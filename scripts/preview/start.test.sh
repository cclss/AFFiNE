#!/bin/sh
# Branch coverage for scripts/preview/start.sh.
#
#   sh scripts/preview/start.test.sh
#
# The start script's job is to hand an already-built server a database it can
# migrate and a port it can listen on, and to refuse rather than start half of
# that. So this suite asks what the script does before the server exists: which
# artifacts it insists on, which platform variables it translates and which it
# reports untouched, what reaches the process that becomes the server, and which
# states stop it before a single connection is made.
#
# scripts/runtime-env.sh is sourced by the start script and is exercised from
# here as it is exercised from the entrypoint's own suite — through the
# environment the server is finally handed, which is the only place its work is
# visible. What is new here, and what these cases pin, is that its lines arrive
# under this script's prefix rather than the entrypoint's.
#
# Every case runs against a fixture repository of its own — a directory holding
# only the files the script reads — with PATH narrowed to a directory this suite
# fills. The bundle, the native addon, the first screen, the vendored Yarn
# release and the setup script are all stand-ins that record how they were
# invoked, so the suite needs neither a database, nor a cache, nor a build.
#
# What this cannot cover, and what a real preview still has to: that the
# migrations apply, that the seeded account can sign in, and that the server
# answers its first screen with 200. Stubs prove the wiring, not the server.

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
START_SCRIPT="${SCRIPT_DIR}/start.sh"
RUNTIME_ENV_SCRIPT=$(CDPATH='' cd -- "${SCRIPT_DIR}/../.." && pwd)/packages/backend/server/scripts/runtime-env.sh

[ -f "$RUNTIME_ENV_SCRIPT" ] || {
  printf 'the suite needs packages/backend/server/scripts/runtime-env.sh\n' >&2
  exit 70
}

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT INT TERM

CASE_TMP="${WORK_DIR}/tmp"
CALL_LOG="${WORK_DIR}/calls.log"
ENV_LOG="${WORK_DIR}/env.log"
STDOUT_FILE="${WORK_DIR}/stdout"
STDERR_FILE="${WORK_DIR}/stderr"

failures=0
current_case=''
repo=''

YARN_VERSION='4.18.0'

# ---------------------------------------------------------------------------
# The fixture repository.
#
# Four stand-ins, one per thing the script hands work to.
# ---------------------------------------------------------------------------

# The vendored Yarn release. Reached only through the shim the script installs,
# so a case that sees `yarn --version` in the log has also seen that the shim
# points the name at the release this repository pins — which is the whole
# reason the shim exists.
write_fake_yarn_release() {
  cat > "$1" <<'RELEASE'
const fs = require('node:fs');

const args = process.argv.slice(2);
fs.appendFileSync(process.env.STUB_CALL_LOG, `yarn ${args.join(' ')}\n`);

if (args[0] === '--version') {
  process.stdout.write('4.18.0\n');
}
RELEASE
}

# scripts/self-host-predeploy.js, which the real one models: it runs from the
# server package and shells out to `yarn`. Both are recorded, because a setup
# step run from the wrong directory finds neither the manifest that declares
# `yarn cli` nor the schema `yarn prisma` deploys.
#
# STUB_PREDEPLOY_STATUS names a setup that fails — the state in which a server
# must not be started.
write_fake_predeploy() {
  cat > "$1" <<'PREDEPLOY'
const fs = require('node:fs');
const { execSync } = require('node:child_process');

fs.appendFileSync(process.env.STUB_CALL_LOG, `predeploy cwd=${process.cwd()}\n`);

const version = execSync('yarn --version', { encoding: 'utf-8' }).trim();
fs.appendFileSync(process.env.STUB_CALL_LOG, `predeploy yarn=${version}\n`);

process.exit(Number(process.env.STUB_PREDEPLOY_STATUS || 0));
PREDEPLOY
}

