# Building the Self-Host Image from Source

> **Warning**
> This document is not guaranteed to be up-to-date.
> If you find any outdated information, please feel free to open an issue or submit a PR.

Clone the repository, run one `docker build`, get one image. Everything the
server needs — the Rust native addon, the web, admin and mobile bundles, the
server bundle and its production dependencies — is compiled inside the build.
Nothing is pulled from a published tag, so the image you get is the code you
have checked out.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Build](#build)
- [Build arguments](#build-arguments)
- [Verify the image](#verify-the-image)
- [Architecture](#architecture)
- [Build cost](#build-cost)
- [Related Documents](#related-documents)

## Prerequisites

**Docker Engine 23.0 or newer.** The Dockerfile opens with
`# syntax=docker/dockerfile:1.7` and uses cache mounts, so it requires
[BuildKit](https://docs.docker.com/build/buildkit/). BuildKit is the default
builder from Engine 23.0 onwards; on an older Engine, export
`DOCKER_BUILDKIT=1` before building. Check with `docker version`.

**Network access.** The build fetches the base image, a handful of Debian
packages, the Rust toolchain from <https://sh.rustup.rs>, and the npm registry.
No registry credential is needed: every dependency resolves from the public
registry.

**Disk.** The final image carries only the server bundle, its production
dependencies and the static assets — but the build cache behind it carries the
Cargo registry, the Cargo `target` directory, the Yarn cache and the full
workspace `node_modules`, and is by far the larger of the two. Reclaim it with
`docker builder prune` once you have the image.

**Nothing else.** Node.js, Yarn and Rust are *not* required on the host. The
build uses the Yarn release vendored in `.yarn/releases` and the Rust toolchain
pinned by [`rust-toolchain.toml`](../../rust-toolchain.toml), so the versions
are the ones this commit pins rather than whatever the host happens to have.
Host-local `node_modules`, `dist`, `lib` and `target` directories are excluded
from the build context by [`.dockerignore`](../../.dockerignore) — a dirty
working tree cannot leak into the image.

## Build

```sh
git clone https://github.com/toeverything/AFFiNE
cd AFFiNE
docker build -f .github/deployment/node/Dockerfile -t affine:selfhost .
```

The build context is the repository root, not the directory the Dockerfile
lives in — the Dockerfile compiles the workspace, so it needs the workspace.

The compose stack builds the same image under the same tag, so either command
serves the other:

```sh
docker compose -f .docker/selfhost/compose.yml build
```

## Build arguments

All three are optional; the defaults produce a working image.

| Argument     | Default                | Effect                                                                                                                                                                                                                                          |
| ------------ | ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `BUILD_TYPE` | `stable`               | The release channel baked into the frontend bundles.                                                                                                                                                                                            |
| `GITHUB_SHA` | forty `0`s             | The commit stamped into the served HTML and `assets-manifest.json`. `.dockerignore` keeps `.git` out of the build context, so the bundler cannot read it — pass `--build-arg GITHUB_SHA="$(git rev-parse HEAD)"` if you want the real commit in. |
| `NODE_IMAGE` | `node:22-bookworm-slim` | The base image shared by every stage.                                                                                                                                                                                                           |

## Verify the image

```sh
docker image ls affine:selfhost

docker run --rm affine:selfhost ls -1 \
  dist/main.js \
  dist/server-native.node \
  static/selfhost.html \
  static/admin/selfhost.html \
  static/mobile/selfhost.html
```

Five paths listed back means the server bundle, the native addon and all three
frontends are in the image. Each of these is also asserted by the build step
that produces it, so a build that reported success has them — the check above
is for confirming *which* image a tag currently points at.

## Architecture

The native addon is compiled for the build host only — there is no cross
toolchain and no second Cargo target. An image built on an arm64 machine runs
on arm64, and an image built on an x86-64 machine runs on x86-64.

To produce an image for a different architecture, ask BuildKit for it:

```sh
docker buildx build --platform linux/amd64 \
  -f .github/deployment/node/Dockerfile -t affine:selfhost --load .
```

This runs the *entire* build — the Rust compile and all three bundlers — under
emulation, which is dramatically slower than a native build. Prefer building on
a host of the architecture you intend to run.

The release pipeline publishes `linux/amd64`, `linux/arm64` and `linux/arm/v7`
by handing the same Dockerfile to `docker buildx`
([`.github/workflows/build-images.yml`](../../.github/workflows/build-images.yml)).

## Build cost

What a cold build does, in order: install the workspace dependencies from the
lockfile, install the Rust toolchain, compile `@affine/server-native`, bundle
the web, admin and mobile apps, bundle the server, then install the server's
production dependency closure and generate the Prisma client. The Rust compile
and the three bundlers dominate; the rest is comparatively cheap.

> **Note**
> No wall-clock time or image size is recorded here yet. The figures depend
> heavily on the host — core count, whether the build is emulated, and how much
> of the cache is warm — and this repository has not yet published a measured
> baseline for the source build. Rather than quote a number that would not
> reproduce, this document tells you how to take your own.

Measure a cold build and the resulting image with:

```sh
time docker build --no-cache \
  -f .github/deployment/node/Dockerfile -t affine:selfhost .

docker image ls affine:selfhost --format '{{.Size}}'
```

Warm rebuilds are much cheaper than the cold number suggests. The stages are
ordered so that dependency installation is invalidated only by a change to a
manifest, the lockfile, a patch or the vendored Yarn release; an edit confined
to application source re-runs the bundlers and, if it touched Rust, an
incremental Cargo build. Drop `--no-cache` for those.

## Related Documents

- [container-build-audit.md](./container-build-audit.md) — what the build and startup definitions did before this build existed
- [BUILDING.md](../BUILDING.md) — building the web app from source, without Docker
- [developing-server.md](../developing-server.md) — running the server locally for development
