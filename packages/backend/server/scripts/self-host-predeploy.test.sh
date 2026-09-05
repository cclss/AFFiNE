#!/bin/sh
# Coverage for scripts/self-host-predeploy.js — the initial-setup entrypoint.
#
#   sh scripts/self-host-predeploy.test.sh
#
# The script's job is to bring an arbitrary database up to the state the server
# expects: schema migrations, then data migrations, then the standard seed. What
# is tested here is that ordering, that every step is reached exactly once, that
# a second run over an already-prepared home is a no-op rather than an error,
# and that every line it prints carries the `[predeploy] ` prefix.
#
# `yarn` is a stub that records its invocation, so the suite needs neither a
# database nor a built server bundle, and HOME is redirected into a temporary
# directory so the generated private key never lands in the real one.
#
# What this cannot cover, and what `docker run` still has to: that the
# migrations and the seed are themselves idempotent against a live PostgreSQL.
# `src/data/__tests__/standard-seed.spec.ts` covers the seed's half of that.

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
APP_DIR=$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd)
PREDEPLOY="${SCRIPT_DIR}/self-host-predeploy.js"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT INT TERM

STUB_DIR="${WORK_DIR}/bin"
FAKE_HOME="${WORK_DIR}/home"
CALL_LOG="${WORK_DIR}/calls.log"
STDOUT_FILE="${WORK_DIR}/stdout"
STDERR_FILE="${WORK_DIR}/stderr"

CONFIG_DIR="${FAKE_HOME}/.affine/config"
PRIVATE_KEY="${CONFIG_DIR}/private.key"

failures=0
current_case=''

mkdir -p "$STUB_DIR" "$FAKE_HOME"

# The one external command the script shells out to. It records argv and then
# defers to STUB_YARN_MODE for whether to succeed, so a single stub covers both
# the happy path and the failure branches below.
cat > "${STUB_DIR}/yarn" <<'STUB'
#!/bin/sh
printf 'yarn' >> "$STUB_CALL_LOG"
for stub_arg in "$@"; do
  printf ' %s' "$stub_arg" >> "$STUB_CALL_LOG"
done
printf '\n' >> "$STUB_CALL_LOG"

case "${STUB_YARN_MODE:-ok}" in
  resolve-not-failed)
    if [ "${1:-}" = 'prisma' ] && [ "${2:-}" = 'migrate' ] && [ "${3:-}" = 'resolve' ]; then
      printf 'migration cannot be rolled back because it is not in a failed state\n' >&2
      exit 1
    fi
    ;;
  seed-fails)
    if [ "${1:-}" = 'cli' ] && [ "${2:-}" = 'standard-seed' ]; then
      printf 'seed exploded\n' >&2
      exit 1
    fi
    ;;
esac

exit 0
STUB
chmod +x "${STUB_DIR}/yarn"

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