# The server bundle. It records the environment it was handed rather than its
# arguments: what scripts/runtime-env.sh translated only matters if it survives
# as far as this process, and argv does not show that.
#
# The variables go to a file of their own, not to the call log, because two of
# them carry credentials and the call log is printed on any failure.
write_fake_server_bundle() {
  cat > "$1" <<'BUNDLE'
const fs = require('node:fs');

fs.appendFileSync(process.env.STUB_CALL_LOG, `server cwd=${process.cwd()}\n`);

for (const name of [
  'AFFINE_SERVER_PORT',
  'REDIS_SERVER_HOST',
  'REDIS_SERVER_PORT',
  'REDIS_SERVER_USERNAME',
  'REDIS_SERVER_PASSWORD',
  'LISTEN_ADDR',
  'AFFINE_SERVER_HTTPS',
  'PATH',
]) {
  fs.appendFileSync(
    process.env.STUB_ENV_LOG,
    `${name}=${process.env[name] ?? ''}\n`
  );
}
BUNDLE
}

# A repository the script can be pointed at: the files it reads, the script
# itself at the path it resolves its root from, and nothing else.
new_repo() {
  repo="${WORK_DIR}/repo-$1"
  rm -rf "$repo"
  mkdir -p \
    "${repo}/.yarn/releases" \
    "${repo}/scripts/preview" \
    "${repo}/packages/backend/server/scripts" \
    "${repo}/packages/backend/server/dist" \
    "${repo}/packages/backend/server/static"

  write_fake_yarn_release "${repo}/.yarn/releases/yarn-${YARN_VERSION}.cjs"
  write_fake_predeploy "${repo}/packages/backend/server/scripts/self-host-predeploy.js"
  write_fake_server_bundle "${repo}/packages/backend/server/dist/main.js"
  printf 'addon\n' > "${repo}/packages/backend/server/dist/server-native.node"
  printf '<!doctype html>\n' > "${repo}/packages/backend/server/static/selfhost.html"

  # The real one, not a stand-in: the translation it performs is what the cases
  # below assert, and a copy of it here would be a second definition free to
  # drift from the one the image sources.
  cp "$RUNTIME_ENV_SCRIPT" "${repo}/packages/backend/server/scripts/runtime-env.sh"
  cp "$START_SCRIPT" "${repo}/scripts/preview/start.sh"
}

# ---------------------------------------------------------------------------
# The case's PATH.
#
# Filled per case, so that "node is on PATH" is a fact the case states rather
# than a property of the machine. Only the programs the script shells out to are
# linked in.
# ---------------------------------------------------------------------------
new_path() {
  CASE_BIN="${WORK_DIR}/bin"
  rm -rf "$CASE_BIN"
  mkdir -p "$CASE_BIN"

  for real in sh cat mktemp chmod rm mkdir dirname; do
    real_path=$(command -v "$real") ||
      { printf 'the suite needs %s on PATH\n' "$real" >&2; exit 70; }
    ln -s "$real_path" "${CASE_BIN}/${real}"
  done

  # The interpreter, not whatever launches it. `node` on a developer's PATH is
  # often a version manager's shim, and a shim resolves its version from an
  # environment these cases deliberately empty.
  ln -s "$(node -e 'process.stdout.write(process.execPath)')" "${CASE_BIN}/node"
}

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

# run <case name> — the fixture repository and the case PATH are already built;
# the environment the script reads comes from the caller.
run() {
  current_case=$1

  : > "$CALL_LOG"
  : > "$ENV_LOG"

  # The shim directory the script makes lands here rather than in the machine's
  # /tmp, so that a case can state it was cleaned up afterwards.
  rm -rf "$CASE_TMP"
  mkdir -p "$CASE_TMP"

  set +e
  env -i \
    PATH="$CASE_BIN" \
    HOME="${WORK_DIR}/home" \
    TMPDIR="$CASE_TMP" \
    STUB_CALL_LOG="$CALL_LOG" \
    STUB_ENV_LOG="$ENV_LOG" \
    STUB_PREDEPLOY_STATUS="${CASE_PREDEPLOY_STATUS:-}" \
    DATABASE_URL="${CASE_DATABASE_URL-postgresql://affine:secret@db:5432/affine}" \
    PORT="${CASE_PORT:-}" \
    AFFINE_SERVER_PORT="${CASE_AFFINE_SERVER_PORT:-}" \
    REDIS_URL="${CASE_REDIS_URL:-}" \
    REDIS_SERVER_HOST="${CASE_REDIS_SERVER_HOST:-}" \
    LISTEN_ADDR="${CASE_LISTEN_ADDR:-}" \
    AFFINE_SERVER_HTTPS="${CASE_AFFINE_SERVER_HTTPS:-}" \
    sh "${repo}/scripts/preview/start.sh" > "$STDOUT_FILE" 2> "$STDERR_FILE"
  run_status=$?
  set -e
}

