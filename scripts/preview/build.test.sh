#!/bin/sh
# Branch coverage for scripts/preview/build.sh.
#
#   sh scripts/preview/build.test.sh
#
# The build script's job is to run one fixed sequence against whatever toolchain
# the host turns out to have, and to refuse rather than half-finish. That is what
# is tested here: which commands it runs and in which order, which toolchain
# branch it takes, what it tells the reader, that the frontends land where the
# server looks for them, and that a step which exits zero without writing its
# artifact stops the build.
#
# Every case runs against a fixture repository of its own — a directory holding
# only the files the script reads (.nvmrc, rust-toolchain.toml, a vendored Yarn
# release) — with PATH narrowed to a directory this suite fills. Narrowed on
# purpose: "rustup is not installed" cannot be stated on a machine that has
# rustup, and a build script that reaches for a real toolchain from a test suite
# is a build script nobody can test twice the same way.
#
# The vendored Yarn release in the fixture is a Node program that records its
# arguments and writes the artifacts a real build would write. It is reached
# through the same shim the script installs, so these cases also prove the shim
# points `yarn` at the release the repository pins.
#
# What this cannot cover, and what `sh scripts/preview/build.sh` on a real
# checkout still has to: that rspack, napi and the bundler actually produce a
# server that runs. Stubs prove the wiring, not the compilers.

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
BUILD_SCRIPT="${SCRIPT_DIR}/build.sh"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT INT TERM

CALL_LOG="${WORK_DIR}/calls.log"
ENV_LOG="${WORK_DIR}/env.log"
STDOUT_FILE="${WORK_DIR}/stdout"
STDERR_FILE="${WORK_DIR}/stderr"

failures=0
current_case=''
repo=''

# ---------------------------------------------------------------------------
# The fixture repository.
# ---------------------------------------------------------------------------
PINNED_NODE='22.23.2'
PINNED_RUST='1.97.1'
YARN_VERSION='4.18.0'

# The vendored Yarn release, standing in for the real one. Two jobs: record the
# invocation, and write what that invocation promises, so that the script's
# artifact assertions have something to find. STUB_YARN_SKIP names a build whose
# artifacts are withheld — a tool exiting zero with nothing to show for it.
write_fake_yarn_release() {
  cat > "$1" <<'RELEASE'
const fs = require('node:fs');
const path = require('node:path');

const args = process.argv.slice(2);
fs.appendFileSync(process.env.STUB_CALL_LOG, `yarn ${args.join(' ')}\n`);

for (const name of [
  'BUILD_TYPE',
  'GITHUB_SHA',
  'HUSKY',
  'CC',
  'ELECTRON_SKIP_BINARY_DOWNLOAD',
  'PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD',
  'SENTRYCLI_SKIP_DOWNLOAD',
]) {
  fs.appendFileSync(
    process.env.STUB_ENV_LOG,
    `${name}=${process.env[name] ?? ''}\n`
  );
}

const write = (file, body) => {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, body);
};

const target = args.join(' ');
const skip = process.env.STUB_YARN_SKIP || '';

if (skip === '' || !target.includes(skip)) {
  if (target === 'workspace @affine/server-native build') {
    write('packages/backend/native/server-native.node', 'addon');
  } else if (target === 'affine @affine/web build') {
    write('packages/frontend/apps/web/dist/selfhost.html', 'web selfhost');
    write('packages/frontend/apps/web/dist/index.html', 'web index');
    write('packages/frontend/apps/web/dist/assets/app.js', 'web asset');
  } else if (target === 'affine @affine/admin build') {
    write('packages/frontend/admin/dist/selfhost.html', 'admin selfhost');
    write('packages/frontend/admin/dist/index.html', 'admin index');
  } else if (target === 'workspace @affine/server build') {
    write('packages/backend/server/dist/main.js', 'server bundle');
    write('packages/backend/server/dist/server-native.node', 'addon');
  }
}
RELEASE
}

