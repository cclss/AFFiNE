#!/bin/sh
# Branch coverage for scripts/self-host-entrypoint.sh.
#
#   sh scripts/self-host-entrypoint.test.sh
#
# The entrypoint's one job is deciding whether the servers inside the image are
# used, so that decision is what is tested here: which binaries it reaches for,
# which it leaves alone, what it tells the operator, that the initial setup runs
# exactly once whichever side the data lives on, and what it finally execs.
#
# scripts/runtime-env.sh is sourced by the entrypoint and is covered from here
# rather than from a suite of its own: what it translates only matters as the
# branch that reads it and as the environment the server is finally handed.
# Every external command is a stub that records its invocation, so the test
# needs neither Docker, nor a database, nor root, and touches nothing outside
# its own temporary directory.
#
# The last two cases boot the embedded database twice — once over an empty
# volume, once over the volume that boot left behind — because a second
# `docker run` over existing data is the one thing an operator does that the
# branch assertions above would not notice breaking. Those two replace /var/lib
# with a directory of the suite's own, which needs Linux mount namespaces; where
# there are none they are skipped, and the summary line says so.
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
ENV_LOG="${WORK_DIR}/env.log"
STDOUT_FILE="${WORK_DIR}/stdout"
STDERR_FILE="${WORK_DIR}/stderr"

failures=0
skipped=0
current_case=''

mkdir -p "$STUB_DIR"

# Every command the entrypoint may reach for. Present so that "was it called?"
# is a fact in the log rather than an exec failure, and so that a branch taken
# by mistake is recorded instead of writing to /var/lib on the machine running
# the suite.
for stub in initdb pg_ctl postgres redis-server redis-cli \
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

# node, like the stubs above, plus the environment it was handed. The variables
# scripts/runtime-env.sh translates are only worth translating if they survive
# as far as the process that becomes the server, and argv does not show that.
#
# They go to a file of their own rather than to the call log, because one of
# them is the password of the cache and the call log is printed on any failure.
cat > "${STUB_DIR}/node" <<'STUB'
#!/bin/sh
printf 'node' >> "$STUB_CALL_LOG"
for stub_arg in "$@"; do
  printf ' %s' "$stub_arg" >> "$STUB_CALL_LOG"
done
printf '\n' >> "$STUB_CALL_LOG"

for stub_name in AFFINE_SERVER_PORT REDIS_SERVER_HOST REDIS_SERVER_PORT \
  REDIS_SERVER_USERNAME REDIS_SERVER_PASSWORD; do
  eval "stub_value=\${${stub_name}:-}"
  printf '%s=%s\n' "$stub_name" "$stub_value" >> "$STUB_ENV_LOG"
done
exit 0
STUB
chmod +x "${STUB_DIR}/node"

# `runuser -u <account> -- <command> [args...]`. Privileges cannot be dropped
# here, so the account is recorded and the command is then run as-is. Running it
# matters: the entrypoint reads the database's answers back out of psql's
# stdout, and a runuser that swallowed the command would answer every question
# with silence — which reads as "nothing exists yet" on every boot.
cat > "${STUB_DIR}/runuser" <<'STUB'
#!/bin/sh
printf 'runuser' >> "$STUB_CALL_LOG"
for stub_arg in "$@"; do
  printf ' %s' "$stub_arg" >> "$STUB_CALL_LOG"
done
printf '\n' >> "$STUB_CALL_LOG"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --) shift; break ;;
    *) shift ;;
  esac
done

[ "$#" -gt 0 ] || exit 0
exec "$@"
STUB
chmod +x "${STUB_DIR}/runuser"

# psql is invoked with --file=-, so the statements arrive on stdin and argv
# alone cannot say whether a CREATE ROLE was issued. Both are recorded, on one
# line, with the SQL's newlines collapsed so a statement block stays greppable.
#
# STUB_PG_EXISTING=1 makes the cluster answer "yes, that exists" to the two
# existence queries — the state a second boot finds. Anything else answers with
# no rows, which is an empty cluster.
cat > "${STUB_DIR}/psql" <<'STUB'
#!/bin/sh
stub_sql=$(cat)

printf 'psql' >> "$STUB_CALL_LOG"
for stub_arg in "$@"; do
  printf ' %s' "$stub_arg" >> "$STUB_CALL_LOG"
done
printf ' <<< %s\n' "$(printf '%s' "$stub_sql" | tr '\n' ' ')" >> "$STUB_CALL_LOG"