# Cleared between cases rather than inside `run`, so a case can run the script
# twice under one environment — which is what the restart case does.
clear_case_environment() {
  unset CASE_PREDEPLOY_STATUS CASE_DATABASE_URL CASE_PORT CASE_AFFINE_SERVER_PORT
  unset CASE_REDIS_URL CASE_REDIS_SERVER_HOST CASE_LISTEN_ADDR CASE_AFFINE_SERVER_HTTPS
  rm -rf "${WORK_DIR}/home"
}

report_failure() {
  failures=$((failures + 1))
  printf 'FAIL  %s: %s\n' "$current_case" "$1" >&2
  printf '      stdout: %s\n' "$(tr '\n' '|' < "$STDOUT_FILE")" >&2
  printf '      stderr: %s\n' "$(tr '\n' '|' < "$STDERR_FILE")" >&2
  printf '      calls:  %s\n' "$(tr '\n' '|' < "$CALL_LOG")" >&2
}

expect_status() {
  if [ "$run_status" -ne "$1" ]; then
    report_failure "expected exit status $1, got $run_status"
  fi
}

expect_called() {
  if ! grep -qxF -- "$1" "$CALL_LOG"; then
    report_failure "expected a call: $1"
  fi
}

expect_not_called() {
  if grep -qF -- "$1" "$CALL_LOG"; then
    report_failure "expected no call matching '$1'"
  fi
}

# The order is the point: the database is brought up to the schema the bundle
# expects before the bundle is started against it. Asserted as one sequence
# rather than as two memberships, which hold just as well the wrong way round.
expect_sequence() {
  actual=$(tr '\n' '|' < "$CALL_LOG")
  if [ "$actual" != "$1" ]; then
    report_failure "expected call sequence: $1
      got:                    $actual"
  fi
}

# What the exec'd server was handed. The value is not printed on failure — two
# of the variables asserted here are credentials.
expect_server_environment() {
  if ! grep -qxF -- "$1" "$ENV_LOG"; then
    report_failure "expected the server to be handed: ${1%%=*}=<other value>"
  fi
}

# A build tool this script installed must not outlive it. The shim is removed
# before the server is exec'd, and on every path that refuses after installing
# it — which is what the trap in the script is for.
expect_no_temporary_directory() {
  if [ -n "$(ls -A "$CASE_TMP" 2>/dev/null)" ]; then
    report_failure 'expected no temporary directory to be left behind'
  fi
}

expect_stdout_line() {
  if ! grep -qxF -- "$1" "$STDOUT_FILE"; then
    report_failure "expected stdout line: $1"
  fi
}

expect_stdout_lacks() {
  if grep -qF -- "$1" "$STDOUT_FILE"; then
    report_failure "expected stdout not to contain: $1"
  fi
}

expect_stderr_line() {
  if ! grep -qxF -- "$1" "$STDERR_FILE"; then
    report_failure "expected stderr line: $1"
  fi
}

