# Deploy

How a runnable image of this application is produced, what goes into it, and
what runs between container start and the server accepting requests. Every claim
below is followed by the `file:line` it was read from. Where the repository does
not back a claim, it is marked `(assumption — needs confirming)` rather than
filled in.

## Scope Statement

This guide answers three questions:

- Which image build paths exist, which one compiles the application, and which
  one the deployment configuration actually points at.
- What ends up inside the published image, and where.
- What the container does, in order, before the server listens.

It does not answer: what the variables the boot script sets mean
([conventions/env.md]), which port the started process opens
([conventions/networking.md]), or what the stores it migrates must provide
([conventions/datastore.md]). The `docker build` invocation itself is the
contract's entry point, not this guide's — see [AGENTS.md].

The headline fact: **the Dockerfile the deployment uses compiles nothing.** It
wraps an already-published image. The path that does compile lives in CI. Both
are described below, and the distance between them is recorded in
[Known Gaps].

## The Two Image Paths

| Path               | Dockerfile                           | What It Produces                                                                                                                                                                                                                              | Evidence                                                                                |
| ------------------ | ------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| Published image    | `.github/deployment/node/Dockerfile` | A two-stage build over `node:22-bookworm-slim` containing the compiled server, the three frontend bundles, and a pruned production `node_modules`. Built and pushed only by CI, tagged `ghcr.io/toeverything/affine:<build-type>-<short-sha>` | `.github/deployment/node/Dockerfile:3,21`, `.github/workflows/build-images.yml:263-272` |
| Deployment wrapper | `.render/Dockerfile`                 | `FROM ghcr.io/toeverything/affine:stable` plus one copied start script and a new `CMD`. No `RUN`, no build stage, nothing compiled                                                                                                            | `.render/Dockerfile:4-8`                                                                |

The second consumes the output of the first. `:stable` is not built by the
wrapper — it is a moving tag that the release workflow re-points at a
`<build-type>-<short-sha>` image after a manual approval step
(`.github/workflows/release.yml:137,146-161,172-175`).

The deployment configuration points at the wrapper, with the build context
narrowed to the `.render` directory (`render.yaml:13-14`). That directory holds
exactly two tracked files — the Dockerfile and the start script — so no part of
the working tree can enter the image through this path.

## What CI Does That The Dockerfile Does Not

The compiling Dockerfile expects a prepared tree. Five workflow steps prepare
it, and none of them is expressed in the Dockerfile.

| Step                                                                                                 | Produces                                                                                                                                | Evidence                                                        |
| ---------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| Build the Rust napi module for three targets, then download all three into `packages/backend/native` | `server-native.{x64,arm64,armv7}.node`                                                                                                  | `.github/workflows/build-images.yml:116-158,176-181`            |
| Build the server, upload and re-download `dist`                                                      | `packages/backend/server/dist`                                                                                                          | `.github/workflows/build-images.yml:184-192,203-207`            |
| Build web, admin, and mobile in three parallel jobs, then download their bundles                     | `packages/frontend/apps/web/dist`, `packages/frontend/admin/dist`, `packages/frontend/apps/mobile/dist`                                 | `.github/workflows/build-images.yml:22-115,228-245`             |
| `yarn workspaces focus @affine/server --production`, then `prisma generate`                          | A production dependency tree with a generated Prisma client                                                                             | `.github/workflows/build-images.yml:246-253`                    |
| `mv ./node_modules ./packages/backend/server`                                                        | Moves the tree where `COPY ./packages/backend/server /app` will pick it up — the root `node_modules` is excluded from the build context | `.github/workflows/build-images.yml:255-256`, `.dockerignore:6` |

Only after all five does the build run, with context `.`, across three
platforms (`.github/workflows/build-images.yml:263-272`).

## Inside The Published Image

