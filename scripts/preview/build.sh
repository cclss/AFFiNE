#!/bin/sh
# AFFiNE preview build — the image's build stage, run on this host.
#
#   sh scripts/preview/build.sh
#
# Turns a clean checkout into the two things the server is started from:
#
#   packages/backend/server/dist/main.js            the bundled server
#   packages/backend/server/dist/server-native.node the native addon it loads
#   packages/backend/server/static/                 the frontends it serves
#
# The sequence is the `build` stage of .github/deployment/node/Dockerfile with
# the container taken away: the same install, the same toolchain pin, the same
# four builds in the same order — the native addon before the server bundle,
# because napi writes server-native.node and the bundler copies it next to
# main.js. Where the image copies the frontend dists into /app/static, this
# script stages them into the server package, which to the server is the same
# directory: env.projectRoot resolves from the bundle's own location
# (packages/backend/server/src/env.ts:105), so dist/main.js next to static/ is
# the layout both the image and this checkout present.
#
# It is not a second definition of how AFFiNE builds. Every step below shells
# out to a script this repository already declares, so a build that changes
# changes in the package that owns it and this file follows without an edit.
#
# The mobile bundle the image also carries is deliberately absent: it is only
# reached on the canary namespace (packages/backend/server/src/core/selfhost/
# static.ts), and BUILD_TYPE below makes this a stable build.
#
# Branch behaviour is covered by scripts/preview/build.test.sh, which runs this
# script against stub binaries and needs neither a toolchain nor a network.

set -eu

# ---------------------------------------------------------------------------
# Output.
#
# Notices follow the cli-target-notice component's build-step extension: one
# line per decision or per step, the deciding file or variable named in it, and
# the command that redoes that one step on the same line. `[preview]` is the
# prefix throughout, because `yarn` and `affine` label their own lines
# (`[build]`, `[run]`) into the same stream and a reader has to be able to tell
# which lines are this script's.
# ---------------------------------------------------------------------------
NOTICE_TAG='[preview]'

# Every step line carries its position, and the total comes from here alone —
# a step added without moving this number is a progress report that lies.
TOTAL_STEPS=6
completed_steps=0

notice() {
  printf '%s %s\n' "$NOTICE_TAG" "$1"
}

# Opens a step. There is no closing line: the next step's line says the last
# one returned, and the final step is closed by the summary at the bottom.
step() {
  completed_steps=$((completed_steps + 1))
  printf '%s %s/%s %s\n' "$NOTICE_TAG" "$completed_steps" "$TOTAL_STEPS" "$1"
}

