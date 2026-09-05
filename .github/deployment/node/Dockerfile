# syntax=docker/dockerfile:1.7

# AFFiNE server image, built from the sources in this repository.
#
# The build is split so that dependency installation — the slowest and least
# volatile step — is cached independently from application code.

ARG NODE_IMAGE=node:22-bookworm-slim

# ---------------------------------------------------------------------------
# manifests — reduce the build context to the files `yarn install` reads.
#
# The workspace holds 100+ package.json files; spelling them out as COPY lines
# would rot every time a package is added, moved or removed. Pruning here keeps
# the deps stage below cache-valid until a manifest, the lockfile, a patch or
# the vendored Yarn release actually changes.
# ---------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS manifests
WORKDIR /src

COPY . .

# Roots mirror the `workspaces` globs in the root package.json. Anything else
# in the context (docs, CI config, editor state) is intentionally dropped.
RUN set -eux; \
  mkdir -p /manifests/.yarn; \
  find package.json blocksuite docs/reference packages tests tools \
    -name node_modules -prune -o -name package.json -print0 > /tmp/manifest.list; \
  tar --null --create --file /tmp/manifest.tar --files-from /tmp/manifest.list; \
  tar --extract --file /tmp/manifest.tar --directory /manifests; \
  cp yarn.lock .yarnrc.yml /manifests/; \
  cp -R .yarn/releases /manifests/.yarn/releases; \
  cp -R .yarn/patches /manifests/.yarn/patches

# ---------------------------------------------------------------------------
# deps — install the workspace dependencies from the lockfile.
# ---------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS deps
WORKDIR /app

