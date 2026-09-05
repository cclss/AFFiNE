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
# .charlie/context/decisions/2026-09-05-docker-build-stage-single-arch.md.
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
  test -f packages/backend/server/dist/main.js; \
  test -f packages/backend/server/dist/server-native.node


# ---------------------------------------------------------------------------
# runtime-deps — the production dependency closure of @affine/server.
#
# The `build` stage's node_modules holds the whole workspace: every frontend
# dependency, every toolchain, every test framework. None of it runs the
# server. This stage installs the other tree — `@affine/server` and its
# production dependencies only — from the same lockfile, so the runtime layer
# carries dependencies the server actually loads.
#
# It installs from the pruned manifests rather than the source tree: nothing
# here needs the sources, so an application edit does not re-resolve the
# dependency graph.
# ---------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS runtime-deps
WORKDIR /app

# git:     a handful of dependencies resolve from git remotes (see yarn.lock).
# openssl: Prisma detects its query engine by the installed OpenSSL version,
#          during `prisma generate` here and again when the server connects.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
    openssl \
  && rm -rf /var/lib/apt/lists/*

ENV CI=true \
    NPM_TOKEN=NONE

COPY --from=manifests /manifests /app

# `prisma generate` reads this schema and writes the typed client into
# node_modules/.prisma/client. It is the one source file the install needs.
COPY packages/backend/server/schema.prisma packages/backend/server/schema.prisma

# One layer, three steps, because they are one artifact:
#
#   focus --production   installs the dependency closure of a single workspace.
#                        Build scripts stay off (.yarnrc.yml), except for the
#                        packages the root package.json marks `built: true` —
#                        which is how @prisma/engines fetches its engines.
#   prisma generate      the server's postinstall, run explicitly. Yarn does
#                        run it during the focus install, but only because the
#                        schema is copied above and the build state is cold —
#                        neither is a guarantee, and a server without a
#                        generated Prisma client cannot start.
#   mv                   the final image is the server package, so its
#                        node_modules must sit at the package root. Doing it
#                        inside this RUN keeps the moved tree in one layer
#                        instead of writing it twice.
RUN --mount=type=cache,target=/root/.yarn/berry/cache,sharing=locked \
  set -eux; \
  set -- .yarn/releases/yarn-*.cjs; \
  yarn_release="$1"; \
  test -f "$yarn_release"; \
  node "$yarn_release" workspaces focus @affine/server --production; \
  node "$yarn_release" workspace @affine/server prisma generate; \
  test -d node_modules/.prisma/client; \
  test -x node_modules/.bin/prisma; \
  mv node_modules packages/backend/server/node_modules


# ---------------------------------------------------------------------------
# runtime-assets — assemble /app as the running server expects it, then prune.
#
# Pruning has to happen before the final stage copies the tree: deleting a file
# in the layer that ships it removes nothing from the image. So the layout is
# built here, cleaned here, and lands in the final image as a single COPY.
# ---------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS runtime-assets
WORKDIR /app

# Supplied by BuildKit. docker-clean.mjs uses them to decide which
# architecture's Prisma engines to keep.
ARG TARGETARCH
ARG TARGETVARIANT

# openssl: docker-clean.mjs runs `prisma -v`, which resolves an engine.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    openssl \
  && rm -rf /var/lib/apt/lists/*

COPY --from=runtime-deps /app/packages/backend/server/node_modules ./node_modules
COPY --from=build /app/packages/frontend/apps/web/dist ./static
COPY --from=build /app/packages/frontend/admin/dist ./static/admin
COPY --from=build /app/packages/frontend/apps/mobile/dist ./static/mobile
COPY packages/backend/server/scripts ./scripts
COPY packages/backend/server/schema.prisma ./schema.prisma
# Not decoration: scripts/self-host-predeploy.js shells out to `yarn cli run`,
# and `cli` is a script defined in this manifest. Without it the scripts copied
# above cannot run.
COPY packages/backend/server/package.json ./package.json
# schema.prisma without the migration history is a schema Prisma cannot deploy —
# `prisma migrate deploy` reads this directory, and scripts/self-host-predeploy.js
# (shipped above) calls it.
COPY packages/backend/server/migrations ./migrations

# Drops sourcemaps and development leftovers from node_modules, deduplicates
# identical static assets and Prisma engine copies into hardlinks. Runs before
# dist arrives on purpose: its dist rule keeps the one `server-native.<arch>.node`
# matching TARGETARCH, a rule written for the release pipeline where three
# prebuilt binaries are staged. This build compiles exactly one, named
# `server-native.node`, which that rule would not recognise — and would delete.
RUN AFFINE_DOCKER_CLEAN=1 \
    TARGETARCH="${TARGETARCH}" \
    TARGETVARIANT="${TARGETVARIANT}" \
    node ./scripts/docker-clean.mjs

# The server bundle, and the native addon the bundle requires next to it.
# Sourcemaps are kept here (and only here) so runtime stack traces stay
# readable.
COPY --from=build /app/packages/backend/server/dist ./dist


# ---------------------------------------------------------------------------
# pgdg-key — the signing key of the PostgreSQL APT repository.
#
# Debian bookworm ships PostgreSQL 15. This image embeds 16 with the pgvector
# extension, the pair `.docker/selfhost/compose.yml` has always run as a
# sibling container (`pgvector/pgvector:pg16`), so the packages come from
# apt.postgresql.org — which has to be trusted before it can be read.
#
# The key is fetched in a stage of its own, so that the tools used to fetch and
# check it — curl, its TLS stack, gnupg — are thrown away with the stage and
# the runtime image receives a single armored file. apt reads an ASCII-armored
# key through `signed-by=`, so it needs no gnupg of its own.
#
# Trust chain, in order: the key arrives over a pinned-protocol TLS connection
# from its upstream-published location; its fingerprint is checked against the
# value below, so a substituted key fails the build rather than the build
# trusting whatever it was handed; apt then signature-checks every package
# installed from the repository against that key.
# ---------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS pgdg-key

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
  && rm -rf /var/lib/apt/lists/*

# The fingerprint PostgreSQL publishes for the repository signing key
# (https://www.postgresql.org/download/linux/debian/). It changes when the key
# is rotated, which is the moment this pin should be reviewed rather than bumped
# on sight — an unexpected fingerprint is exactly what it is here to catch.
ARG PGDG_SIGNING_FINGERPRINT=B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8

RUN set -eux; \
  curl --proto '=https' --tlsv1.2 -fsSL \
    https://www.postgresql.org/media/keys/ACCC4CF8.asc -o /pgdg.asc; \
  fingerprint="$( \
    gpg --show-keys --with-colons /pgdg.asc \
      | awk -F: '$1 == "fpr" { print $10; exit }' \
  )"; \
  test "$fingerprint" = "${PGDG_SIGNING_FINGERPRINT}"


# ---------------------------------------------------------------------------
# runtime — the shipped image.
#
# Nothing that built the application is here: no Rust toolchain, no C
# compiler, no source tree, no development dependencies. Just Node, the
# bundle, its production dependencies, the static assets — and a database and
# a cache, so that an image run with no connection details still has both.
# Which of the two it uses is a startup decision, not a build one: this stage
# only puts the servers and their data directories in the image, and names the
# entrypoint that makes the decision.
#
# They live in this stage alone. No build stage installs them: nothing above
# runs a database, and a package in a build stage would be paid for in build
# time without ever reaching the image.
#
# Architecture: apt.postgresql.org publishes amd64, arm64 and ppc64el. This
# stage therefore builds on those three and fails, loudly and at `apt-get`, on
# anything else — armhf (`linux/arm/v7`) included. The Rust build above is
# already single-architecture by design, so a build targets one platform at a
# time; a `--platform` matrix that still lists armhf is a matrix to revisit,
# not a reason to embed a database this repository would then not test on.
# ---------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS runtime
WORKDIR /app

# The major version is pinned and the patch level is not: apt.postgresql.org
# carries only the newest patch release of each major, so pinning one would
# break the build the day it is superseded. 16 matches the sibling image the
# compose stack runs, which is what an existing volume was initialised by.
ARG PG_MAJOR=16

COPY --from=pgdg-key /pgdg.asc /etc/apt/keyrings/pgdg.asc

# ca-certificates    installed from Debian's own repository first, because the
#                    PGDG line below is https and apt verifies the certificate
#                    before it verifies the signature.
# libjemalloc2       see LD_PRELOAD below.
# openssl            Prisma detects its query engine by the installed OpenSSL
#                    version when the server connects.
# postgresql-N       the embedded database.
# postgresql-N-pgvector  the vector type the server's embedding tables
#                    declare, which the sibling image supplied before. The
#                    server disables embeddings below pgvector 0.8
#                    (packages/backend/native/src/runtime/migrations.rs), and
#                    the repository ships a later one.
# redis-server       the embedded cache. Pulls redis-tools, hence redis-cli.
#
# postgresql-common goes in first so `create_main_cluster` can be turned off
# before the server package arrives. Debian would otherwise run initdb during
# the build and ship a cluster under /var/lib/postgresql/N/main that this image
# never starts — the data directory created below is the only one it runs on,
# and a cluster baked into a layer cannot hold data anyway.
#
# The suite codename is read from the base image rather than written out, so a
# NODE_IMAGE on a different Debian release fails loudly at `apt-get update`
# instead of quietly installing bookworm packages.
#
# DEBIAN_FRONTEND is set because postgresql-common carries a debconf question
# (whether new clusters enable SSL). A build has no one to answer it, and the
# answer is irrelevant to an image that creates no cluster at build time.
RUN set -eux; \
  export DEBIAN_FRONTEND=noninteractive; \
  apt-get update; \
  apt-get install -y --no-install-recommends ca-certificates; \
  . /etc/os-release; \
  test -n "${VERSION_CODENAME}"; \
  echo "deb [signed-by=/etc/apt/keyrings/pgdg.asc]" \
    "https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" \
    > /etc/apt/sources.list.d/pgdg.list; \
  apt-get update; \
  apt-get install -y --no-install-recommends postgresql-common; \
  sed -ri 's/^[[:space:]]*#?[[:space:]]*(create_main_cluster)[[:space:]]*=.*/\1 = false/' \
    /etc/postgresql-common/createcluster.conf; \
  grep -qx 'create_main_cluster = false' /etc/postgresql-common/createcluster.conf; \
  apt-get install -y --no-install-recommends \
    libjemalloc2 \
    openssl \
    "postgresql-${PG_MAJOR}" \
    "postgresql-${PG_MAJOR}-pgvector" \
    redis-server; \
  rm -rf /var/lib/apt/lists/*; \
  test ! -d "/var/lib/postgresql/${PG_MAJOR}/main"