# A build that cannot continue must not leave a half-staged tree behind a zero
# exit status: the preview would then start a server whose first screen is a
# 404, and the reason would be pages above in the log.
fail() {
  printf '%s %s\n' "$NOTICE_TAG" "$1" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------

# A build tool can fail by exiting non-zero, and it can fail by exiting zero
# without writing what it promised. The second kind is checked here, at every
# step, with the same assertions the Dockerfile's build stage makes — this is
# the last place the two artifacts and the staged directory can be caught
# missing before something tries to serve them.
require_file() {
  [ -f "$1" ] || fail "\`$1\` was not produced — \`$2\` returned successfully without writing it, so the preview has nothing to start."
}

# The script is invoked by path from wherever the preview happens to stand, so
# the repository root is resolved from the script's own location rather than
# from the working directory. Every path below is relative to it.
REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$REPO_ROOT"

WEB_DIST='packages/frontend/apps/web/dist'
ADMIN_DIST='packages/frontend/admin/dist'
SERVER_DIR='packages/backend/server'
SERVER_DIST="${SERVER_DIR}/dist"
STATIC_DIR="${SERVER_DIR}/static"
NATIVE_ADDON='packages/backend/native/server-native.node'

# ---------------------------------------------------------------------------
# Node.
#
# The version is reported, not enforced: the manifest's `engines` range is what
# the packages are built against, and a host one major ahead usually builds.
# Being told which version did the building is what makes a strange failure
# below readable, so the line is printed either way.
# ---------------------------------------------------------------------------
command -v node >/dev/null 2>&1 ||
  fail 'node is not on PATH — every step of this build is a Node program; install the version `.nvmrc` pins and run this script again.'

node_version=$(node --version)
node_major=${node_version#v}
node_major=${node_major%%.*}

pinned_node=''
if [ -f .nvmrc ]; then
  pinned_node=$(tr -d ' \t\r\n' < .nvmrc)
fi
pinned_node_major=${pinned_node%%.*}

if [ -z "$pinned_node" ]; then
  notice "Node ${node_version} is on PATH and this checkout carries no \`.nvmrc\` — the build runs on what is here, with nothing to compare it against."
elif [ "$node_major" = "$pinned_node_major" ]; then
  notice "Node ${node_version} is on PATH — the major version \`.nvmrc\` pins (${pinned_node})."
else
  notice "Node ${node_version} is on PATH and \`.nvmrc\` pins ${pinned_node} — the build runs on what is here; install the pinned version if a step below fails on a language feature."
fi

# ---------------------------------------------------------------------------
# Yarn.
#
# .yarnrc.yml's yarnPath names a release vendored in .yarn/releases, pinned by
# the same commit as the lockfile. A `yarn` on PATH may be any version, and
# Yarn Classic ignores yarnPath outright, so this build never trusts the one it
# found: a shim ahead of PATH points the name at the vendored release for this
# process and its children. Workspace scripts call `yarn` by name too, so
# pointing the name is what makes the pin hold all the way down.
#
# The shim lives in a temporary directory that is removed on exit — a build
# tool this script installed must not outlive it on someone's machine.
# ---------------------------------------------------------------------------
set -- .yarn/releases/yarn-*.cjs
yarn_release=$1
[ -f "$yarn_release" ] ||
  fail 'no Yarn release is vendored in `.yarn/releases` — `.yarnrc.yml` points `yarnPath` at one, and this checkout is incomplete without it.'

yarn_version=${yarn_release#.yarn/releases/yarn-}
yarn_version=${yarn_version%.cjs}

SHIM_DIR=$(mktemp -d)
trap 'rm -rf "$SHIM_DIR"' EXIT
trap 'rm -rf "$SHIM_DIR"; exit 130' INT
trap 'rm -rf "$SHIM_DIR"; exit 143' TERM

printf '#!/bin/sh\nexec node "%s/%s" "$@"\n' "$REPO_ROOT" "$yarn_release" > "${SHIM_DIR}/yarn"
chmod +x "${SHIM_DIR}/yarn"
PATH="${SHIM_DIR}:${PATH}"
export PATH

notice "\`yarn\` is the release this repository vendors (${yarn_version}) for the rest of this build — whatever \`yarn\` was on PATH is left unread."

# ---------------------------------------------------------------------------
# Rust.
#
# packages/backend/native is a napi addon compiled from Rust, and the server
# bundle does not run without it. rust-toolchain.toml pins the channel; rustup
# is what honours a pin, so a host without rustup gets one — installed the way
# .github/actions/build-rust and the Dockerfile install it, over a
# pinned-protocol TLS connection from rustup's published location, after which
# rustup signature-checks the toolchain it downloads.
#
# A host that has cargo but not rustup is left alone: installing a second
# toolchain manager underneath an existing one is how a machine ends up with
# two rustcs and no way to tell which built what. The pin is reported instead.
# ---------------------------------------------------------------------------
rust_channel=$(sed -n 's/^[[:space:]]*channel[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' rust-toolchain.toml | head -n 1)
[ -n "$rust_channel" ] ||
  fail '`rust-toolchain.toml` names no `channel` — the native addon has no pinned toolchain to build with, and guessing one is how a build starts producing a different binary every day.'

if ! command -v rustup >/dev/null 2>&1 && ! command -v cargo >/dev/null 2>&1; then
  command -v curl >/dev/null 2>&1 ||
    fail 'neither `rustup` nor `cargo` is on PATH, and `curl` is not there to install one — the native addon is compiled from Rust; install rustup from https://rustup.rs and run this script again.'

  notice "Neither \`rustup\` nor \`cargo\` is on PATH — installing rustup, then the toolchain \`rust-toolchain.toml\` pins (${rust_channel}); install rustup yourself to keep this build off the network."
  curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs |
    sh -s -- -y --no-modify-path --default-toolchain none
  # rustup-init installs under CARGO_HOME and is told not to touch any shell
  # profile, so the only way this process reaches what it just installed is to
  # put it on PATH here.
  PATH="${CARGO_HOME:-${HOME:-}/.cargo}/bin:${PATH}"
  export PATH
fi

if command -v rustup >/dev/null 2>&1; then
  # Idempotent: an installed toolchain makes this a no-op, and rustup would
  # otherwise download it silently at the first cargo call, mid-step, with no
  # line saying which channel arrived.
  rustup toolchain install "$rust_channel"
  notice "Rust ${rust_channel} is installed — the channel \`rust-toolchain.toml\` pins; edit that file to build the addon with another."
elif command -v cargo >/dev/null 2>&1; then
  notice "\`cargo\` is on PATH without \`rustup\`, so the pin in \`rust-toolchain.toml\` (${rust_channel}) is reported and not applied — install rustup to have it honoured."
else
  # Reached only when the install above returned successfully and left nothing
  # behind. Stopping here costs a message; continuing costs the reader a Rust
  # error four steps down, in a language about missing crates.
  fail "rustup was installed but is not on PATH — expected it under \`${CARGO_HOME:-${HOME:-}/.cargo}/bin\`; install rustup yourself and run this script again."
fi

# tree-sitter, which the addon pulls in, does not compile against glibc's
# headers without _BSD_SOURCE (tree-sitter/tree-sitter#4186). The Dockerfile
# and .github/actions/build-rust both set it on clang; here the compiler is
# whatever the host has, and only the flag is what the addon needs. An operator
# who set CC already made this decision and is not overruled.
if [ -z "${CC:-}" ]; then
  if command -v clang >/dev/null 2>&1; then
    CC='clang -D_BSD_SOURCE'
  else
    CC='cc -D_BSD_SOURCE'
  fi
  TARGET_CC=$CC
  export CC TARGET_CC
  notice "\`CC\` was empty — the addon's C dependencies are compiled with \`${CC}\`; set \`CC\` to choose the compiler yourself."
else
  notice "\`CC\` is set to \`${CC}\` — the addon's C dependencies are compiled with it; unset it to let this script pick one."
fi

# ---------------------------------------------------------------------------
# Build environment.
#
# BUILD_TYPE   the release channel baked into the frontend bundles. `stable` is
#              what a self-hosted build ships, and it is also what keeps the
#              canary-only mobile bundle out of the server's static routes.
# GITHUB_SHA   stamped into the HTML and the assets manifest. The bundler falls
#              back to reading it from the git repository, which an exported
#              source tree does not carry, so a value is resolved here.
# HUSKY        the root postinstall installs git hooks. A preview host builds a
#              tree it will never commit from, and an exported tree has no .git
#              for husky to write into.
# *_SKIP_*     install scripts that would otherwise download hundreds of
#              megabytes of binaries — an Electron runtime, browsers, a release
#              CLI — that no step below and no preview ever runs.
#
# Each is defaulted, never overwritten: a caller that set one meant it.
# ---------------------------------------------------------------------------
BUILD_TYPE=${BUILD_TYPE:-stable}
export BUILD_TYPE

if [ -z "${GITHUB_SHA:-}" ]; then
  GITHUB_SHA=$(git rev-parse HEAD 2>/dev/null || true)
  if [ -n "$GITHUB_SHA" ]; then
    notice "\`GITHUB_SHA\` was empty — the bundles are stamped with this checkout's commit ${GITHUB_SHA}; set it to stamp another."
  else
    GITHUB_SHA='0000000000000000000000000000000000000000'
    notice "\`GITHUB_SHA\` was empty and this tree is not a git repository — the bundles are stamped with a placeholder commit; set \`GITHUB_SHA\` to stamp the real one."
  fi
  export GITHUB_SHA
else
  notice "\`GITHUB_SHA\` is set — the bundles are stamped with commit ${GITHUB_SHA}."
fi

export HUSKY=${HUSKY:-0}
export ELECTRON_SKIP_BINARY_DOWNLOAD=${ELECTRON_SKIP_BINARY_DOWNLOAD:-1}
export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=${PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD:-1}
export SENTRYCLI_SKIP_DOWNLOAD=${SENTRYCLI_SKIP_DOWNLOAD:-1}

# ---------------------------------------------------------------------------
# The build.
#
# One step per artifact, in dependency order, each one a command that can be
# typed on its own — which is what every step line hands the reader.
# ---------------------------------------------------------------------------

# --immutable: a lockfile that does not already satisfy the manifests fails the
# build here instead of resolving something the lockfile never recorded.
step 'Installing workspace dependencies from the lockfile — `yarn install --immutable --inline-builds`.'
yarn install --immutable --inline-builds

step 'Building the native addon the server loads — `yarn workspace @affine/server-native build`.'
yarn workspace @affine/server-native build
require_file "$NATIVE_ADDON" 'yarn workspace @affine/server-native build'

step 'Building the web frontend — `yarn affine @affine/web build`.'
yarn affine @affine/web build
require_file "${WEB_DIST}/selfhost.html" 'yarn affine @affine/web build'

step 'Building the admin frontend — `yarn affine @affine/admin build`.'
yarn affine @affine/admin build
require_file "${ADMIN_DIST}/selfhost.html" 'yarn affine @affine/admin build'

step 'Bundling the server — `yarn workspace @affine/server build`.'
yarn workspace @affine/server build
require_file "${SERVER_DIST}/main.js" 'yarn workspace @affine/server build'
require_file "${SERVER_DIST}/server-native.node" 'yarn workspace @affine/server build'

# The frontends are copied rather than linked, and the destination is emptied
# first: a stale asset left from an earlier build is served with the same
# confidence as a fresh one, and the manifest that names it has already moved
# on. Copying the contents (`dist/.`) rather than the directory keeps the
# layout the server expects — static/selfhost.html, not static/dist/*.
step "Staging the frontends into \`${STATIC_DIR}\` — the directory the server serves from."
rm -rf "$STATIC_DIR"
mkdir -p "${STATIC_DIR}/admin"
cp -R "${WEB_DIST}/." "${STATIC_DIR}/"
cp -R "${ADMIN_DIST}/." "${STATIC_DIR}/admin/"
require_file "${STATIC_DIR}/selfhost.html" "cp -R ${WEB_DIST}/."
require_file "${STATIC_DIR}/admin/selfhost.html" "cp -R ${ADMIN_DIST}/."

notice "Build complete — \`${SERVER_DIST}/main.js\`, \`${SERVER_DIST}/server-native.node\` and \`${STATIC_DIR}/\` are in place."
