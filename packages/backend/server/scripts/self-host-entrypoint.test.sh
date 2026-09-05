#!/bin/sh
# Branch coverage for scripts/self-host-entrypoint.sh.
#
#   sh scripts/self-host-entrypoint.test.sh
#
# The entrypoint's one job is deciding whether the servers inside the image are
# used, so that decision is what is tested here: which binaries it reaches for,
# which it leaves alone, what it tells the operator, and what it finally execs.
# Every external command is a stub that records its invocation, so the test
# needs neither Docker, nor a database, nor root, and touches nothing outside
# its own temporary directory.
#
# What this cannot cover, and what `docker run` still has to: that initdb,
# pg_ctl and redis-server actually bring servers up, and that the application
# then answers on /info. Stubs prove the wiring, not the servers.

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ENTRYPOINT="${SCRIPT_DIR}/self-host-entrypoint.sh"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT INT TERM

STUB_DIR="${WORK_DIR}/bin"
CALL_LOG="${WORK_DIR}/calls.log"
STDOUT_FILE="${WORK_DIR}/stdout"
STDERR_FILE="${WORK_DIR}/stderr"

failures=0
current_case=''

mkdir -p "$STUB_DIR"

# Every command the entrypoint may reach for. Present so that "was it called?"
# is a fact in the log rather than an exec failure, and so that a branch taken
# by mistake is recorded instead of writing to /var/lib on the machine running
# the suite.
for stub in node runuser initdb pg_ctl postgres psql redis-server redis-cli \
  install chown chmod; do
  cat > "${STUB_DIR}/${stub}" <<STUB
#!/bin/sh
printf '%s' "${stub}" >> "\$STUB_CALL_LOG"
for stub_arg in "\$@"; do
  printf ' %s' "\$stub_arg" >> "\$STUB_CALL_LOG"
done
printf '\n' >> "\$STUB_CALL_LOG"
exit 0
STUB
  chmod +x "${STUB_DIR}/${stub}"
done

# A uid the entrypoint must refuse to start an embedded server under. Pinned so
# the outcome is the same whether the suite runs as root or not — without it a
# root runner would fall through to initdb against the real /var/lib.
cat > "${STUB_DIR}/id" <<'STUB'
#!/bin/sh
if [ "${1:-}" = '-u' ]; then
  printf '1000\n'
  exit 0
fi
printf 'id stub: unexpected arguments: %s\n' "$*" >&2
exit 64
STUB
chmod +x "${STUB_DIR}/id"

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

# run <case name> [args...] — env for the entrypoint comes from the caller.
run() {
  current_case=$1
  shift

  : > "$CALL_LOG"

  set +e
  env \
    PATH="${STUB_DIR}:${PATH}" \
    STUB_CALL_LOG="$CALL_LOG" \
    sh "$ENTRYPOINT" "$@" > "$STDOUT_FILE" 2> "$STDERR_FILE"
  run_status=$?
  set -e
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
  if ! grep -q -- "$1" "$CALL_LOG"; then
    report_failure "expected a call matching '$1'"
  fi
}

expect_not_called() {
  if grep -q -- "$1" "$CALL_LOG"; then
    report_failure "expected no call matching '$1'"
  fi
}

expect_call_count() {
  expect_count_actual=$(grep -c -- "$1" "$CALL_LOG" || true)
  if [ "$expect_count_actual" -ne "$2" ]; then
    report_failure "expected $2 calls matching '$1', got $expect_count_actual"
  fi
}

expect_stdout_line() {
  if ! grep -qxF -- "$1" "$STDOUT_FILE"; then
    report_failure "expected stdout line: $1"
  fi
}

expect_stderr_contains() {
  if ! grep -qF -- "$1" "$STDERR_FILE"; then
    report_failure "expected stderr to contain: $1"
  fi
}