if [ "${STUB_PG_EXISTING:-0}" = '1' ]; then
  case "$stub_sql" in
    *pg_roles*|*pg_database*) printf '1\n' ;;
  esac
fi
exit 0
STUB
chmod +x "${STUB_DIR}/psql"

# The uid the entrypoint sees, pinned rather than inherited so that a case means
# the same thing whether the suite runs as root or not. 1000 is the uid an
# embedded server must be refused under; STUB_UID=0 is for the cases that need
# the embedded branch to proceed past that refusal.
cat > "${STUB_DIR}/id" <<'STUB'
#!/bin/sh
if [ "${1:-}" = '-u' ]; then
  printf '%s\n' "${STUB_UID:-1000}"
  exit 0
fi
printf 'id stub: unexpected arguments: %s\n' "$*" >&2
exit 64
STUB
chmod +x "${STUB_DIR}/id"

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

# A case states its environment as assignments in front of the call. Whether
# those survive the call is not agreed on between shells — dash keeps them set
# afterwards, bash does not — so they are cleared here. Without this, a case
# would inherit whatever the case above it happened to set, and would pass or
# fail depending on which /bin/sh ran the suite.
clear_case_environment() {
  unset DATABASE_URL REDIS_SERVER_HOST STUB_UID STUB_PG_EXISTING
  unset PORT AFFINE_SERVER_PORT REDIS_URL
}

# run <case name> [args...] — env for the entrypoint comes from the caller.
run() {
  current_case=$1
  shift

  : > "$CALL_LOG"
  : > "$ENV_LOG"

  set +e
  env \
    PATH="${STUB_DIR}:${PATH}" \
    STUB_CALL_LOG="$CALL_LOG" \
    STUB_ENV_LOG="$ENV_LOG" \
    sh "$ENTRYPOINT" "$@" > "$STDOUT_FILE" 2> "$STDERR_FILE"
  run_status=$?
  set -e

  clear_case_environment
}

# run_in_fake_root <var-lib tree> <case name> [args...]
#
# The same as run(), with the given directory mounted over /var/lib for the
# duration — inside a mount namespace of this process's own, so nothing outside
# it sees the mount and nothing outside it is written.
#
# The embedded database branch decides what to do by looking at
# /var/lib/postgresql/data, a path fixed in the entrypoint because it is fixed
# in the image. Handing it a directory the case prepared is what lets "an empty
# volume" and "a volume an earlier boot already initialised" both be stated
# here, instead of being whatever the machine running the suite happens to have.
run_in_fake_root() {
  fake_root_tree=$1
  current_case=$2
  shift 2

  : > "$CALL_LOG"
  : > "$ENV_LOG"

  set +e
  env \
    PATH="${STUB_DIR}:${PATH}" \
    STUB_CALL_LOG="$CALL_LOG" \
    STUB_ENV_LOG="$ENV_LOG" \
    unshare --map-root-user --mount sh -c \
      'mount --bind "$1" /var/lib || exit 70; shift; exec sh "$@"' \
      fake-root "$fake_root_tree" "$ENTRYPOINT" "$@" \
      > "$STDOUT_FILE" 2> "$STDERR_FILE"
  run_status=$?
  set -e

  clear_case_environment
}