# Neither server runs as root: PostgreSQL refuses to start as root, and both
# Debian packages create a service account of their own. So the directories
# they own are created here, owned by the account that will write them, rather
# than left for a startup script to repair.
#
# 0700 is PostgreSQL's own requirement — it refuses to start on a data
# directory that is group- or world-readable. Empty is what `initdb` needs to
# find; populating it is a startup concern.
#
# /var/lib/redis is replaced rather than adjusted: installing redis-server may
# leave a dump file behind, and image layers are not where cache state belongs.
RUN set -eux; \
  install -d -o postgres -g postgres -m 0700 /var/lib/postgresql/data; \
  rm -rf /var/lib/redis; \
  install -d -o redis -g redis -m 0750 /var/lib/redis

# Debian puts the server binaries under a versioned prefix and leaves it off
# PATH — only the client wrappers are linked into /usr/bin. Prepending it makes
# `postgres`, `initdb` and `pg_ctl` callable by name, and pins every one of
# them to the major version installed above instead of whatever a wrapper
# would resolve to at runtime.
ENV PATH=/usr/lib/postgresql/${PG_MAJOR}/bin:${PATH}

# jemalloc keeps the resident set stable under the server's allocation pattern;
# glibc's allocator fragments and grows over long uptimes. Being a process
# environment variable, it is inherited by the embedded servers as well.
ENV LD_PRELOAD=libjemalloc.so.2

COPY --from=runtime-assets /app /app

# The entrypoint drops privileges to the `postgres` and `redis` accounts before
# starting either embedded server, and runuser is how it does that. It comes
# from util-linux, which Debian marks essential — asserting it here turns a base
# image that ever stopped shipping it into a failed build instead of a container
# that fails on its first start.
#
# The executable bit likewise: the script's mode travels from the repository
# through two COPY layers, and an ENTRYPOINT that is not executable is a run
# time error with no useful message.
RUN set -eux; \
  command -v runuser; \
  test -x ./scripts/self-host-entrypoint.sh

EXPOSE 3010

# The entrypoint decides whether the servers embedded above are used or whether
# the operator's own are, runs the initial setup, and hands over to the command
# below. It is the only place that decision is made — see the script's header.
#
# CMD stays the server so that `docker run <image>` starts it, and so that
# `docker run <image> <something else>` reaches the same prepared database and
# cache instead of bypassing them.
ENTRYPOINT ["/app/scripts/self-host-entrypoint.sh"]
CMD ["node", "./dist/main.js"]