# A repository the script can be pointed at: the three files it reads, the
# script itself at the path it resolves its root from, and nothing else.
new_repo() {
  repo="${WORK_DIR}/repo-$1"
  rm -rf "$repo"
  mkdir -p "${repo}/.yarn/releases" "${repo}/scripts/preview"

  printf '%s\n' "$PINNED_NODE" > "${repo}/.nvmrc"
  printf '[toolchain]\nchannel = "%s"\nprofile = "default"\n' "$PINNED_RUST" \
    > "${repo}/rust-toolchain.toml"
  write_fake_yarn_release "${repo}/.yarn/releases/yarn-${YARN_VERSION}.cjs"
  cp "$BUILD_SCRIPT" "${repo}/scripts/preview/build.sh"
}

# ---------------------------------------------------------------------------
# The case's PATH.
#
# Filled per case, so that "rustup is on PATH" and "nothing is" are both facts
# the case states rather than properties of the machine. The real programs the
# script cannot be tested without — a shell, Node, and the file utilities it
# shells out to — are linked in; everything else is a stub or absent.
# ---------------------------------------------------------------------------
new_path() {
  CASE_BIN="${WORK_DIR}/bin"
  rm -rf "$CASE_BIN"
  mkdir -p "$CASE_BIN"

  for real in sh cat mktemp chmod sed head tr cp rm mkdir dirname; do
    real_path=$(command -v "$real") ||
      { printf 'the suite needs %s on PATH\n' "$real" >&2; exit 70; }
    ln -s "$real_path" "${CASE_BIN}/${real}"
  done
}

# The interpreter, not whatever launches it. `node` on a developer's PATH is
# often a version manager's shim, and a shim resolves its version from the
# environment — which a case deliberately empties. process.execPath is the
# binary that shim would have ended up running, so linking it keeps the cases
# from depending on a resolver they took the inputs away from.
NODE_BIN=$(node -e 'process.stdout.write(process.execPath)')

# A stub that records its arguments and exits zero.
#
# The target is removed before it is written. Without that, a name that is also
# linked into the case's PATH would be written *through* the link, and the file
# a stub replaced would be the real program on the machine running the suite.
add_stub() {
  rm -f "${CASE_BIN}/$1"
  cat > "${CASE_BIN}/$1" <<STUB
#!/bin/sh
printf '%s' "$1" >> "\$STUB_CALL_LOG"
for stub_arg in "\$@"; do
  printf ' %s' "\$stub_arg" >> "\$STUB_CALL_LOG"
done
printf '\n' >> "\$STUB_CALL_LOG"
exit 0
STUB
  chmod +x "${CASE_BIN}/$1"
}

# node, reporting whichever version the case wants and otherwise being node.
# The version line is a decision the script reports, and a suite that could only
# state the version this machine happens to run could not test the other side
# of it.
add_node_stub() {
  rm -f "${CASE_BIN}/node"
  cat > "${CASE_BIN}/node" <<STUB
#!/bin/sh
if [ "\${1:-}" = '--version' ]; then
  printf 'v%s\n' "\${STUB_NODE_VERSION:-${PINNED_NODE}}"
  exit 0
fi
exec "${NODE_BIN}" "\$@"
STUB
  chmod +x "${CASE_BIN}/node"
}

# git, answering `rev-parse HEAD` with a fixed commit. Absent in the cases that
# state an exported source tree, which is a tree with no git history to read.
FIXTURE_SHA='1234567890123456789012345678901234567890'
add_git_stub() {
  rm -f "${CASE_BIN}/git"
  cat > "${CASE_BIN}/git" <<STUB
#!/bin/sh
printf 'git %s\n' "\$*" >> "\$STUB_CALL_LOG"
if [ "\${1:-}" = 'rev-parse' ]; then
  printf '%s\n' '${FIXTURE_SHA}'
  exit 0
fi
exit 1
STUB
  chmod +x "${CASE_BIN}/git"
}

