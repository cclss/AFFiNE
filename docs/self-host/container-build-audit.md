# Container Build Audit — Self-Host Image

> **Note**
> This is an audit, not a guide. It records what the container build and startup
> definitions in this repository do **today**, so that a change to them can be
> reviewed against a written baseline. It does not propose a fix.

The ship-ready contract for self-hosting is: _clone the repository, build one
image from source, run it_. This document locates every point where the current
definitions fall short of that, and every environment variable the app reads at
runtime.

## Scope

Audited files:

| File                                                                             | Role                                                         |
| -------------------------------------------------------------------------------- | ------------------------------------------------------------ |
| [`.github/deployment/node/Dockerfile`](../../.github/deployment/node/Dockerfile) | The image that is published as `ghcr.io/toeverything/affine` |
| [`.github/workflows/build-images.yml`](../../.github/workflows/build-images.yml) | The CI pipeline that feeds that Dockerfile                   |
| [`.dockerignore`](../../.dockerignore)                                           | What reaches the build context                               |
| [`.render/Dockerfile`](../../.render/Dockerfile)                                 | The Render deployment image                                  |
| [`.render/start.sh`](../../.render/start.sh)                                     | The Render entrypoint                                        |
| [`.docker/selfhost/compose.yml`](../../.docker/selfhost/compose.yml)             | The documented self-host stack                               |

## How to read this document

Every finding carries one of three labels. The label is about the _evidence_,
not about how likely the finding is to be true.

| Label            | Meaning                                                                                                  |
| ---------------- | -------------------------------------------------------------------------------------------------------- |
| **Fact**         | Directly readable in a file in this repository. Cited with `path:line`.                                  |
| **Inference**    | Follows from the facts, but no file states it. A reasonable reader could disagree.                       |
| **Unverifiable** | Cannot be settled from this repository alone. Needs a build run, registry access, or a product decision. |

---

## Facts

Each item below is stated by the cited lines.

### F1 — The image Dockerfile compiles nothing

`.github/deployment/node/Dockerfile` has no `yarn`, `npm`, `cargo`, or build
invocation. Its `RUN` steps are two `apt-get` installs and one cleanup script:

- `Dockerfile:15-17` — installs `openssl ca-certificates`.
- `Dockerfile:19` — runs `scripts/docker-clean.mjs`, which only deletes and
  hardlinks files that already exist.
- `Dockerfile:26-28` — installs `openssl libjemalloc2`.

The app is assembled entirely by `COPY`.

### F2 — Four `COPY` instructions depend on build output that is not in the repository

`Dockerfile:6-9`:

| Line | Copied from                            | What must already exist there                                      |
| ---- | -------------------------------------- | ------------------------------------------------------------------ |
| `:6` | `./packages/backend/server`            | Compiled `dist/`, plus a `node_modules/` placed inside the package |
| `:7` | `./packages/frontend/apps/web/dist`    | Web bundle                                                         |
| `:8` | `./packages/frontend/admin/dist`       | Admin bundle                                                       |
| `:9` | `./packages/frontend/apps/mobile/dist` | Mobile bundle                                                      |

All four are build output. `.gitignore:12` ignores `*dist` and `.gitignore:20`
ignores `node_modules`, so none of these paths exist in a fresh clone.

### F3 — CI produces those inputs, outside the Dockerfile

`.github/workflows/build-images.yml` runs the builds as separate jobs and moves
their output into the build context before calling `docker build`:

| Step                                                          | Line                           | Effect                                                      |
| ------------------------------------------------------------- | ------------------------------ | ----------------------------------------------------------- |
| `yarn affine @affine/web build` → upload artifact `web`       | `:31`, `:47-52`                | Produces `packages/frontend/apps/web/dist`                  |
| `yarn affine @affine/admin build` → upload artifact `admin`   | `:60`, `:78-83`                | Produces `packages/frontend/admin/dist`                     |
| `yarn affine @affine/mobile build` → upload artifact `mobile` | `:89`, `:109-114`              | Produces `packages/frontend/apps/mobile/dist`               |
| `yarn workspace @affine/server build` → upload `server-dist`  | `:185`, `:186-191`             | Produces `packages/backend/server/dist`                     |
| Download `server-dist`, `web`, `mobile`, `admin`              | `:203`, `:228`, `:234`, `:240` | Restores the four `COPY` sources                            |
| `yarn workspaces focus @affine/server --production`           | `:246-251`                     | Installs production dependencies at the repo root           |
| `yarn workspace @affine/server prisma generate`               | `:252`                         | Generates the Prisma client                                 |
| `mv ./node_modules ./packages/backend/server`                 | `:255`                         | Relocates `node_modules` so that `Dockerfile:6` picks it up |
| `docker/build-push-action` with `context: .`                  | `:263-272`                     | Only now is the Dockerfile invoked                          |

The Rust native addon is built earlier still, in `build-server-native`
(`:116-158`), and consumed by `build-server` through the
`server-native-*` artifacts (`:176-181`).

### F4 — The Render image inherits a published image and compiles nothing

`.render/Dockerfile:4` is `FROM ghcr.io/toeverything/affine:stable`. The file's
own comment says so: _"Adds a start script to the published AFFiNE image.
Nothing is compiled here."_ (`.render/Dockerfile:3`). The only other
instructions are a `COPY` of the start script (`:6`) and a `CMD` (`:8`).

`render.yaml:13-14` points Render at that Dockerfile with
`dockerContext: ./.render`, so the build context is the two-file `.render`
directory — the application source is not even reachable from it.

### F5 — The compose stack consumes a published image; it never builds one

`.docker/selfhost/compose.yml:4` and `:24` both set
`image: ghcr.io/toeverything/affine:stable`. Neither service declares a `build:`
key, so `docker compose build` has nothing to build.

### F6 — Startup bootstrapping exists, in two places, calling the same script

- `.render/start.sh:10` runs `node ./scripts/self-host-predeploy.js`, then
  `exec node ./dist/main.js` (`:12`).
- `compose.yml:29` runs the same script as a one-shot `affine_migration`
  service, which the `affine` service waits on
  (`compose.yml:13-14`, `condition: service_completed_successfully`).

`packages/backend/server/scripts/self-host-predeploy.js` generates
`~/.affine/config/private.key` only if absent (`:34-36`), rolls back a known
failed migration while swallowing "already rolled back" errors (`:59-81`), then
runs `yarn prisma migrate deploy` (`:43`) and `yarn cli run` (`:52`).

### F7 — Every existing path expects the database and cache to be outside the image

- `compose.yml:39-64` runs `redis` and `pgvector/pgvector:pg16` as sibling
  containers; the app receives `REDIS_SERVER_HOST=redis` and a `DATABASE_URL`
  pointing at the `postgres` service (`:19-20`).
- `render.yaml:27-40` wires `DATABASE_URL` and `REDIS_SERVER_*` from a managed
  Render database and key-value service.
- `.github/deployment/node/Dockerfile` installs no database or cache server, and
  its `CMD` (`:35`) starts only the Node process.

### F8 — There is no environment variable that seeds an administrator account