# ---------------------------------------------------------------------------
# The notices, verbatim. Duplicated from the script on purpose: the wording is a
# recorded design decision (cli-target-notice, build-step extension), so a silent
# edit to it fails a test rather than passing review unnoticed.
# ---------------------------------------------------------------------------
NOTICE_BUILD='[preview] The build in `packages/backend/server` is what starts here — `dist/main.js`, `dist/server-native.node` and `static/`; run `sh scripts/preview/build.sh` to replace it.'
NOTICE_DATABASE='[preview] `DATABASE_URL` is set — the migrations below and the server both use the database it names; its value is not printed here because it carries a password.'
NOTICE_YARN='[preview] `yarn` is the release this repository vendors (4.18.0) for the migration step — whatever `yarn` was on PATH is left unread.'
NOTICE_LISTEN_EMPTY='[preview] `LISTEN_ADDR` is empty — the server accepts connections on every interface, which is what a preview behind a proxy needs; set it to narrow that to one address.'
NOTICE_LISTEN_SET="[preview] \`LISTEN_ADDR\` is set to '127.0.0.1' — the server accepts connections there and nowhere else; unset it to listen on every interface."
NOTICE_HTTPS_EMPTY='[preview] `AFFINE_SERVER_HTTPS` is empty — the server speaks plain HTTP and redirects nothing to https, which is what a TLS terminator in front of it expects; set it to `true` when this deployment serves TLS itself.'
NOTICE_HTTPS_SET="[preview] \`AFFINE_SERVER_HTTPS\` is set to 'true' — the server builds its own URLs with it and marks session cookies accordingly; unset it to speak plain HTTP behind a TLS terminator."

# scripts/runtime-env.sh's own lines, under this script's prefix.
NOTICE_PORT='[preview] `PORT` is set — the server will listen on port 10000; set `AFFINE_SERVER_PORT` to choose the port yourself.'
NOTICE_PORT_EMPTY='[preview] `PORT` is empty — the server listens on the port it is configured with; set it to the port this host expects.'
NOTICE_PORT_UNREAD='[preview] `AFFINE_SERVER_PORT` is set — the server listens on the port it names, and `PORT` is left unread; unset it to follow `PORT`.'
NOTICE_REDIS='[preview] `REDIS_URL` is set — using the cache at cache.internal:6380; unset it to start the cache inside this image.'
NOTICE_REDIS_EMPTY='[preview] `REDIS_URL` is empty — the cache is chosen by `REDIS_SERVER_HOST`; set it to name host, port and credentials in one variable.'

STEP_PREDEPLOY='[preview] 1/2 Applying migrations and seeding the first account — `node ./scripts/self-host-predeploy.js`.'
STEP_SERVER_PORT='[preview] 2/2 Starting the server on port 10000 over plain HTTP — `node ./dist/main.js`.'
STEP_SERVER_DEFAULT='[preview] 2/2 Starting the server on the port it is configured with, over plain HTTP — `node ./dist/main.js`; set `PORT` to choose that port.'

REFUSAL_DATABASE='[preview] `DATABASE_URL` is empty and this script starts no database of its own — set it to the connection string of the database this preview should use.'
REFUSAL_BUNDLE='[preview] `packages/backend/server/dist/main.js` is missing — this script starts a build it did not make; run `sh scripts/preview/build.sh` first.'
REFUSAL_SCREEN='[preview] `packages/backend/server/static/selfhost.html` is missing — this script starts a build it did not make; run `sh scripts/preview/build.sh` first.'
REFUSAL_YARN='[preview] no Yarn release is vendored in `.yarn/releases` — `.yarnrc.yml` points `yarnPath` at one, and the migration step below calls `yarn`.'
REFUSAL_PORT="[preview] \`PORT\` is set to 'http', which is not a port number between 1 and 65535."

# `yarn --version` is logged by the release itself, which runs to completion
# before the step that called it writes down what it answered.
SEQUENCE="predeploy cwd=REPO/packages/backend/server|yarn --version|predeploy yarn=${YARN_VERSION}|server cwd=REPO/packages/backend/server|"

# The call log carries the fixture's own path, which differs per case. Comparing
# against it directly would make the expected sequence a moving target, so the
# repository root is folded to `REPO` before the comparison.
fold_repo_path() {
  sed "s|${repo}|REPO|g" "$CALL_LOG" > "${CALL_LOG}.folded"
  mv "${CALL_LOG}.folded" "$CALL_LOG"
}