# curl, standing in for the rustup installer's download. It prints the installer
# rather than fetching it, and the printed installer does what rustup-init does
# to the shape of the host: it puts a rustup on PATH under CARGO_HOME. The
# script pipes this into `sh -s --`, so the arguments it was handed are recorded
# by the installer itself — which is the only place they can be observed.
add_curl_stub() {
  rm -f "${CASE_BIN}/curl"
  cat > "${CASE_BIN}/curl" <<STUB
#!/bin/sh
printf 'curl %s\n' "\$*" >> "\$STUB_CALL_LOG"
cat <<'INSTALLER'
printf 'rustup-init %s\n' "\$*" >> "\$STUB_CALL_LOG"
mkdir -p "\$CARGO_HOME/bin"
cat > "\$CARGO_HOME/bin/rustup" <<'RUSTUP'
#!/bin/sh
printf 'rustup' >> "\$STUB_CALL_LOG"
for stub_arg in "\$@"; do
  printf ' %s' "\$stub_arg" >> "\$STUB_CALL_LOG"
done
printf '\n' >> "\$STUB_CALL_LOG"
exit 0
RUSTUP
chmod +x "\$CARGO_HOME/bin/rustup"
INSTALLER
exit 0
STUB
  chmod +x "${CASE_BIN}/curl"
}

