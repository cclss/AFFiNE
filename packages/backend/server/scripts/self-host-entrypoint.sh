#!/bin/sh
# AFFiNE self-host entrypoint.
#
# The image carries a PostgreSQL server and a Redis server of its own (see the
# `runtime` stage of .github/deployment/node/Dockerfile). Whether they are used
# is decided here, and only here: an empty connection variable means "the one
# inside the image", a filled one means "the one the operator pointed us at".
#
#   DATABASE_URL empty       -> initdb if needed, start the embedded PostgreSQL,
#                               provision role + database, export the loopback URL
#   REDIS_SERVER_HOST empty  -> start the embedded Redis, export its loopback host
#
# The two are independent: an external database with the in-image cache, or the
# reverse, both work. Whichever side each lands on, the initial-setup entrypoint
# (scripts/self-host-predeploy.js: schema migrations, data migrations, standard
# seed) runs once from the single call below, and the server is exec'd after it.
#
# This is the only branch on where the data lives. Nothing downstream — not the
# server, not the predeploy script, not the compose files — repeats it. Adding a
# second copy of this decision anywhere else is the thing this file exists to
# prevent.
#
# Branch behaviour is covered by scripts/self-host-entrypoint.test.sh, which runs
# this script against stub binaries and needs neither Docker nor a database.

set -eu

# ---------------------------------------------------------------------------
# Constants. The paths match the directories the Dockerfile's runtime stage
# creates, and the ports match the server's own defaults.
# ---------------------------------------------------------------------------
NOTICE_TAG='[entrypoint]'
LOOPBACK='127.0.0.1'

PG_DATA_DIR='/var/lib/postgresql/data'
PG_SOCKET_DIR='/var/run/postgresql'
PG_SUPERUSER='postgres'
PG_PORT='5432'
PG_APP_ROLE='affine'
PG_APP_DATABASE='affine'

REDIS_DATA_DIR='/var/lib/redis'
REDIS_CONFIG_DIR='/run/affine'
REDIS_CONFIG_FILE="${REDIS_CONFIG_DIR}/redis.conf"
REDIS_ACCOUNT='redis'
REDIS_PORT='6379'

# How long to wait for an embedded server to accept connections before giving
# up. Generous: first boot on a slow disk pays for initdb and crash recovery.
STARTUP_TIMEOUT_SECONDS=60

# The script is invoked as the image ENTRYPOINT, so `docker run <image> <cmd>`
# reaches it with an arbitrary working directory. Resolve the application root
# from the script's own location instead of trusting WORKDIR, so that the
# relative paths below — and the relative CMD — mean the same thing either way.
APP_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$APP_DIR"

# ---------------------------------------------------------------------------
# Output.
#
# Notices follow the cli-target-notice component: one line per target, stating
# which one was chosen and how to choose the other. Connection strings are never
# printed — the embedded ones carry a password.
# ---------------------------------------------------------------------------
notice() {
  printf '%s %s\n' "$NOTICE_TAG" "$1"
}