# ---------------------------------------------------------------------------
# The platform's own case: a port, a database and a cache, all injected.
# ---------------------------------------------------------------------------
new_repo 'happy'
new_path
CASE_PORT='10000'
# The password carries an `@`, which a URL cannot hold literally. It arrives
# percent-encoded and must reach the server decoded, or the cache rejects it.
CASE_REDIS_URL='redis://affine:pa%40ss@cache.internal:6380'

run 'port, database and cache injected'
fold_repo_path
expect_status 0
expect_sequence "$SEQUENCE"

expect_stdout_line "$NOTICE_BUILD"
expect_stdout_line "$NOTICE_DATABASE"
expect_stdout_line "$NOTICE_YARN"
expect_stdout_line "$NOTICE_PORT"
expect_stdout_line "$NOTICE_REDIS"
expect_stdout_line "$NOTICE_LISTEN_EMPTY"
expect_stdout_line "$NOTICE_HTTPS_EMPTY"
expect_stdout_line "$STEP_PREDEPLOY"
expect_stdout_line "$STEP_SERVER_PORT"

# The two variables the platform speaks, in the vocabulary the server speaks.
expect_server_environment 'AFFINE_SERVER_PORT=10000'
expect_server_environment 'REDIS_SERVER_HOST=cache.internal'
expect_server_environment 'REDIS_SERVER_PORT=6380'
expect_server_environment 'REDIS_SERVER_USERNAME=affine'
expect_server_environment 'REDIS_SERVER_PASSWORD=pa@ss'

# Neither is set by this script. A preview that quietly narrowed the listen
# address or claimed TLS it does not terminate would be unreachable, or would
# mark its session cookies for a scheme it never speaks.
expect_server_environment 'LISTEN_ADDR='
expect_server_environment 'AFFINE_SERVER_HTTPS='

# The shim is a build tool this script installed for one step; the server is
# handed the PATH the script was invoked with, and the temporary directory is
# gone.
expect_server_environment "PATH=${CASE_BIN}"
expect_no_temporary_directory

# Neither the connection string nor the cache password is a thing to leave in a
# preview log.
expect_stdout_lacks 'postgresql://'
expect_stdout_lacks 'pa@ss'
expect_stdout_lacks 'pa%40ss'
clear_case_environment

# ---------------------------------------------------------------------------
# The same environment, twice. A preview is restarted far more often than it is
# started, and the second start must do exactly what the first did — no extra
# step, no refusal over what the first one left behind.
# ---------------------------------------------------------------------------
new_repo 'restart'
new_path
CASE_PORT='10000'
CASE_REDIS_URL='redis://affine:pa%40ss@cache.internal:6380'

run 'first start'
fold_repo_path
expect_status 0
first_sequence=$(tr '\n' '|' < "$CALL_LOG")

run 'restart over the same tree'
fold_repo_path
expect_status 0
expect_sequence "$first_sequence"
expect_stdout_line "$STEP_PREDEPLOY"
expect_stdout_line "$STEP_SERVER_PORT"
clear_case_environment

# ---------------------------------------------------------------------------
# No port and no cache: both variables are optional, and both silences are
# reported. The server is started on what it is configured with.
# ---------------------------------------------------------------------------
new_repo 'no-platform-variables'
new_path

run 'neither PORT nor REDIS_URL injected'
fold_repo_path
expect_status 0
expect_sequence "$SEQUENCE"
expect_stdout_line "$NOTICE_PORT_EMPTY"
expect_stdout_line "$NOTICE_REDIS_EMPTY"
expect_stdout_line "$STEP_SERVER_DEFAULT"
expect_server_environment 'AFFINE_SERVER_PORT='
expect_server_environment 'REDIS_SERVER_HOST='
clear_case_environment

