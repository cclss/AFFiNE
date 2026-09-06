#!/bin/sh
# AFFiNE preview start — the image's boot, run on this host.
#
#   sh scripts/preview/start.sh
#
# Takes what `sh scripts/preview/build.sh` produced and turns it into a server
# the preview can reach: the datastores the platform injected are translated
# into the names this server knows, the database is brought up to the schema the
# bundle expects, and the bundle is exec'd on the port the platform named.
#
# The sequence is scripts/self-host-entrypoint.sh with the image taken away.
# What is missing here is only what the image supplies: this host has no
# PostgreSQL and no Redis of its own to start, and no root to start them as, so
# the branch that chooses between "inside the image" and "outside it" is not
# repeated — a database this script cannot provision is refused instead, once,
# at the top. Everything the two have in common is shared rather than copied:
# scripts/runtime-env.sh does the translating and
# scripts/self-host-predeploy.js does the migrating and the seeding, exactly as
# they do under `docker run`.
#
# Plain HTTP throughout. Whatever terminates TLS in front of this process is the
# platform's, and this script neither serves a certificate nor issues a redirect
# to one — see the `AFFINE_SERVER_HTTPS` notice below.
#
# Branch behaviour is covered by scripts/preview/start.test.sh, which runs this
# script against stub binaries and needs neither a database nor a built bundle.

set -eu

# ---------------------------------------------------------------------------
# Output.
#
# Notices follow the cli-target-notice component's build-step extension, the
# same one scripts/preview/build.sh follows: one line per decision or per step,
# the deciding file or variable named in it, and how to change that decision on
# the same line. `[preview]` is the prefix throughout — the operator invoked one
# preview, and the two scripts it runs are two halves of it, not two voices.
#
# scripts/runtime-env.sh reports its own decisions through the two functions
# below, so its lines arrive under this prefix as well.
# ---------------------------------------------------------------------------
NOTICE_TAG='[preview]'

# Two steps: bring the database up to date, then start the server. The total
# comes from here alone — a step added without moving this number is a progress
# report that lies.
TOTAL_STEPS=2
completed_steps=0

notice() {
  printf '%s %s\n' "$NOTICE_TAG" "$1"
}

# Opens a step. There is no closing line: the next step's line says the last one
# returned, and the last step ends by becoming the server.
step() {
  completed_steps=$((completed_steps + 1))
  printf '%s %s/%s %s\n' "$NOTICE_TAG" "$completed_steps" "$TOTAL_STEPS" "$1"
}