The server binds environment variables through `defineModuleConfig(...)` with an
`env:` key. The complete set of such bindings is listed under
[Runtime environment variables](#runtime-environment-variables); none of them
create a user. The first administrator is created over HTTP instead, by
`POST /create-admin-user`
(`packages/backend/server/src/core/selfhost/controller.ts:35-36`), which refuses
once a first user exists (`:41-43`).

---

## Runtime environment variables

Every variable below is read by the running container. Sources are relative to
`packages/backend/server/`. All have defaults — the server starts without any of
them set, but the connection defaults point at `localhost`, which inside a
container is the container itself.

### Database and cache

| Variable                | Source                         | Default                              |
| ----------------------- | ------------------------------ | ------------------------------------ |
| `DATABASE_URL`          | `src/base/prisma/config.ts:19` | `postgresql://localhost:5432/affine` |
| `REDIS_SERVER_HOST`     | `src/base/redis/config.ts:31`  | `localhost`                          |
| `REDIS_SERVER_PORT`     | `src/base/redis/config.ts:36`  | `6379`                               |
| `REDIS_SERVER_DATABASE` | `src/base/redis/config.ts:25`  | `0`                                  |
| `REDIS_SERVER_USERNAME` | `src/base/redis/config.ts:42`  | `""`                                 |
| `REDIS_SERVER_PASSWORD` | `src/base/redis/config.ts:47`  | `""`                                 |

### Server addressing

| Variable                     | Source                         | Default     |
| ---------------------------- | ------------------------------ | ----------- |
| `AFFINE_SERVER_HOST`         | `src/core/config/config.ts:55` | `localhost` |
| `AFFINE_SERVER_PORT`         | `src/core/config/config.ts:70` | `3010`      |
| `AFFINE_SERVER_HTTPS`        | `src/core/config/config.ts:49` | `false`     |
| `AFFINE_SERVER_EXTERNAL_URL` | `src/core/config/config.ts:36` | `""`        |
| `AFFINE_SERVER_SUB_PATH`     | `src/core/config/config.ts:75` | `""`        |
| `LISTEN_ADDR`                | `src/core/config/config.ts:65` | `0.0.0.0`   |

`Dockerfile:33` exposes `3010`, matching the `AFFINE_SERVER_PORT` default.
`render.yaml:23-26` overrides the port to `10000` and sets
`AFFINE_SERVER_HTTPS=true`.

### Crypto and identity

| Variable             | Source                          | Default                                                                                                                      |
| -------------------- | ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `AFFINE_PRIVATE_KEY` | `src/base/helpers/config.ts:14` | `""` — otherwise read from `~/.affine/config/private.key`, generated on first boot by `scripts/self-host-predeploy.js:34-36` |

### Deployment shape

| Variable              | Source              | Default                          |
| --------------------- | ------------------- | -------------------------------- |
| `NODE_ENV`            | `src/env.ts:91`     | `production`                     |
| `AFFINE_ENV`          | `src/env.ts:92-96`  | `production`                     |
| `DEPLOYMENT_TYPE`     | `src/env.ts:97-101` | `selfhosted` outside development |
| `SERVER_FLAVOR`       | `src/env.ts:102`    | `allinone`                       |
| `DEPLOYMENT_PLATFORM` | `src/env.ts:103`    | `unknown`                        |

### Mail and telemetry (optional)

| Variable                                                                                                                  | Source                               |
| ------------------------------------------------------------------------------------------------------------------------- | ------------------------------------ |
| `MAILER_HOST`, `MAILER_PORT`, `MAILER_USER`, `MAILER_PASSWORD`, `MAILER_SENDER`, `MAILER_SERVERNAME`, `MAILER_IGNORE_TLS` | `src/core/mail/config.ts:41-71`      |
| `GA4_MEASUREMENT_ID`, `GA4_API_SECRET`                                                                                    | `src/core/telemetry/config.ts:32-37` |

### Not runtime — build-time and platform-supplied

These appear near the container definitions but are not read by the running
server:

| Variable                                                         | Source                          | Nature                                                       |
| ---------------------------------------------------------------- | ------------------------------- | ------------------------------------------------------------ |
| `AFFINE_DOCKER_CLEAN`, `AFFINE_DOCKER_CLEAN_VERBOSE`, `APP_ROOT` | `scripts/docker-clean.mjs:9-13` | Build-time cleanup control                                   |
| `TARGETARCH`, `TARGETVARIANT`                                    | `Dockerfile:12-13`              | BuildKit-supplied build args                                 |
| `RENDER_EXTERNAL_HOSTNAME`                                       | `.render/start.sh:6`            | Supplied by Render; used only to derive `AFFINE_SERVER_HOST` |

---

## Inferences

These follow from the facts above, but no file in the repository asserts them.

### I1 — `docker build -f .github/deployment/node/Dockerfile .` fails on a clean clone

From **F2**: the first `COPY` whose source is missing aborts the build. Since
`dist` directories are gitignored, `Dockerfile:7` is the first such line
(`Dockerfile:6` would succeed, copying source without `dist`/`node_modules`).
Not verified by running a build here — see **U2**.

### I2 — No change made in this repository can reach the Render deployment

From **F4**: `.render/Dockerfile` pins `:stable`, and its build context excludes
the source tree. The deployed artifact is therefore whatever was last published
under that tag, independent of the commit being deployed.

### I3 — Moving the database and cache into the image is not a Dockerfile-only change

From **F7** and **F1**: the runtime stage is `node:22-bookworm-slim`
(`Dockerfile:21`), which contains neither a Postgres nor a Redis server, and the
image's only process supervisor is `CMD` (`Dockerfile:35`). Adding in-image
services requires new packages in the image and a process that starts more than
one thing.

### I4 — Re-running the bootstrap against a populated database is designed to be safe

From **F6**: the key generator is guarded by an existence check, the
failed-migration fixer swallows the "not in a failed state" and "never applied"
cases, and `prisma migrate deploy` applies only pending migrations. This is a
reading of the code's intent, not a tested property — no test in the repository
exercises a second boot.

### I5 — A documented dummy login cannot work today

From **F8**: there is no seed path reachable from environment configuration, and
the HTTP setup endpoint requires a caller. A shipped image would come up with
zero users and an unauthenticated setup screen.

### I6 — The self-host stack has two sources of truth for bootstrapping

From **F6**: `.render/start.sh` and `compose.yml`'s `affine_migration` service
each independently decide when the predeploy script runs. Any change to
bootstrap ordering must be made in both places, or they drift.

---

## Unverifiable

These cannot be settled from this repository. Each names what would settle it.

### U1 — Whether `ghcr.io/toeverything/affine:stable` matches this repository

`.render/Dockerfile:4` and `compose.yml:4`/`:24` consume a tag whose contents are
decided by a past CI run. Settling this requires pulling the image and comparing
it to a locally produced one.

### U2 — Whether the CI install sequence reproduces inside a Docker build

`build-images.yml:246-255` performs `yarn workspaces focus --production`,
`prisma generate`, and a `node_modules` relocation on the CI host. Whether the
same sequence succeeds inside a Docker layer is not observable here: this
worktree has no installed dependencies (`yarn` reports
_"Couldn't find the node_modules state file"_), so no install or build was run
while writing this document.

### U3 — Whether the GitHub Packages registry setup is still required

`build-images.yml:221-226` configures npm against `https://npm.pkg.github.com`
with scope `@toeverything`, but the only `@toeverything` dependency found is
`@toeverything/infra`, declared as `workspace:*` (`package.json:103`). Whether
some transitive dependency still resolves from that registry can only be
determined by running an install with the registry unavailable.

### U4 — Image size and build duration budgets

`scripts/docker-clean.mjs` exists to shrink the image and logs how much it saved,
but no target figure is recorded anywhere in the repository. Without a stated
budget, a restructured build cannot be judged a regression or an improvement.

### U5 — Whether the multi-architecture matrix must be preserved

`build-images.yml:269` publishes `linux/amd64,linux/arm64,linux/arm/v7`, and
`docker-clean.mjs` prunes per-architecture native binaries and Prisma engines
accordingly. Whether `arm/v7` still has consumers is a product decision, not a
fact in the tree — and it materially changes the cost of building from source.

---

## Related documents

- [BUILDING.md](../BUILDING.md) — building the web app from source
- [developing-server.md](../developing-server.md) — running the server locally