| Path In Image        | Source                                                                                                                             | Evidence                               |
| -------------------- | ---------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------- |
| `/app`               | The whole `packages/backend/server` directory — `dist`, the moved `node_modules`, `scripts/`, and the Prisma schema and migrations | `.github/deployment/node/Dockerfile:6` |
| `/app/static`        | `packages/frontend/apps/web/dist`                                                                                                  | `.github/deployment/node/Dockerfile:7` |
| `/app/static/admin`  | `packages/frontend/admin/dist`                                                                                                     | `.github/deployment/node/Dockerfile:8` |
| `/app/static/mobile` | `packages/frontend/apps/mobile/dist`                                                                                               | `.github/deployment/node/Dockerfile:9` |

That layout is what the server's static routes read at runtime — it resolves
`static/` relative to the directory above `dist`
(`packages/backend/server/src/env.ts:105`,
`packages/backend/server/src/core/selfhost/static.ts:29`). Which of those routes
are mounted is [conventions/networking.md]'s subject.

Between the two stages, `docker-clean.mjs` runs with `AFFINE_DOCKER_CLEAN=1`
(`.github/deployment/node/Dockerfile:19`). It is a no-op without that variable
(`packages/backend/server/scripts/docker-clean.mjs:12,757-760`) and otherwise
deletes every `.map` under `static` and `node_modules`, hardlinks duplicate
static assets, keeps only the current architecture's `server-native.*.node` and
Prisma query engine, and removes `src`, `typescript`, `@types`, `tsconfig.json`,
and `config.example.json` from the image
(`packages/backend/server/scripts/docker-clean.mjs:762-826`). The server's own
sourcemap survives, by a negated rule in the ignore file
(`.dockerignore:24-26`). The final stage copies `/app` forward and preloads
jemalloc (`.github/deployment/node/Dockerfile:21-31`).

The image's own default command is `node ./dist/main.js` with no migration step
(`.github/deployment/node/Dockerfile:35`). Every deployment path in this
repository replaces or precedes it, because a fresh database has no schema.

## Boot Sequence

`.render/Dockerfile:8` overrides the base image's command with the start script.
Five things then happen, in this order.

| #   | Step                                                                                                                             | Evidence                                                                   |
| --- | -------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| 1   | `set -eu` — any failing step aborts the boot rather than starting a half-migrated server                                         | `.render/start.sh:2`                                                       |
| 2   | `AFFINE_SERVER_HOST` is exported: an already-set value wins, else the platform's external hostname, else `localhost`             | `.render/start.sh:6`                                                       |
| 3   | `~/.affine/config` is created and `private.key` generated there if absent                                                        | `packages/backend/server/scripts/self-host-predeploy.js:29-39,95`          |
| 4   | One known-failed migration is rolled back if present, then `prisma migrate deploy`, then `yarn cli run` for the data migrations  | `packages/backend/server/scripts/self-host-predeploy.js:41-57,59-93,96-98` |
| 5   | `exec node ./dist/main.js` — `exec` replaces the shell, so the server is PID 1 and receives the container's stop signal directly | `.render/start.sh:12`                                                      |

Steps 3 and 4 are the whole of `self-host-predeploy.js`, invoked as one line
(`.render/start.sh:10`). The script is written to be safe on every boot: it
writes the key only when the file is missing, and `migrate deploy` applies only
what is outstanding.

The compose path runs the same script, but as a separate one-shot container that
must complete before the app container starts
(`.docker/selfhost/compose.yml:13-14,23-29`). That is the only deployment path
in the repository where migrations do not run inside the serving container.

## Deployment Shape

`render.yaml` describes one project containing three independent pieces, not one
container: a Docker web service, a key-value service, and a PostgreSQL database
(`render.yaml:8-52`). The web service is the only one built from this
repository; the other two are provisioned by the platform, and what they must
provide is [conventions/datastore.md]'s subject. The disk mounted at
`/root/.affine` is what makes step 3 above idempotent across restarts — without
it, every boot generates a new private key
(`render.yaml:16-21`, and see [conventions/env.md]).

## Commands