# A start that cannot continue must say so and stop. A server exec'd over a
# database that was never migrated answers requests with stack traces, and the
# reason is then pages above in the log — or, when the migration step was never
# reached at all, nowhere in it.
fail() {
  printf '%s %s\n' "$NOTICE_TAG" "$1" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Paths.
#
# The script is invoked by path from wherever the preview happens to stand, so
# the repository root is resolved from the script's own location rather than
# from the working directory.
# ---------------------------------------------------------------------------
REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$REPO_ROOT"

SERVER_DIR='packages/backend/server'
SERVER_BUNDLE="${SERVER_DIR}/dist/main.js"
SERVER_ADDON="${SERVER_DIR}/dist/server-native.node"
SERVER_FIRST_SCREEN="${SERVER_DIR}/static/selfhost.html"
PREDEPLOY='./scripts/self-host-predeploy.js'
RUNTIME_ENV="${REPO_ROOT}/${SERVER_DIR}/scripts/runtime-env.sh"

# ---------------------------------------------------------------------------
# What the build left behind.
#
# Checked before anything is connected to, because every failure after this
# point costs the reader a database round trip to find out that the thing meant
# to use it was never built. The three are the three the build script asserts it
# wrote: the bundle, the native addon it loads on the first line, and the first
# screen it serves.
# ---------------------------------------------------------------------------
command -v node >/dev/null 2>&1 ||
  fail 'node is not on PATH — the server is a Node program; install the version `.nvmrc` pins and run this script again.'

for required in "$SERVER_BUNDLE" "$SERVER_ADDON" "$SERVER_FIRST_SCREEN"; do
  [ -f "$required" ] ||
    fail "\`${required}\` is missing — this script starts a build it did not make; run \`sh scripts/preview/build.sh\` first."
done

notice "The build in \`${SERVER_DIR}\` is what starts here — \`dist/main.js\`, \`dist/server-native.node\` and \`static/\`; run \`sh scripts/preview/build.sh\` to replace it."

# ---------------------------------------------------------------------------
# The database.
#
# Refused rather than defaulted. The entrypoint inside the image reads an empty
# DATABASE_URL as "use the PostgreSQL in this image" — there is none on this
# host, and inventing a connection string would send the migrations at whatever
# happens to be listening on the local machine. The one thing worse than not
# starting is starting against someone else's database.
# ---------------------------------------------------------------------------
if [ -z "${DATABASE_URL:-}" ]; then
  fail '`DATABASE_URL` is empty and this script starts no database of its own — set it to the connection string of the database this preview should use.'
fi

notice '`DATABASE_URL` is set — the migrations below and the server both use the database it names; its value is not printed here because it carries a password.'

# ---------------------------------------------------------------------------
# Yarn.
#
# scripts/self-host-predeploy.js shells out to `yarn prisma` and `yarn cli`,
# which the server package declares. A `yarn` on PATH may be any version, and
# Yarn Classic ignores .yarnrc.yml's yarnPath outright, so the name is pointed
# at the release this repository vendors for as long as the setup step needs it
# — and removed again before the server is exec'd, because a build tool this
# script installed must not outlive the step that needed it.
# ---------------------------------------------------------------------------
set -- .yarn/releases/yarn-*.cjs
yarn_release=$1
[ -f "$yarn_release" ] ||
  fail 'no Yarn release is vendored in `.yarn/releases` — `.yarnrc.yml` points `yarnPath` at one, and the migration step below calls `yarn`.'

yarn_version=${yarn_release#.yarn/releases/yarn-}
yarn_version=${yarn_version%.cjs}

SHIM_DIR=$(mktemp -d)
trap 'rm -rf "$SHIM_DIR"' EXIT
trap 'rm -rf "$SHIM_DIR"; exit 130' INT
trap 'rm -rf "$SHIM_DIR"; exit 143' TERM

printf '#!/bin/sh\nexec node "%s/%s" "$@"\n' "$REPO_ROOT" "$yarn_release" > "${SHIM_DIR}/yarn"
chmod +x "${SHIM_DIR}/yarn"
PATH_WITHOUT_SHIM=$PATH
PATH="${SHIM_DIR}:${PATH}"
export PATH

notice "\`yarn\` is the release this repository vendors (${yarn_version}) for the migration step — whatever \`yarn\` was on PATH is left unread."

# ---------------------------------------------------------------------------
# Platform variables.
#
# The port this host expects and the cache it provisioned arrive under names
# this server does not know. The same file the image sources translates them
# here, so a preview and a container agree on what `PORT` and `REDIS_URL` mean
# down to the notice they print. It reports through `notice` and `fail` above,
# which is why it is sourced after them.
# ---------------------------------------------------------------------------
[ -f "$RUNTIME_ENV" ] ||
  fail "\`${SERVER_DIR}/scripts/runtime-env.sh\` is missing — it is what teaches this server what \`PORT\` and \`REDIS_URL\` mean, and this checkout is incomplete without it."

. "$RUNTIME_ENV"

# ---------------------------------------------------------------------------
# How the server is reached.
#
# Neither variable is set here: an operator who set one meant it, and a preview
# that silently overrode it would be lying to the person who chose it. Both are
# reported either way, because "no line" and "the branch was never reached" read
# the same in a log a day later.
# ---------------------------------------------------------------------------
if [ -z "${LISTEN_ADDR:-}" ]; then
  notice '`LISTEN_ADDR` is empty — the server accepts connections on every interface, which is what a preview behind a proxy needs; set it to narrow that to one address.'
else
  notice "\`LISTEN_ADDR\` is set to '${LISTEN_ADDR}' — the server accepts connections there and nowhere else; unset it to listen on every interface."
fi

if [ -z "${AFFINE_SERVER_HTTPS:-}" ]; then
  notice '`AFFINE_SERVER_HTTPS` is empty — the server speaks plain HTTP and redirects nothing to https, which is what a TLS terminator in front of it expects; set it to `true` when this deployment serves TLS itself.'
else
  notice "\`AFFINE_SERVER_HTTPS\` is set to '${AFFINE_SERVER_HTTPS}' — the server builds its own URLs with it and marks session cookies accordingly; unset it to speak plain HTTP behind a TLS terminator."
fi

# ---------------------------------------------------------------------------
# The start.
#
# From the server package, because that is where `yarn cli` and `yarn prisma`
# find the manifest and the schema they are named in, and where the bundle's
# relative path below resolves.
# ---------------------------------------------------------------------------
cd "$SERVER_DIR"

# Config files, schema migrations, data migrations and the standard seed. Every
# one of them is conditional on what it finds rather than on "is this the first
# start", which is what makes a restart repeat nothing: the key is kept, the
# applied migrations are skipped, and the seed stops as soon as the database
# holds a user.
step "Applying migrations and seeding the first account — \`node ${PREDEPLOY}\`."
node "$PREDEPLOY"

# The shim goes away with the step that needed it; the server is handed the PATH
# this script was invoked with.
rm -rf "$SHIM_DIR"
PATH=$PATH_WITHOUT_SHIM
export PATH

if [ -n "${AFFINE_SERVER_PORT:-}" ]; then
  step "Starting the server on port ${AFFINE_SERVER_PORT} over plain HTTP — \`node ./dist/main.js\`."
else
  step 'Starting the server on the port it is configured with, over plain HTTP — `node ./dist/main.js`; set `PORT` to choose that port.'
fi

# exec, so the server is this process: it receives the signals the platform
# sends to stop the preview, and there is no shell left in between to swallow
# them or to outlive it.
exec node ./dist/main.js
