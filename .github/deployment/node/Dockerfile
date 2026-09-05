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

# Application build and runtime stages follow in the next step of this change.