skip() {
  skipped=$((skipped + 1))
  printf 'SKIP  %s: %s\n' "$1" "$2" >&2
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

# The environment the server was started with. Never dumped on failure: one of
# the recorded variables is a password.
expect_server_environment() {
  if [ ! -s "$ENV_LOG" ]; then
    report_failure "expected the server to be started with $1, but it was never started"
    return
  fi

  if ! grep -qxF -- "$1" "$ENV_LOG"; then
    report_failure "expected the server to be started with: $1"
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

expect_stderr_contains() {
  if ! grep -qF -- "$1" "$STDERR_FILE"; then
    report_failure "expected stderr to contain: $1"
  fi
}

expect_stderr_lacks() {
  if grep -qF -- "$1" "$STDERR_FILE"; then
    report_failure "expected stderr not to contain: $1"
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

NOTICE_PORT_APPLIED='[entrypoint] `PORT` is set — the server will listen on port 10000; set `AFFINE_SERVER_PORT` to choose the port yourself.'
NOTICE_PORT_UNREAD='[entrypoint] `AFFINE_SERVER_PORT` is set — the server listens on the port it names, and `PORT` is left unread; unset it to follow `PORT`.'
NOTICE_PORT_ABSENT='[entrypoint] `PORT` is empty — the server listens on the port it is configured with; set it to the port this host expects.'
NOTICE_CACHE_URL_APPLIED='[entrypoint] `REDIS_URL` is set — using the cache at cache.example:6380; unset it to start the cache inside this image.'
NOTICE_CACHE_URL_UNREAD='[entrypoint] `REDIS_SERVER_HOST` is set — the cache is the one it names, and `REDIS_URL` is left unread; unset it to follow `REDIS_URL`.'
NOTICE_CACHE_URL_ABSENT='[entrypoint] `REDIS_URL` is empty — the cache is chosen by `REDIS_SERVER_HOST`; set it to name host, port and credentials in one variable.'

EXTERNAL_DATABASE_URL='postgresql://affine@db.example:5432/affine'

# The cache a platform hands over: credentials in the URL, and the two
# characters a password cannot carry literally there — `@` and `/` — arriving
# percent-encoded, which is how a generated password usually arrives.
EXTERNAL_REDIS_URL='redis://default:p%40ss%2Fword@cache.example:6380'
EXTERNAL_REDIS_PASSWORD='p@ss/word'

# ---------------------------------------------------------------------------
# Two /var/lib trees for the embedded database cases: one empty, one carrying
# the file initdb leaves behind, which is how a cluster answers "I have already
# been initialised".
# ---------------------------------------------------------------------------
FAKE_VAR_LIB_EMPTY="${WORK_DIR}/var-lib-empty"
FAKE_VAR_LIB_INITIALISED="${WORK_DIR}/var-lib-initialised"

mkdir -p "$FAKE_VAR_LIB_EMPTY"
mkdir -p "${FAKE_VAR_LIB_INITIALISED}/postgresql/data"
printf '16\n' > "${FAKE_VAR_LIB_INITIALISED}/postgresql/data/PG_VERSION"

# Mounting one of those over /var/lib needs Linux mount namespaces, and an
# unprivileged user namespace to hold them. Probed with the exact operation the
# cases perform, rather than by looking for the binary: the kernel may have user
# namespaces disabled, and a sandbox may forbid the mount.
fake_root_available=no
if command -v unshare >/dev/null 2>&1 &&
  unshare --map-root-user --mount sh -c \
    'mount --bind "$1" /var/lib' fake-root-probe "$FAKE_VAR_LIB_EMPTY" \
    >/dev/null 2>&1; then
  fake_root_available=yes
fi

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
# `PORT` and `REDIS_URL` — the two names a platform speaks — translated into the
# names the server speaks, and carried as far as the server itself.
#
# The database is pointed outside throughout, so that the branch under test is
# the cache one. That the cache branch says "outside" here is the point of the
# translation: the URL filled REDIS_SERVER_HOST before the branch read it, and
# no second decision about the cache was made anywhere.
# ---------------------------------------------------------------------------
DATABASE_URL="$EXTERNAL_DATABASE_URL" PORT='10000' \
  REDIS_URL="$EXTERNAL_REDIS_URL" \
  run 'platform port and cache'
expect_status 0
expect_stdout_line "$NOTICE_PORT_APPLIED"
expect_stdout_line "$NOTICE_CACHE_URL_APPLIED"
expect_stdout_line "$NOTICE_CACHE_OUTSIDE"
expect_not_called 'redis-server'
expect_server_environment 'AFFINE_SERVER_PORT=10000'
expect_server_environment 'REDIS_SERVER_HOST=cache.example'
expect_server_environment 'REDIS_SERVER_PORT=6380'
expect_server_environment 'REDIS_SERVER_USERNAME=default'
# Percent-decoded. Handed over as it arrived, the cache would refuse a password
# it never had — a failure that reads as "wrong password", not as "wrong
# translation", and costs an operator an afternoon.
expect_server_environment "REDIS_SERVER_PASSWORD=${EXTERNAL_REDIS_PASSWORD}"
# The URL carries a password, so no line of the startup may repeat it.
expect_stdout_lacks "$EXTERNAL_REDIS_PASSWORD"
expect_stdout_lacks 'p%40ss'
expect_stdout_lacks 'redis://'

# ---------------------------------------------------------------------------
# The same URL with everything optional left out: the port is the one a
# `redis://` URL means when it names none, and the credentials are empty rather
# than inherited from whatever else was in the environment.
# ---------------------------------------------------------------------------
DATABASE_URL="$EXTERNAL_DATABASE_URL" REDIS_URL='redis://cache.example' \
  run 'cache url without port or credentials'
expect_status 0
expect_stdout_line "$NOTICE_CACHE_OUTSIDE"
expect_not_called 'redis-server'
expect_server_environment 'REDIS_SERVER_HOST=cache.example'
expect_server_environment 'REDIS_SERVER_PORT=6379'
expect_server_environment 'REDIS_SERVER_USERNAME='
expect_server_environment 'REDIS_SERVER_PASSWORD='

# ---------------------------------------------------------------------------
# Neither platform variable set: nothing is translated, nothing is invented,
# and the deployments that predate the translation see the environment they
# have always seen. The two lines are still printed — a reader of the log can
# tell "the platform said nothing" from "this was never asked".
# ---------------------------------------------------------------------------
DATABASE_URL="$EXTERNAL_DATABASE_URL" REDIS_SERVER_HOST='cache.example' \
  run 'no platform variables'
expect_status 0
expect_stdout_line "$NOTICE_PORT_ABSENT"
expect_stdout_line "$NOTICE_CACHE_URL_ABSENT"
expect_stdout_line "$NOTICE_CACHE_OUTSIDE"
expect_server_environment 'AFFINE_SERVER_PORT='
expect_server_environment 'REDIS_SERVER_HOST=cache.example'
expect_server_environment 'REDIS_SERVER_PORT='

# ---------------------------------------------------------------------------
# Both names for the same thing: the server's own variable is the more specific
# of the two and keeps the decision, and the platform's is reported as unread
# instead of being dropped in silence.
# ---------------------------------------------------------------------------
DATABASE_URL="$EXTERNAL_DATABASE_URL" PORT='10000' AFFINE_SERVER_PORT='3010' \
  REDIS_URL="$EXTERNAL_REDIS_URL" REDIS_SERVER_HOST='other.example' \
  run 'server variables win'
expect_status 0
expect_stdout_line "$NOTICE_PORT_UNREAD"
expect_stdout_line "$NOTICE_CACHE_URL_UNREAD"
expect_server_environment 'AFFINE_SERVER_PORT=3010'
expect_server_environment 'REDIS_SERVER_HOST=other.example'
expect_server_environment 'REDIS_SERVER_PORT='
expect_server_environment "REDIS_SERVER_PASSWORD="

# ---------------------------------------------------------------------------
# A `PORT` that is not a port. Fail secure: a server listening on a port nobody
# routes to is indistinguishable from one that never started, so nothing
# downstream of the translation runs.
# ---------------------------------------------------------------------------
DATABASE_URL="$EXTERNAL_DATABASE_URL" REDIS_SERVER_HOST='cache.example' \
  PORT='8o80' run 'port is not a number'
expect_status 1
expect_stderr_contains "\`PORT\` is set to '8o80', which is not a port number between 1 and 65535."
expect_not_called 'self-host-predeploy.js'
expect_not_called 'node ./dist/main.js'

# ---------------------------------------------------------------------------
# A cache that demands TLS. The client's TLS options are not reachable through
# the environment, so the alternative to refusing is sending the password in
# the URL across the network in the clear.
# ---------------------------------------------------------------------------
DATABASE_URL="$EXTERNAL_DATABASE_URL" \
  REDIS_URL='rediss://default:s3cret@cache.example:6380' \
  run 'cache url demands tls'
expect_status 1
expect_stderr_contains 'refused rather than connected to in the clear'
# The refusal names the scheme, never the URL that carries the password.
expect_stderr_lacks 's3cret'
expect_stdout_lacks 's3cret'
expect_not_called 'self-host-predeploy.js'
expect_not_called 'node ./dist/main.js'

# ---------------------------------------------------------------------------
# A database index this file does not translate. Ignoring it would connect to
# database 0 while the URL says 1 — the same cache, a different set of keys,
# and nothing in the log to say so.
# ---------------------------------------------------------------------------
DATABASE_URL="$EXTERNAL_DATABASE_URL" REDIS_URL='redis://cache.example:6380/1' \
  run 'cache url names a database index'
expect_status 1
expect_stderr_contains "carries '/1' after the host"
expect_stderr_contains 'REDIS_SERVER_DATABASE'
expect_not_called 'self-host-predeploy.js'

# ---------------------------------------------------------------------------
# Something that is not a URL at all.
# ---------------------------------------------------------------------------
DATABASE_URL="$EXTERNAL_DATABASE_URL" REDIS_URL='cache.example:6380' \
  run 'cache url is not a url'
expect_status 1
expect_stderr_contains 'is not a `redis://host[:port]` URL'
expect_not_called 'self-host-predeploy.js'

# ---------------------------------------------------------------------------
# The database inside the image, on a first boot and on a second one.
#
# Both cases run against a /var/lib the case itself prepared (see
# run_in_fake_root), so the state the entrypoint finds is stated here rather
# than inherited from the machine. Where that is not possible the pair is
# skipped out loud — a quiet pass would claim coverage this run did not have.
#
# The cache is pointed outside in both, so that what is under test is one
# branch at a time.
# ---------------------------------------------------------------------------
if [ "$fake_root_available" = 'yes' ]; then
  # First boot: an empty volume. Everything the database needs gets created,
  # which is what makes the second-boot assertions below able to fail.
  STUB_UID=0 REDIS_SERVER_HOST='cache.example' \
    run_in_fake_root "$FAKE_VAR_LIB_EMPTY" 'database inside, first boot'
  expect_status 0
  expect_stdout_line "$NOTICE_DB_INSIDE"
  expect_stdout_line "$NOTICE_CACHE_OUTSIDE"
  expect_called 'initdb --pgdata=/var/lib/postgresql/data'
  expect_called 'CREATE ROLE "affine" LOGIN;'
  expect_called 'CREATE DATABASE "affine" OWNER "affine";'
  expect_call_count 'self-host-predeploy.js' 1
  expect_called 'node ./dist/main.js'
  # The role's password exists from here on, and the connection string built
  # around it is exported. Neither may reach the log.
  expect_stdout_lacks 'postgresql://'
  expect_stdout_lacks 'PASSWORD'

  # Second boot: the same volume, after a boot like the one above. The cluster
  # is already initialised and already carries the role and the database, so
  # every step of the embedded branch has nothing left to do — and doing nothing
  # is a success, not a failure. This is the container restart in the story:
  # `docker run` a second time over an existing volume.
  STUB_UID=0 STUB_PG_EXISTING=1 REDIS_SERVER_HOST='cache.example' \
    run_in_fake_root "$FAKE_VAR_LIB_INITIALISED" 'database inside, second boot'
  expect_status 0
  expect_stdout_line "$NOTICE_DB_INSIDE"
  # PG_VERSION is there, so the cluster is not initialised over — which would
  # be the one step of this branch that destroys data rather than duplicating
  # work.
  expect_not_called 'initdb'
  # An operator's volume keeps the ownership and permissions it arrived with.
  expect_not_called 'chown postgres:postgres /var/lib/postgresql/data'
  # The role and the database are found rather than created. CREATE would error
  # against an existing object, which is exactly the second-boot failure this
  # case exists to catch.
  expect_not_called 'CREATE ROLE'
  expect_not_called 'CREATE DATABASE'
  # What does re-run: the password is minted fresh on every boot, and the
  # extensions are asserted with IF NOT EXISTS. Both are writes that repeat
  # safely.
  expect_called 'ALTER ROLE "affine" LOGIN PASSWORD'
  expect_called 'CREATE EXTENSION IF NOT EXISTS "vector";'
  # The server still comes up, and the initial setup still runs — once. Its own
  # steps are idempotent (scripts/self-host-predeploy.test.sh covers that); what
  # is asserted here is that this path neither skips it nor repeats it.
  expect_call_count 'self-host-predeploy.js' 1
  expect_called 'node ./dist/main.js'
  expect_stdout_lacks 'postgresql://'
else
  skip 'database inside, first boot' \
    'no usable mount namespace, so /var/lib cannot be replaced for the case'
  skip 'database inside, second boot' \
    'no usable mount namespace, so /var/lib cannot be replaced for the case'
fi

# ---------------------------------------------------------------------------
if [ "$failures" -ne 0 ]; then
  printf '\n%d assertion(s) failed.\n' "$failures" >&2
  exit 1
fi

if [ "$skipped" -ne 0 ]; then
  printf 'self-host-entrypoint.sh: all branch assertions passed, %d case(s) skipped.\n' \
    "$skipped"
  exit 0
fi

printf 'self-host-entrypoint.sh: all branch assertions passed.\n'