# ---------------------------------------------------------------------------
# The server's own variables, set alongside the platform's. The specific one
# wins, and the one that lost is named as unread rather than dropped in silence.
# ---------------------------------------------------------------------------
new_repo 'server-variables-win'
new_path
CASE_PORT='10000'
CASE_AFFINE_SERVER_PORT='3010'
CASE_LISTEN_ADDR='127.0.0.1'
CASE_AFFINE_SERVER_HTTPS='true'

run 'AFFINE_SERVER_PORT, LISTEN_ADDR and AFFINE_SERVER_HTTPS set by the operator'
fold_repo_path
expect_status 0
expect_stdout_line "$NOTICE_PORT_UNREAD"
expect_stdout_line "$NOTICE_LISTEN_SET"
expect_stdout_line "$NOTICE_HTTPS_SET"
expect_server_environment 'AFFINE_SERVER_PORT=3010'
expect_server_environment 'LISTEN_ADDR=127.0.0.1'
expect_server_environment 'AFFINE_SERVER_HTTPS=true'
clear_case_environment

# ---------------------------------------------------------------------------
# A port the platform got wrong. Refused before the database is touched: a
# server on a port nobody routes to is indistinguishable from one that never
# started.
# ---------------------------------------------------------------------------
new_repo 'bad-port'
new_path
CASE_PORT='http'

run 'PORT is not a port number'
fold_repo_path
expect_status 1
expect_stderr_line "$REFUSAL_PORT"
expect_no_temporary_directory
expect_not_called 'predeploy'
expect_not_called 'server'
clear_case_environment

# ---------------------------------------------------------------------------
# No database. There is none inside this host to fall back to, and guessing one
# would point the migrations at whatever is listening locally.
# ---------------------------------------------------------------------------
new_repo 'no-database'
new_path
CASE_DATABASE_URL=''

run 'DATABASE_URL is empty'
fold_repo_path
expect_status 1
expect_stderr_line "$REFUSAL_DATABASE"
expect_not_called 'predeploy'
expect_not_called 'server'
clear_case_environment

# ---------------------------------------------------------------------------
# Started without a build. Three artifacts, each checked before anything is
# connected to — the alternative is finding out after a migration.
# ---------------------------------------------------------------------------
new_repo 'no-bundle'
new_path
rm -f "${repo}/packages/backend/server/dist/main.js"

run 'the server bundle was never built'
fold_repo_path
expect_status 1
expect_stderr_line "$REFUSAL_BUNDLE"
expect_not_called 'predeploy'
clear_case_environment

new_repo 'no-first-screen'
new_path
rm -f "${repo}/packages/backend/server/static/selfhost.html"

run 'the frontends were never staged'
fold_repo_path
expect_status 1
expect_stderr_line "$REFUSAL_SCREEN"
expect_not_called 'predeploy'
clear_case_environment

# ---------------------------------------------------------------------------
# An incomplete checkout: the package manager the setup step calls is not there
# to be pointed at.
# ---------------------------------------------------------------------------
new_repo 'no-yarn-release'
new_path
rm -f "${repo}/.yarn/releases/yarn-${YARN_VERSION}.cjs"

run 'no Yarn release is vendored'
fold_repo_path
expect_status 1
expect_stderr_line "$REFUSAL_YARN"
expect_not_called 'predeploy'
clear_case_environment

# ---------------------------------------------------------------------------
# Setup that fails. The server is not started over a database whose schema was
# never brought up to date, and the status the step failed with is the status
# the preview sees.
# ---------------------------------------------------------------------------
new_repo 'failing-predeploy'
new_path
CASE_PREDEPLOY_STATUS='3'

run 'the migration step fails'
fold_repo_path
expect_status 3
expect_called 'predeploy cwd=REPO/packages/backend/server'
expect_not_called 'server cwd='
expect_stdout_line "$STEP_PREDEPLOY"
expect_stdout_lacks 'Starting the server'
clear_case_environment

# ---------------------------------------------------------------------------
if [ "$failures" -ne 0 ]; then
  printf '\n%d assertion(s) failed.\n' "$failures" >&2
  exit 1
fi

printf 'preview/start.sh: all branch assertions passed.\n'