# run <case name> — STUB_YARN_MODE comes from the caller.
run() {
  current_case=$1
  shift

  : > "$CALL_LOG"

  set +e
  env \
    PATH="${STUB_DIR}:${PATH}" \
    HOME="$FAKE_HOME" \
    STUB_CALL_LOG="$CALL_LOG" \
    STUB_YARN_MODE="${STUB_YARN_MODE:-ok}" \
    node "$PREDEPLOY" > "$STDOUT_FILE" 2> "$STDERR_FILE"
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

expect_call_count() {
  expect_count_actual=$(grep -c -- "$1" "$CALL_LOG" || true)
  if [ "$expect_count_actual" -ne "$2" ]; then
    report_failure "expected $2 calls matching '$1', got $expect_count_actual"
  fi
}

# expect_call_order <earlier> <later> — both must be present, in this order.
expect_call_order() {
  order_earlier=$(grep -n -- "$1" "$CALL_LOG" | head -n 1 | cut -d: -f1)
  order_later=$(grep -n -- "$2" "$CALL_LOG" | head -n 1 | cut -d: -f1)

  if [ -z "$order_earlier" ] || [ -z "$order_later" ]; then
    report_failure "expected both '$1' and '$2' to be called"
    return
  fi

  if [ "$order_earlier" -ge "$order_later" ]; then
    report_failure "expected '$1' to be called before '$2'"
  fi
}

expect_stdout_contains() {
  if ! grep -qF -- "$1" "$STDOUT_FILE"; then
    report_failure "expected stdout to contain '$1'"
  fi
}

expect_stdout_missing() {
  if grep -qF -- "$1" "$STDOUT_FILE"; then
    report_failure "expected stdout not to contain '$1'"
  fi
}

# Every line the script prints is a bootstrap notice, and every bootstrap notice
# carries the prefix. A line without it came from somewhere that bypassed the
# helper, which is the thing the prefix rule exists to catch.
expect_every_stdout_line_prefixed() {
  if [ ! -s "$STDOUT_FILE" ]; then
    report_failure 'expected at least one notice on stdout'
    return
  fi

  if grep -qvE '^\[predeploy\] ' "$STDOUT_FILE"; then
    report_failure 'every stdout line must carry the `[predeploy] ` prefix'
  fi
}

# ---------------------------------------------------------------------------
# First run: an empty home and an empty database.
#
# All three steps run, in the order the server needs them — the seed inserts a
# row, so it cannot precede the migrations that create the table to hold it.
# ---------------------------------------------------------------------------
cd "$APP_DIR"

run 'first run'
expect_status 0
expect_call_count 'yarn prisma migrate deploy' 1
expect_call_count 'yarn cli run' 1
expect_call_count 'yarn cli standard-seed' 1
expect_call_order 'yarn prisma migrate deploy' 'yarn cli run'
expect_call_order 'yarn cli run' 'yarn cli standard-seed'
expect_every_stdout_line_prefixed
expect_stdout_contains 'Created `private.key`'

if [ ! -s "$PRIVATE_KEY" ]; then
  report_failure 'expected a private key to be generated'
fi

FIRST_KEY=$(cat "$PRIVATE_KEY")

# ---------------------------------------------------------------------------
# Second run over the same home: the DoneWhen case. Nothing is regenerated,
# nothing errors, and the seed is still reached — its own skip is what makes
# re-running safe, and that belongs to the command, not to this script.
# ---------------------------------------------------------------------------
run 'second run'
expect_status 0
expect_call_count 'yarn cli standard-seed' 1
expect_every_stdout_line_prefixed
expect_stdout_contains 'Kept the existing `private.key`'
expect_stdout_missing 'Created `private.key`'

if [ "$(cat "$PRIVATE_KEY")" != "$FIRST_KEY" ]; then
  report_failure 'a second run replaced the private key it should have kept'
fi

# ---------------------------------------------------------------------------
# A rollback the database refuses because there is nothing to roll back is the
# normal case on every boot after the first. It is reported and stepped over,
# never raised.
# ---------------------------------------------------------------------------
STUB_YARN_MODE='resolve-not-failed' run 'rollback not applicable'
expect_status 0
expect_call_count 'yarn cli standard-seed' 1
expect_every_stdout_line_prefixed
STUB_YARN_MODE='ok'

# ---------------------------------------------------------------------------
# Fail loudly: a seed that genuinely fails must not be swallowed. The entrypoint
# execs the server on this script's success, so a silent failure here would
# start a server over a database nobody finished preparing.
# ---------------------------------------------------------------------------
STUB_YARN_MODE='seed-fails' run 'seed fails'
if [ "$run_status" -eq 0 ]; then
  report_failure 'expected a failing seed to fail the script'
fi
STUB_YARN_MODE='ok'

# ---------------------------------------------------------------------------
# The manifest script and this script must name the same steps. `yarn predeploy`
# is what the Helm migration job runs; if it stops seeding, one deployment path
# comes up with no administrator and the other does not.
# ---------------------------------------------------------------------------
current_case='package.json predeploy stays in step'
: > "$CALL_LOG"
: > "$STDOUT_FILE"
: > "$STDERR_FILE"
PREDEPLOY_SCRIPT=$(node -e 'process.stdout.write(require("./package.json").scripts.predeploy)')
for required_step in 'prisma migrate deploy' 'cli run' 'cli standard-seed'; do
  case "$PREDEPLOY_SCRIPT" in
    *"$required_step"*) ;;
    *) report_failure "package.json predeploy does not run '${required_step}'" ;;
  esac
done

# ---------------------------------------------------------------------------
if [ "$failures" -ne 0 ]; then
  printf '\n%d assertion(s) failed.\n' "$failures" >&2
  exit 1
fi

printf 'self-host-predeploy.js: all assertions passed.\n'