# python3/make/g++: node-gyp toolchain, for packages that compile from source.
# git:              two dependencies resolve from git remotes (see yarn.lock).
# openssl:          TLS, and Prisma's engine/runtime lookup.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    g++ \
    git \
    make \
    openssl \
    python3 \
  && rm -rf /var/lib/apt/lists/*

# Every dependency comes from the public registry, so no credential is needed
# or accepted here: NONE is the placeholder .yarnrc.yml already falls back to.
ENV CI=true \
    NPM_TOKEN=NONE

COPY --from=manifests /manifests /app

# The Yarn release is vendored in .yarn/releases, so the package manager itself
# is never downloaded — it is pinned by the same commit as the lockfile.
#
# --immutable    fails the build if the lockfile does not already satisfy the
#                manifests, instead of silently resolving something new.
# --mode=skip-build  fetch and link only. Build scripts are deferred because
#                this stage deliberately has no application sources: the
#                workspace postinstalls (prisma generate, template bundling)
#                read files that arrive with the source tree, and dependency
#                build scripts are untrusted code we do not need here. The
#                stage that owns the source tree runs them.
# enableScripts=false  matches .yarnrc.yml, and is repeated on the command so
#                it constrains this install only, not the stages built on top.
RUN --mount=type=cache,target=/root/.yarn/berry/cache,sharing=locked \
  set -eux; \
  set -- .yarn/releases/yarn-*.cjs; \
  yarn_release="$1"; \
  test -f "$yarn_release"; \
  YARN_ENABLE_SCRIPTS=false node "$yarn_release" install --immutable --mode=skip-build; \
  test -d node_modules


# ---------------------------------------------------------------------------
# build — compile the native addon and bundle the applications.
#
# This stage owns the source tree, so it also runs the work `deps` deferred:
# the `built: true` dependency scripts and the two workspace postinstalls
# (`@affine/server` -> `prisma generate`, `@affine/templates` -> asset codegen).
#
# Architecture: the native addon is compiled for the build host only, with no
# `--target` and no cross toolchain. Producing a multi-architecture image is a
# `docker buildx build --platform` concern, not a second Cargo target — see
# context/decisions/2026-09-05-docker-build-stage-single-arch.md.
# ---------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS build
WORKDIR /app

# On top of the node-gyp toolchain the deps stage needs, the Rust build pulls
# several `-sys` crates that compile C from source:
#   clang       tree-sitter (via doc_extractor) and libwebp-sys
#   cmake, perl aws-lc-rs, the crypto provider behind rustls
#   libssl-dev, pkg-config  -sys crate discovery
#   curl        fetches rustup-init below
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    clang \
    cmake \
    curl \
    g++ \
    git \
    libssl-dev \
    make \
    openssl \
    perl \
    pkg-config \
    python3 \
  && rm -rf /var/lib/apt/lists/*

ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH

# The toolchain is pinned by rust-toolchain.toml, copied on its own so the
# (slow) toolchain download is not invalidated by an unrelated source edit.
# rustup would read the file implicitly, but resolving the channel here makes
# the failure obvious if the pin is ever removed.
#
# rustup itself comes from sh.rustup.rs over a pinned-protocol TLS connection —
# the upstream-recommended path, and the same one .github/actions/build-rust
# takes. The toolchain it then fetches is signature-checked by rustup, so the
# thing that actually compiles code is verified even though the installer is
# fetched by version-floating URL.
COPY rust-toolchain.toml ./
RUN set -eux; \
  curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs \
    | sh -s -- -y --no-modify-path --default-toolchain none; \
  channel="$(sed -n 's/^[[:space:]]*channel[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' rust-toolchain.toml | head -n 1)"; \
  test -n "$channel"; \
  rustup toolchain install "$channel"; \
  rustup default "$channel"; \
  cargo --version

# HUSKY:                        the root postinstall installs git hooks, and
#                               .git is deliberately outside the build context.
# ELECTRON/PLAYWRIGHT/SENTRYCLI: install scripts that would otherwise download
#                               hundreds of megabytes of binaries the server
#                               image never runs.
ENV CI=true \
    NPM_TOKEN=NONE \
    HUSKY=0 \
    ELECTRON_SKIP_BINARY_DOWNLOAD=1 \
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
    SENTRYCLI_SKIP_DOWNLOAD=1

COPY --from=deps /app/node_modules ./node_modules
COPY . .

# The image ships whatever the repository pins. The `yarn` on the base image is
# Classic and does not honour .yarnrc.yml's yarnPath, so point the name at the
# vendored release once instead of spelling out `node .yarn/releases/...` at
# every call site — workspace scripts invoke `yarn` by name too.
RUN set -eux; \
  set -- .yarn/releases/yarn-*.cjs; \
  yarn_release="$1"; \
  test -f "$yarn_release"; \
  printf '#!/bin/sh\nexec node "/app/%s" "$@"\n' "$yarn_release" > /usr/local/bin/yarn; \
  chmod +x /usr/local/bin/yarn; \
  yarn --version

# Second install: the tree is complete now, so the deferred build scripts can
# run. --immutable still holds — nothing above changed the lockfile.
RUN --mount=type=cache,target=/root/.yarn/berry/cache,sharing=locked \
  set -eux; \
  yarn install --immutable --inline-builds; \
  test -d node_modules/.prisma/client

# BUILD_TYPE  selects the release channel baked into the frontend bundles;
#             `stable` is the channel a self-hosted image ships.
# GITHUB_SHA  is stamped into the HTML and the assets manifest. The bundler
#             falls back to reading it out of the git repository, which the
#             build context does not carry, so a value must be supplied. The
#             default keeps `docker build` working; release builds pass the
#             real commit.
ARG BUILD_TYPE=stable
ARG GITHUB_SHA=0000000000000000000000000000000000000000
ENV BUILD_TYPE=${BUILD_TYPE} \
    GITHUB_SHA=${GITHUB_SHA}

# -D_BSD_SOURCE: tree-sitter does not compile against glibc's headers without
# it (tree-sitter/tree-sitter#4186). Mirrors .github/actions/build-rust.
ENV CC="clang -D_BSD_SOURCE" \
    TARGET_CC="clang -D_BSD_SOURCE"

# Cargo's registry and target directory are caches, not artifacts: they stay in
# the build cache and never enter a layer. napi copies the cdylib out of the
# target directory into the package as server-native.node.
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/app/target,sharing=locked \
  set -eux; \
  yarn workspace @affine/server-native build; \
  test -f packages/backend/native/server-native.node

# One frontend per layer: a change to a single app does not rebuild the others.
RUN set -eux; \
  yarn affine @affine/web build; \
  test -f packages/frontend/apps/web/dist/selfhost.html

RUN set -eux; \
  yarn affine @affine/admin build; \
  test -f packages/frontend/admin/dist/selfhost.html

RUN set -eux; \
  yarn affine @affine/mobile build; \
  test -f packages/frontend/apps/mobile/dist/selfhost.html

# Bundles the server into a single dist/main.js, with server-native.node
# emitted alongside it — hence the ordering against the Rust build above.
RUN set -eux; \
  yarn workspace @affine/server build; \
  test -f packages/backend/server/dist/main.js

# The runtime stage follows in the next step of this change.