# The same download, ending with nothing installed — an installer that exits
# zero after failing to place a binary. Rare, and the reason the script checks
# instead of assuming.
add_empty_curl_stub() {
  rm -f "${CASE_BIN}/curl"
  cat > "${CASE_BIN}/curl" <<STUB
#!/bin/sh
printf 'curl %s\n' "\$*" >> "\$STUB_CALL_LOG"
printf ': installed nothing\n'
exit 0
STUB
  chmod +x "${CASE_BIN}/curl"
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

  set +e
  env -i \
    PATH="$CASE_BIN" \
    HOME="${WORK_DIR}/home" \
    CARGO_HOME="${WORK_DIR}/cargo" \
    STUB_CALL_LOG="$CALL_LOG" \
    STUB_ENV_LOG="$ENV_LOG" \
    STUB_NODE_VERSION="${CASE_NODE_VERSION:-}" \
    STUB_YARN_SKIP="${CASE_YARN_SKIP:-}" \
    CC="${CASE_CC:-}" \
    GITHUB_SHA="${CASE_GITHUB_SHA:-}" \
    sh "${repo}/scripts/preview/build.sh" > "$STDOUT_FILE" 2> "$STDERR_FILE"
  run_status=$?
  set -e

  unset CASE_NODE_VERSION CASE_YARN_SKIP CASE_CC CASE_GITHUB_SHA
  rm -rf "${WORK_DIR}/cargo" "${WORK_DIR}/home"
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

# The order of the builds is the point of the script: the addon before the
# bundle that copies it, the frontends before they are staged. Asserted as one
# sequence rather than as five memberships, because five memberships hold just
# as well when the order is wrong.
expect_yarn_sequence() {
  actual=$(grep '^yarn ' "$CALL_LOG" | tr '\n' '|')
  if [ "$actual" != "$1" ]; then
    report_failure "expected yarn sequence: $1
      got:                   $actual"
  fi
}

expect_build_environment() {
  if ! grep -qxF -- "$1" "$ENV_LOG"; then
    report_failure "expected the builders to be run with: $1"
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

expect_file() {
  if [ ! -f "${repo}/$1" ]; then
    report_failure "expected the build to leave $1"
  fi
}

expect_no_file() {
  if [ -e "${repo}/$1" ]; then
    report_failure "expected the build not to leave $1"
  fi
}

expect_file_content() {
  if [ "$(cat "${repo}/$1" 2>/dev/null)" != "$2" ]; then
    report_failure "expected $1 to hold '$2'"
  fi
}

# ---------------------------------------------------------------------------
# The notices, verbatim. Duplicated from the script on purpose: the wording is a
# recorded design decision (cli-target-notice, build-step extension), so a silent
# edit to it fails a test rather than passing review unnoticed.
# ---------------------------------------------------------------------------
NOTICE_NODE_PINNED='[preview] Node v22.23.2 is on PATH — the major version `.nvmrc` pins (22.23.2).'
NOTICE_NODE_OTHER='[preview] Node v24.4.0 is on PATH and `.nvmrc` pins 22.23.2 — the build runs on what is here; install the pinned version if a step below fails on a language feature.'
NOTICE_YARN='[preview] `yarn` is the release this repository vendors (4.18.0) for the rest of this build — whatever `yarn` was on PATH is left unread.'
NOTICE_RUST_INSTALLED='[preview] Rust 1.97.1 is installed — the channel `rust-toolchain.toml` pins; edit that file to build the addon with another.'
NOTICE_RUST_NO_RUSTUP='[preview] `cargo` is on PATH without `rustup`, so the pin in `rust-toolchain.toml` (1.97.1) is reported and not applied — install rustup to have it honoured.'
NOTICE_RUSTUP_INSTALL='[preview] Neither `rustup` nor `cargo` is on PATH — installing rustup, then the toolchain `rust-toolchain.toml` pins (1.97.1); install rustup yourself to keep this build off the network.'
NOTICE_CC_DEFAULT='[preview] `CC` was empty — the addon'"'"'s C dependencies are compiled with `cc -D_BSD_SOURCE`; set `CC` to choose the compiler yourself.'
NOTICE_CC_SET='[preview] `CC` is set to `gcc` — the addon'"'"'s C dependencies are compiled with it; unset it to let this script pick one.'
NOTICE_SHA_FROM_GIT="[preview] \`GITHUB_SHA\` was empty — the bundles are stamped with this checkout's commit ${FIXTURE_SHA}; set it to stamp another."
NOTICE_SHA_PLACEHOLDER='[preview] `GITHUB_SHA` was empty and this tree is not a git repository — the bundles are stamped with a placeholder commit; set `GITHUB_SHA` to stamp the real one.'
NOTICE_SHA_SET="[preview] \`GITHUB_SHA\` is set — the bundles are stamped with commit ${FIXTURE_SHA}."

STEP_INSTALL='[preview] 1/6 Installing workspace dependencies from the lockfile — `yarn install --immutable --inline-builds`.'
STEP_NATIVE='[preview] 2/6 Building the native addon the server loads — `yarn workspace @affine/server-native build`.'
STEP_WEB='[preview] 3/6 Building the web frontend — `yarn affine @affine/web build`.'
STEP_ADMIN='[preview] 4/6 Building the admin frontend — `yarn affine @affine/admin build`.'
STEP_SERVER='[preview] 5/6 Bundling the server — `yarn workspace @affine/server build`.'
STEP_STAGE='[preview] 6/6 Staging the frontends into `packages/backend/server/static` — the directory the server serves from.'
NOTICE_DONE='[preview] Build complete — `packages/backend/server/dist/main.js`, `packages/backend/server/dist/server-native.node` and `packages/backend/server/static/` are in place.'

YARN_SEQUENCE='yarn install --immutable --inline-builds|yarn workspace @affine/server-native build|yarn affine @affine/web build|yarn affine @affine/admin build|yarn workspace @affine/server build|'

# ---------------------------------------------------------------------------
# A host with rustup: the whole sequence, in order, and everything it leaves
# behind. This is the case the preview platform runs.
# ---------------------------------------------------------------------------
new_repo 'happy'
new_path
add_node_stub
add_stub 'rustup'
add_git_stub
# The static directory carries a file from an earlier build, which the staging
# step must not preserve: a stale asset is served as confidently as a fresh one.
mkdir -p "${repo}/packages/backend/server/static"
printf 'stale\n' > "${repo}/packages/backend/server/static/stale.html"

run 'rustup on PATH, full sequence'
expect_status 0
expect_yarn_sequence "$YARN_SEQUENCE"
expect_called 'rustup toolchain install 1.97.1'

expect_stdout_line "$NOTICE_NODE_PINNED"
expect_stdout_line "$NOTICE_YARN"
expect_stdout_line "$NOTICE_RUST_INSTALLED"
expect_stdout_line "$NOTICE_CC_DEFAULT"
expect_stdout_line "$NOTICE_SHA_FROM_GIT"
expect_stdout_line "$STEP_INSTALL"
expect_stdout_line "$STEP_NATIVE"
expect_stdout_line "$STEP_WEB"
expect_stdout_line "$STEP_ADMIN"
expect_stdout_line "$STEP_SERVER"
expect_stdout_line "$STEP_STAGE"
expect_stdout_line "$NOTICE_DONE"

# The three artifacts the preview starts from.
expect_file 'packages/backend/server/dist/main.js'
expect_file 'packages/backend/server/dist/server-native.node'
expect_file 'packages/backend/server/static/selfhost.html'
# The frontends are staged as contents, not as a nested dist directory, and the
# admin bundle lands under the path the server serves /admin from.
expect_file 'packages/backend/server/static/assets/app.js'
expect_file 'packages/backend/server/static/admin/selfhost.html'
expect_no_file 'packages/backend/server/static/dist'
expect_no_file 'packages/backend/server/static/stale.html'
expect_file_content 'packages/backend/server/static/selfhost.html' 'web selfhost'
expect_file_content 'packages/backend/server/static/admin/selfhost.html' 'admin selfhost'

# What the builders were handed. `stable` is what keeps the canary-only mobile
# routes out of a build that has no mobile bundle, and the three skips are what
# keep an Electron runtime and a browser matrix off a preview host.
expect_build_environment 'BUILD_TYPE=stable'
expect_build_environment "GITHUB_SHA=${FIXTURE_SHA}"
expect_build_environment 'HUSKY=0'
expect_build_environment 'ELECTRON_SKIP_BINARY_DOWNLOAD=1'
expect_build_environment 'PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1'
expect_build_environment 'SENTRYCLI_SKIP_DOWNLOAD=1'

# ---------------------------------------------------------------------------
# A host one Node major ahead of the pin. Reported, not refused: the manifest's
# range is what the packages are built against, and being told which version
# built them is what makes a strange failure readable.
# ---------------------------------------------------------------------------
new_repo 'node-version'
new_path
add_node_stub
add_stub 'rustup'
add_git_stub

CASE_NODE_VERSION='24.4.0'
run 'node major ahead of the pin'
expect_status 0
expect_stdout_line "$NOTICE_NODE_OTHER"
expect_yarn_sequence "$YARN_SEQUENCE"

# ---------------------------------------------------------------------------
# A host with a toolchain but no rustup. Nothing is installed underneath it —
# two toolchain managers on one machine is how a build starts producing a
# binary nobody can account for — and the pin is reported instead.
# ---------------------------------------------------------------------------
new_repo 'cargo-only'
new_path
add_node_stub
add_stub 'cargo'
add_git_stub

run 'cargo without rustup'
expect_status 0
expect_stdout_line "$NOTICE_RUST_NO_RUSTUP"
expect_not_called 'rustup'
expect_yarn_sequence "$YARN_SEQUENCE"

# ---------------------------------------------------------------------------
# A host with no Rust at all — the shape a preview platform's Node image has.
# rustup is fetched, the pinned toolchain installed through it, and the build
# then runs to the end.
# ---------------------------------------------------------------------------
new_repo 'no-rust'
new_path
add_node_stub
add_curl_stub
add_git_stub

run 'no rust toolchain, rustup installed'
expect_status 0
expect_stdout_line "$NOTICE_RUSTUP_INSTALL"
expect_called 'rustup-init -y --no-modify-path --default-toolchain none'
expect_called 'rustup toolchain install 1.97.1'
expect_yarn_sequence "$YARN_SEQUENCE"

# ---------------------------------------------------------------------------
# The same host without curl. Nothing to install rustup with, so the build stops
# before it installs a single dependency, saying what to install.
# ---------------------------------------------------------------------------
new_repo 'no-rust-no-curl'
new_path
add_node_stub
add_git_stub

run 'no rust toolchain and no curl'
expect_status 1
expect_stderr_line '[preview] neither `rustup` nor `cargo` is on PATH, and `curl` is not there to install one — the native addon is compiled from Rust; install rustup from https://rustup.rs and run this script again.'
expect_not_called 'yarn'
expect_no_file 'packages/backend/server/dist/main.js'

# ---------------------------------------------------------------------------
# An installer that returns successfully and installs nothing. The build stops
# on the check rather than on a Rust error four steps down, in a language about
# missing crates.
# ---------------------------------------------------------------------------
new_repo 'rustup-install-empty'
new_path
add_node_stub
add_empty_curl_stub
add_git_stub

run 'rustup installer leaves nothing behind'
expect_status 1
expect_stderr_line "[preview] rustup was installed but is not on PATH — expected it under \`${WORK_DIR}/cargo/bin\`; install rustup yourself and run this script again."
expect_not_called 'yarn'

# ---------------------------------------------------------------------------
# A caller who set CC, and a host carrying clang. Both are decisions, and both
# are reported.
# ---------------------------------------------------------------------------
new_repo 'cc-set'
new_path
add_node_stub
add_stub 'rustup'
add_git_stub

CASE_CC='gcc'
run 'CC set by the caller'
expect_status 0
expect_stdout_line "$NOTICE_CC_SET"
expect_build_environment 'CC=gcc'

new_repo 'cc-clang'
new_path
add_node_stub
add_stub 'rustup'
add_stub 'clang'
add_git_stub

run 'clang on PATH'
expect_status 0
expect_stdout_line '[preview] `CC` was empty — the addon'"'"'s C dependencies are compiled with `clang -D_BSD_SOURCE`; set `CC` to choose the compiler yourself.'
expect_build_environment 'CC=clang -D_BSD_SOURCE'

# ---------------------------------------------------------------------------
# The commit stamped into the bundles: handed over, read from the checkout, or
# absent because the tree was exported without its history.
# ---------------------------------------------------------------------------
new_repo 'sha-set'
new_path
add_node_stub
add_stub 'rustup'
add_git_stub

CASE_GITHUB_SHA="$FIXTURE_SHA"
run 'GITHUB_SHA handed over'
expect_status 0
expect_stdout_line "$NOTICE_SHA_SET"
expect_not_called 'git rev-parse'

new_repo 'sha-absent'
new_path
add_node_stub
add_stub 'rustup'

run 'no git history to read'
expect_status 0
expect_stdout_line "$NOTICE_SHA_PLACEHOLDER"
expect_build_environment 'GITHUB_SHA=0000000000000000000000000000000000000000'

# ---------------------------------------------------------------------------
# A build tool that exits zero without writing its artifact. The build stops
# there: a preview started from a half-staged tree answers its first screen with
# a 404, and the reason would be pages above in the log.
# ---------------------------------------------------------------------------
new_repo 'silent-failure'
new_path
add_node_stub
add_stub 'rustup'
add_git_stub

CASE_YARN_SKIP='workspace @affine/server build'
run 'server bundle missing after a zero exit'
expect_status 1
expect_stderr_line '[preview] `packages/backend/server/dist/main.js` was not produced — `yarn workspace @affine/server build` returned successfully without writing it, so the preview has nothing to start.'
expect_stdout_line "$STEP_SERVER"
# The staging step is never reached, so nothing is served from a tree that has
# no server to serve it.
expect_stdout_lacks '6/6'
expect_no_file 'packages/backend/server/static'

# ---------------------------------------------------------------------------
# A checkout without the vendored Yarn release. .yarnrc.yml points yarnPath at
# it, so the tree is incomplete and no install from it would mean anything.
# ---------------------------------------------------------------------------
new_repo 'no-yarn-release'
new_path
add_node_stub
add_stub 'rustup'
add_git_stub
rm -f "${repo}/.yarn/releases/yarn-${YARN_VERSION}.cjs"

run 'no vendored yarn release'
expect_status 1
expect_stderr_line '[preview] no Yarn release is vendored in `.yarn/releases` — `.yarnrc.yml` points `yarnPath` at one, and this checkout is incomplete without it.'
expect_not_called 'rustup'

# ---------------------------------------------------------------------------
if [ "$failures" -ne 0 ]; then
  printf '\n%d assertion(s) failed.\n' "$failures" >&2
  exit 1
fi

printf 'preview/build.sh: all branch assertions passed.\n'