# A failure here must not fall through to the server: a server pointed at a
# database that never came up corrupts nothing, but it does bury the real cause
# under a stack trace. Say what broke, and stop.
fail() {
  printf '%s %s\n' "$NOTICE_TAG" "$1" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------

# Neither embedded server runs as root — PostgreSQL refuses to, and both Debian
# packages ship a service account. runuser takes the command as arguments
# rather than as a shell string, so nothing here has to survive a second round
# of word splitting.
run_as() {
  run_as_account=$1
  shift
  runuser -u "$run_as_account" -- "$@"
}

# 24 bytes of kernel entropy as hex. Hex on purpose: the value goes into a URL
# and into an SQL string literal, and no hex digit needs escaping in either.
random_secret() {
  od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
}

# Make a data directory exist and belong to the account that will write it.
#
# The directory is left alone once it holds data: a populated directory is an
# operator's volume with its own history, and rewriting its ownership on every
# boot would be a silent way to break it. Only an absent or still-empty
# directory is claimed — which is exactly the case a fresh bind mount presents,
# where the host's ownership would otherwise stop the server from starting.
claim_directory() {
  claim_path=$1
  claim_account=$2
  claim_mode=$3

  if [ ! -d "$claim_path" ]; then
    install -d -o "$claim_account" -g "$claim_account" -m "$claim_mode" "$claim_path"
  elif [ -z "$(ls -A "$claim_path")" ]; then
    chown "$claim_account:$claim_account" "$claim_path"
    chmod "$claim_mode" "$claim_path"
  fi
}

# Starting an embedded server means dropping privileges to its service account,
# and that is a root-only move. Checked before anything is written, so that a
# non-root container fails on a sentence instead of on a chown.
require_embedded_prerequisites() {
  if [ "$(id -u)" -ne 0 ]; then
    fail "the servers inside this image start as their own service accounts, which needs the container to run as root; supply DATABASE_URL and REDIS_SERVER_HOST to use servers outside the image instead."
  fi

  if ! command -v runuser >/dev/null 2>&1; then
    fail "runuser was not found, so privileges cannot be dropped to the service accounts of the servers inside this image."
  fi
}

# ---------------------------------------------------------------------------
# Embedded PostgreSQL.
# ---------------------------------------------------------------------------

# SQL arrives on stdin rather than in an argument: `ps` shows argv to every
# process in the container, and one of these statements carries the password.
# Authentication is peer over the Unix socket, so the superuser connection
# itself needs no secret at all.
psql_superuser() {
  run_as "$PG_SUPERUSER" psql \
    --host="$PG_SOCKET_DIR" \
    --port="$PG_PORT" \
    --username="$PG_SUPERUSER" \
    --dbname="$1" \
    --no-psqlrc \
    --quiet \
    --no-align \
    --tuples-only \
    --set=ON_ERROR_STOP=1 \
    --file=-
}

start_embedded_postgres() {
  require_embedded_prerequisites

  claim_directory "$PG_DATA_DIR" "$PG_SUPERUSER" 0700

  # PG_VERSION is the first file initdb writes and the last thing it would
  # leave behind, so its presence is the cluster's own answer to "have I been
  # initialised?" — which makes a second boot on the same volume a no-op here
  # rather than a failure.
  if [ ! -s "${PG_DATA_DIR}/PG_VERSION" ]; then
    # --locale=C.UTF-8    the image generates no locales; C.UTF-8 is built into
    #                     glibc. Without it initdb would settle on SQL_ASCII and
    #                     the database would mangle any non-ASCII text.
    # --data-checksums    the embedded server is not signalled on shutdown (see
    #                     the note above `exec` at the end of this file), so it
    #                     goes through crash recovery on most restarts and meets
    #                     a torn page sooner or later. Checksums make that loud
    #                     instead of silent.
    # --auth-local=peer   the superuser is reachable over the Unix socket by the
    #                     postgres account and by nothing else. No password
    #                     exists for it, so none can leak.
    # --auth-host=scram-sha-256  every TCP connection authenticates, including
    #                     the application's. `trust` here would hand a superuser
    #                     session to anything that reaches the loopback address
    #                     — which is more than this container when its network
    #                     namespace is shared.
    run_as "$PG_SUPERUSER" initdb \
      --pgdata="$PG_DATA_DIR" \
      --username="$PG_SUPERUSER" \
      --encoding=UTF8 \
      --locale=C.UTF-8 \
      --data-checksums \
      --auth-local=peer \
      --auth-host=scram-sha-256
  fi

  # The socket directory comes from the postgresql package, but whether it
  # survives into a running container depends on how /run is provisioned — a
  # tmpfs mount there would leave it empty. Ensuring it is cheaper than
  # depending on it.
  claim_directory "$PG_SOCKET_DIR" "$PG_SUPERUSER" 0755

  # listen_addresses is forced on the command line, not left to the cluster's
  # postgresql.conf: a volume initialised elsewhere may carry any value, and an
  # embedded database has no reason to answer anyone but this container.
  #
  # pg_ctl --wait returns only once the server accepts connections, and returns
  # non-zero if it never does, which is the readiness check. With no --log the
  # server keeps this script's stdout and stderr, so `docker logs` shows the
  # database and the application interleaved instead of hiding one of them.
  run_as "$PG_SUPERUSER" pg_ctl \
    --pgdata="$PG_DATA_DIR" \
    --wait \
    --timeout="$STARTUP_TIMEOUT_SECONDS" \
    --options="-c listen_addresses=${LOOPBACK} -c port=${PG_PORT} -c unix_socket_directories=${PG_SOCKET_DIR}" \
    start

  provision_embedded_postgres
}

# Bring the cluster to the shape the application expects: a login role that owns
# a database of its own. Every step is conditional on the catalog rather than on
# "is this the first boot", so re-running it against a populated volume is a
# no-op.
provision_embedded_postgres() {
  PG_APP_PASSWORD=$(random_secret)

  pg_role_exists=$(
    printf 'SELECT 1 FROM pg_roles WHERE rolname = %s;\n' "'${PG_APP_ROLE}'" \
      | psql_superuser "$PG_SUPERUSER"
  )

  if [ -z "$pg_role_exists" ]; then
    printf 'CREATE ROLE "%s" LOGIN;\n' "$PG_APP_ROLE" | psql_superuser "$PG_SUPERUSER"
  fi

  # The password is minted fresh on every boot and never persisted. Nothing
  # outside this container ever needs it, so there is no second copy to rotate,
  # leak or forget — and a volume that outlives the container carries no
  # credential with it.
  psql_superuser "$PG_SUPERUSER" <<SQL
ALTER ROLE "${PG_APP_ROLE}" LOGIN PASSWORD '${PG_APP_PASSWORD}';
SQL

  pg_database_exists=$(
    printf 'SELECT 1 FROM pg_database WHERE datname = %s;\n' "'${PG_APP_DATABASE}'" \
      | psql_superuser "$PG_SUPERUSER"
  )

  if [ -z "$pg_database_exists" ]; then
    # OWNER, not superuser. The role needs to create tables and extensions in
    # its own database and nothing more; a superuser reaching the database
    # would also reach the container's filesystem through COPY TO PROGRAM.
    printf 'CREATE DATABASE "%s" OWNER "%s";\n' "$PG_APP_DATABASE" "$PG_APP_ROLE" \
      | psql_superuser "$PG_SUPERUSER"
  fi

  # The migrations declare `CREATE EXTENSION IF NOT EXISTS` for both of these,
  # but they run as the application role, which can only install an extension
  # marked trusted. Installing them here as the superuser makes that a property
  # of the database rather than of the extension's control file: the migration
  # then finds them present and skips, whichever way a future package is
  # marked. It also matches the shape the sibling pgvector image handed over.
  psql_superuser "$PG_APP_DATABASE" <<'SQL'
CREATE EXTENSION IF NOT EXISTS "vector";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
SQL

  DATABASE_URL="postgresql://${PG_APP_ROLE}:${PG_APP_PASSWORD}@${LOOPBACK}:${PG_PORT}/${PG_APP_DATABASE}"
  export DATABASE_URL
}

# ---------------------------------------------------------------------------
# Embedded Redis.
# ---------------------------------------------------------------------------
start_embedded_redis() {
  require_embedded_prerequisites

  claim_directory "$REDIS_DATA_DIR" "$REDIS_ACCOUNT" 0750

  REDIS_ACCESS_PASSWORD=$(random_secret)

  # The password goes through a configuration file rather than `--requirepass`,
  # for the same reason the SQL above goes through stdin: an argument is public
  # to every process in the container. The file is created empty, locked down,
  # and only then filled, so it is never briefly readable with content in it.
  #
  # It lives under /run — wiped on every container start, and never the volume
  # an operator mounts — so the credential does not outlive the process it
  # belongs to.
  install -d -o "$REDIS_ACCOUNT" -g "$REDIS_ACCOUNT" -m 0750 "$REDIS_CONFIG_DIR"
  : > "$REDIS_CONFIG_FILE"
  chown "$REDIS_ACCOUNT:$REDIS_ACCOUNT" "$REDIS_CONFIG_FILE"
  chmod 0600 "$REDIS_CONFIG_FILE"
  cat >> "$REDIS_CONFIG_FILE" <<CONF
bind ${LOOPBACK}
port ${REDIS_PORT}
dir ${REDIS_DATA_DIR}
daemonize no
requirepass ${REDIS_ACCESS_PASSWORD}
CONF

  # Foreground, backgrounded by the shell, so Redis keeps this script's stdout
  # and stderr and its log lines reach `docker logs` like everything else.
  run_as "$REDIS_ACCOUNT" redis-server "$REDIS_CONFIG_FILE" &
  redis_pid=$!

  wait_for_redis "$redis_pid"

  # Port and password are overwritten rather than merged. An operator who left
  # REDIS_SERVER_HOST empty asked for the cache in this image, and the port and
  # password of some other cache do not describe it.
  REDIS_SERVER_HOST="$LOOPBACK"
  REDIS_SERVER_PORT="$REDIS_PORT"
  REDIS_SERVER_PASSWORD="$REDIS_ACCESS_PASSWORD"
  export REDIS_SERVER_HOST REDIS_SERVER_PORT REDIS_SERVER_PASSWORD
}

# Redis has no equivalent of `pg_ctl --wait`, so poll — but poll the process as
# well as the port. A server that has already exited will never answer, and
# waiting out the full timeout for it only delays the error message.
#
# REDISCLI_AUTH rather than `-a`: same argv exposure, same reason.
wait_for_redis() {
  wait_redis_pid=$1
  wait_elapsed=0

  while [ "$wait_elapsed" -lt "$STARTUP_TIMEOUT_SECONDS" ]; do
    if REDISCLI_AUTH="$REDIS_ACCESS_PASSWORD" redis-cli \
      -h "$LOOPBACK" -p "$REDIS_PORT" ping >/dev/null 2>&1; then
      return 0
    fi

    if ! kill -0 "$wait_redis_pid" 2>/dev/null; then
      fail "the cache inside this image exited while starting up; its output is above."
    fi

    sleep 1
    wait_elapsed=$((wait_elapsed + 1))
  done

  fail "the cache inside this image did not accept connections within ${STARTUP_TIMEOUT_SECONDS}s."
}

# ---------------------------------------------------------------------------
# The branch.
# ---------------------------------------------------------------------------

# Empty covers unset as well as set-to-nothing: `docker run -e DATABASE_URL`
# with no value is a request for the database inside the image, not a request
# to connect to the empty string.
if [ -z "${DATABASE_URL:-}" ]; then
  notice '`DATABASE_URL` is empty — starting the database inside this image; set it to a connection string to use one outside.'
  start_embedded_postgres
else
  notice '`DATABASE_URL` is set — using the database outside this image; unset it to start the one inside.'
fi

if [ -z "${REDIS_SERVER_HOST:-}" ]; then
  notice '`REDIS_SERVER_HOST` is empty — starting the cache inside this image; set it to a host name to use one outside.'
  start_embedded_redis
else
  notice '`REDIS_SERVER_HOST` is set — using the cache outside this image; unset it to start the one inside.'
fi

# One call, on both paths. Schema migrations, data migrations and the standard
# seed are idempotent by construction, so this is also what makes a second boot
# on an existing volume a no-op rather than an error.
node ./scripts/self-host-predeploy.js

# The command from CMD, so that `docker run <image> <something else>` still
# reaches the database and cache this script set up. exec, so the server is
# PID 1 and receives the signals `docker stop` sends.
#
# Replacing this shell also gives up the chance to forward those signals to the
# embedded servers, which are therefore killed rather than asked to stop. That
# is survivable and by design here — PostgreSQL's crash recovery and Redis's
# snapshots exist for exactly this — but it is a trade, recorded in
# context/backlog.md rather than left to be rediscovered.
if [ "$#" -eq 0 ]; then
  set -- node ./dist/main.js
fi

exec "$@"