# ---------------------------------------------------------------------------
# The notices, verbatim. Duplicated from the entrypoint on purpose: the wording
# is a recorded design decision (the cli-target-notice component), so a silent
# edit to it should fail a test rather than pass review unnoticed.
# ---------------------------------------------------------------------------
NOTICE_DB_INSIDE='[entrypoint] `DATABASE_URL` is empty — starting the database inside this image; set it to a connection string to use one outside.'
NOTICE_DB_OUTSIDE='[entrypoint] `DATABASE_URL` is set — using the database outside this image; unset it to start the one inside.'
NOTICE_CACHE_INSIDE='[entrypoint] `REDIS_SERVER_HOST` is empty — starting the cache inside this image; set it to a host name to use one outside.'
NOTICE_CACHE_OUTSIDE='[entrypoint] `REDIS_SERVER_HOST` is set — using the cache outside this image; unset it to start the one inside.'

EXTERNAL_DATABASE_URL='postgresql://affine@db.example:5432/affine'

# ---------------------------------------------------------------------------
# Both connection variables filled: the image's own servers stay untouched.
# ---------------------------------------------------------------------------
DATABASE_URL="$EXTERNAL_DATABASE_URL" REDIS_SERVER_HOST='cache.example' \
  run 'both outside'
expect_status 0
expect_stdout_line "$NOTICE_DB_OUTSIDE"
expect_stdout_line "$NOTICE_CACHE_OUTSIDE"
expect_not_called 'initdb'
expect_not_called 'pg_ctl'
expect_not_called 'postgres'
expect_not_called 'redis-server'
expect_not_called 'runuser'
# The initial setup runs on this path too, exactly once, and the server is what
# the entrypoint hands over to afterwards.
expect_call_count 'self-host-predeploy.js' 1
expect_called 'node ./dist/main.js'

# ---------------------------------------------------------------------------
# A variable that is set but empty is a request for the server inside the image,
# not a request to connect to the empty string.
# ---------------------------------------------------------------------------
DATABASE_URL='' REDIS_SERVER_HOST='' run 'both empty'
expect_status 1
expect_stdout_line "$NOTICE_DB_INSIDE"
expect_stderr_contains 'needs the container to run as root'
# Fail secure: the setup and the server are downstream of a database that never
# came up, so neither may run.
expect_not_called 'self-host-predeploy.js'
expect_not_called 'node ./dist/main.js'

# ---------------------------------------------------------------------------
# Unset behaves the same as empty, and the two sides are independent: an
# external database with the in-image cache reaches the cache branch and leaves
# the database alone.
# ---------------------------------------------------------------------------
DATABASE_URL="$EXTERNAL_DATABASE_URL" run 'cache inside, database outside'
expect_status 1
expect_stdout_line "$NOTICE_DB_OUTSIDE"
expect_stdout_line "$NOTICE_CACHE_INSIDE"
expect_not_called 'initdb'
expect_not_called 'pg_ctl'
expect_not_called 'self-host-predeploy.js'

# ---------------------------------------------------------------------------
# ...and the reverse.
# ---------------------------------------------------------------------------
REDIS_SERVER_HOST='cache.example' run 'database inside, cache outside'
expect_status 1
expect_stdout_line "$NOTICE_DB_INSIDE"
expect_not_called 'redis-server'
expect_not_called 'self-host-predeploy.js'
# The cache notice belongs to a branch the failed database branch never reaches.
if grep -qxF -- "$NOTICE_CACHE_OUTSIDE" "$STDOUT_FILE"; then
  report_failure 'startup continued past a database that failed to start'
fi

# ---------------------------------------------------------------------------
# An explicit command replaces the default one, after the same preparation —
# which is what keeps `docker run <image> <command>` usable.
# ---------------------------------------------------------------------------
DATABASE_URL="$EXTERNAL_DATABASE_URL" REDIS_SERVER_HOST='cache.example' \
  run 'explicit command' node ./scripts/self-host-predeploy.js
expect_status 0
expect_call_count 'self-host-predeploy.js' 2
expect_not_called 'node ./dist/main.js'

# ---------------------------------------------------------------------------
if [ "$failures" -ne 0 ]; then
  printf '\n%d assertion(s) failed.\n' "$failures" >&2
  exit 1
fi

printf 'self-host-entrypoint.sh: all branch assertions passed.\n'