```sh
# List every Dockerfile the repository tracks. Three today: the CI build, this
# deployment's wrapper, and a PostgreSQL image for the Helm chart.
git ls-files '*Dockerfile*'

# Print the boot steps in order, without running them. This is the file the
# wrapper makes the container's CMD (.render/Dockerfile:6-8).
cat .render/start.sh

# Show what the wrapper inherits — the base image's command, exposed port, and
# baked-in environment. Requires the published image to be pulled first.
docker image inspect ghcr.io/toeverything/affine:stable \
  --format '{{.Config.Cmd}} {{.Config.ExposedPorts}}'
```

## Known Gaps

| Gap                                                       | Evidence                                                                               | What Happens Today                                                                                                                                                                                                                                                                                                                                              |
| --------------------------------------------------------- | -------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| The Dockerfile does not build the app                     | `.render/Dockerfile:4-8`, `render.yaml:13-14`                                          | Building it from a checkout produces an image of whatever `ghcr.io/toeverything/affine:stable` currently is, plus a start script. A change to the working tree cannot reach a deployed container through this path — the build succeeds and ships the previous release's code                                                                                   |
| The from-source image build is CI-only                    | `.github/workflows/build-images.yml:116-272`, `.github/deployment/node/Dockerfile:6-9` | The Dockerfile that does compile expects `dist` for the server and three frontends, three prebuilt native binaries, a production `node_modules` already moved into the server package, and a generated Prisma client. All of that is workflow steps. No single command in this repository reproduces it locally, and no `Makefile` or script wraps the sequence |
| Nothing pins the base image                               | `.render/Dockerfile:4`, `.github/workflows/release.yml:172-175`                        | `:stable` is retagged on every stable release. Two builds of the same commit of this repository can yield different images, and no digest is recorded anywhere, so there is nothing to roll back to                                                                                                                                                             |
| Migrations run inside the serving container on every boot | `.render/start.sh:10`, `render.yaml:8-40`                                              | The web service is the migration runner. Scale it past one instance and two containers can run `prisma migrate deploy` against the same database at the same time; nothing in this path takes a lock. The compose path avoids this with a separate job (`.docker/selfhost/compose.yml:13-14,23-29`), and the Render path has no equivalent                      |
| Deployment is not a single container                      | `render.yaml:8-52`                                                                     | Web, PostgreSQL, and the key-value store are three separate services with independent lifecycles. Any instruction that assumes one self-contained container is wrong against this repository                                                                                                                                                                    |
| A nested ignore file has no build to apply to             | `packages/backend/server/.dockerignore:1-2`, `.github/workflows/build-images.yml:266`  | The server package carries a `.dockerignore` excluding `schema.prisma`, but the build context is the repository root, whose own `.dockerignore` does not exclude it. The nested file appears to be inert **(assumption — needs confirming)**, in which case `COPY ./packages/backend/server /app` ships the schema the comment intends to withhold              |

## Assumptions

- That the hosting platform builds `.render/Dockerfile` with `./.render` as the
  context exactly as a local `docker build` would (`render.yaml:13-14`) is taken
  from the configuration file's own fields. The platform's build behaviour is
  not defined in this repository **(assumption — needs confirming)**.
- Whether `ghcr.io/toeverything/affine:stable` is published by _this_
  repository's workflows or by the upstream project is unresolved. The workflow
  pushes to that exact registry path
  (`.github/workflows/build-images.yml:272`,
  `.github/workflows/release.yml:174`), but nothing here confirms the tag the
  wrapper pulls came from these files **(assumption — needs confirming)**.
- Docker consults only the build context's root ignore file, which is why the
  gap row above calls `packages/backend/server/.dockerignore` inert. That is
  builder behaviour, not a repository fact, and no test here pins it
  **(assumption — needs confirming)**.
- `yarn cli run`, the data-migration step
  (`packages/backend/server/scripts/self-host-predeploy.js:52`), is assumed to
  be idempotent because the script runs it on every boot. The script says it is
  safe to re-run (`.render/start.sh:8-9`); the migrations themselves were not
  read to confirm it **(assumption — needs confirming)**.

[AGENTS.md]: ../AGENTS.md
[conventions/datastore.md]: ./datastore.md
[conventions/env.md]: ./env.md
[conventions/networking.md]: ./networking.md
[Known Gaps]: #known-gaps
