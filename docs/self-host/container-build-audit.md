# Container Build Audit — Self-Host Image

> **Note**
> This is an audit, not a guide. It records what the container build and startup
> definitions in this repository do **today**, so that a change to them can be
> reviewed against a written baseline. It does not propose a fix.

> **Superseded — this describes the state before the source build landed.**
> The findings below were written against the prebuilt-artifact pipeline. That
> pipeline is gone: `.github/deployment/node/Dockerfile` now installs, compiles
> and assembles from source, `.github/workflows/build-images.yml` is a checkout
> and a `docker build`, `.docker/selfhost/compose.yml` carries a `build:` key,
> and `render.yaml` builds the same Dockerfile — so `.render/Dockerfile` and
> `.render/start.sh`, cited below and linked from the table, no longer exist.
> The document is kept as the baseline those changes were reviewed against.
> The findings the source build invalidates — **F1**–**F5**, **I1**, **I2** and
> **U1** — carry an inline note recording what replaced them. For how to build
> the image today, see [building-the-image.md](./building-the-image.md).

> **Also superseded — the image now carries its own database and cache.**
> **F7**, **I3**, **I8** and **U7** were written when every path put the database
> and the cache outside the image. The image now embeds both and its entrypoint
> decides between them and yours, so those four carry an inline note as well. For
> how to run the image today, see [running-the-image.md](./running-the-image.md).

The ship-ready contract for self-hosting is: _clone the repository, build one
image from source, run it_. This document locates every point where the current
definitions fall short of that, and every environment variable the app reads at
runtime.

## Scope

Build and startup definitions:

| File                                                                                   | Role                                                         |
| -------------------------------------------------------------------------------------- | ------------------------------------------------------------ |
| [`.github/deployment/node/Dockerfile`](../../.github/deployment/node/Dockerfile)       | The image that is published as `ghcr.io/toeverything/affine` |
| [`.github/workflows/build-images.yml`](../../.github/workflows/build-images.yml)       | The CI pipeline that feeds that Dockerfile                   |
| [`.dockerignore`](../../.dockerignore)                                                 | What reaches the build context                               |
| [`.gitignore`](../../.gitignore)                                                       | What a fresh clone does not contain                          |
| `.render/Dockerfile`                                                                   | The Render deployment image *(deleted; see the banner)*      |
| `.render/start.sh`                                                                     | The Render entrypoint *(deleted; see the banner)*            |
| [`render.yaml`](../../render.yaml)                                                     | The Render service, disk and variable wiring                 |
| [`.docker/selfhost/compose.yml`](../../.docker/selfhost/compose.yml)                   | The documented self-host stack                               |
| [`package.json`](../../package.json)                                                   | Workspace and registry declarations                          |
| [`.github/actions/setup-node/action.yml`](../../.github/actions/setup-node/action.yml) | The shared registry setup every other job uses               |
| [`yarn.lock`](../../yarn.lock)                                                         | What each declared version resolves to                       |
| [`packages/frontend/core/package.json`](../../packages/frontend/core/package.json)     | Registry-versioned `@toeverything` declarations              |
| [`blocksuite/playground/package.json`](../../blocksuite/playground/package.json)       | A further registry-versioned `@toeverything` declaration     |

Server sources read for the variable inventory, under
[`packages/backend/server/`](../../packages/backend/server/):

| File                              | Role                                                     |
| --------------------------------- | -------------------------------------------------------- |
| `scripts/self-host-predeploy.js`  | The bootstrap both deployments call                      |
| `scripts/docker-clean.mjs`        | Build-time image slimming                                |
| `schema.prisma`                   | The Prisma datasource                                    |
| `src/prelude.ts`                  | `.env` and private key loading, before anything else     |
| `src/env.ts`                      | Deployment-shape variables and `readEnv`                 |
| `src/base/config/register.ts`     | How an `env` binding becomes a config value              |
| `src/base/prisma/config.ts`       | Database configuration                                   |
| `src/base/redis/config.ts`        | Cache configuration                                      |
| `src/base/helpers/config.ts`      | Private key configuration                                |
| `src/base/helpers/crypto.ts`      | Private key consumption and the non-production key paths |
| `src/core/config/config.ts`       | Server addressing                                        |
| `src/core/mail/config.ts`         | SMTP configuration                                       |
| `src/core/telemetry/config.ts`    | GA4 configuration                                        |
| `src/core/storage/config.ts`      | Blob and avatar storage paths                            |
| `src/core/selfhost/controller.ts` | The first-administrator endpoint                         |
| `src/plugins/gcloud/metrics.ts`   | The two observability-only variables                     |
| `src/cli.ts`                      | The CLI entrypoint and its command list                  |
| `src/data/commands/`              | The data commands the CLI exposes                        |

## How to read this document

Every finding carries one of three labels. The label is about the _evidence_,
not about how likely the finding is to be true.

| Label            | Meaning                                                                                                  |
| ---------------- | -------------------------------------------------------------------------------------------------------- |
| **Fact**         | Directly readable in a file in this repository. Cited with `path:line`.                                  |
| **Inference**    | Follows from the facts, but no file states it. A reasonable reader could disagree.                       |
| **Unverifiable** | Cannot be settled from this repository alone. Needs a build run, registry access, or a product decision. |

**F11**–**F16** inventory every variable the running container reads. Their
columns mean:

| Column       | Meaning                                                                                                                              |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------ |
| **Source**   | Where the name is bound. Every name was located by grep at the cited line.                                                           |
| **Required** | Whether the process fails or misbehaves when the variable is absent. "No" means a default applies, in the sense of **F9**.           |
| **Default**  | The value used when the variable is unset or empty.                                                                                  |
| **Split**    | Whether the variable addresses the database or cache, and so carries a different value for an in-image service than an external one. |

Paths in those tables are relative to `packages/backend/server/` unless stated
otherwise.

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

> **No longer true.** The Dockerfile now compiles: it installs the workspace
> from the lockfile, builds the Rust native addon, bundles web, admin, mobile
> and the server, then installs the server's production dependency closure.
> See [building-the-image.md](./building-the-image.md).

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

> **No longer true.** No stage copies build output from the context. The four
> paths are produced inside the image by the `build` stage and reach the final
> image through `COPY --from`, so a fresh clone is a complete build context.
> `.dockerignore` now excludes the host's `node_modules` and `dist` directories
> outright, to keep a dirty working tree out of the build.

### F3 — CI produces those inputs, outside the Dockerfile

`.github/workflows/build-images.yml` runs the builds as separate jobs and moves
their output into the build context before calling `docker build`:

| Step                                                          | Line                           | Effect                                                      |
| ------------------------------------------------------------- | ------------------------------ | ----------------------------------------------------------- |
| `yarn affine @affine/web build` → upload artifact `web`       | `:35`, `:47-52`                | Produces `packages/frontend/apps/web/dist`                  |
| `yarn affine @affine/admin build` → upload artifact `admin`   | `:67`, `:78-83`                | Produces `packages/frontend/admin/dist`                     |
| `yarn affine @affine/mobile build` → upload artifact `mobile` | `:98`, `:109-114`              | Produces `packages/frontend/apps/mobile/dist`               |
| `yarn workspace @affine/server build` → upload `server-dist`  | `:185`, `:186-191`             | Produces `packages/backend/server/dist`                     |
| Download `server-dist`, `web`, `mobile`, `admin`              | `:203`, `:228`, `:234`, `:240` | Restores the four `COPY` sources                            |
| `yarn workspaces focus @affine/server --production`           | `:250`                         | Installs production dependencies at the repo root           |
| `yarn workspace @affine/server prisma generate`               | `:253`                         | Generates the Prisma client                                 |
| `mv ./node_modules ./packages/backend/server`                 | `:256`                         | Relocates `node_modules` so that `Dockerfile:6` picks it up |
| `docker/build-push-action` with `context: .`                  | `:263-272`                     | Only now is the Dockerfile invoked                          |

The Rust native addon is built earlier still, in `build-server-native`
(`:116-158`), and consumed by `build-server` through the
`server-native-*` artifacts (`:176-181`).

> **No longer true.** All of those jobs are gone. `build-images.yml` is now a
> single job — checkout, version stamp, buildx, `docker build` — that passes
> `BUILD_TYPE` and `GITHUB_SHA` as build arguments and produces the artifacts
> inside the image. No artifact is uploaded, downloaded or moved on the CI
> host.

### F4 — The Render image inherits a published image and compiles nothing

`.render/Dockerfile:4` is `FROM ghcr.io/toeverything/affine:stable`. The file's
own comment says so: _"Adds a start script to the published AFFiNE image.
Nothing is compiled here."_ (`.render/Dockerfile:3`). The only other
instructions are a `COPY` of the start script (`:6`) and a `CMD` (`:8`).

`render.yaml:13-14` points Render at that Dockerfile with
`dockerContext: ./.render`, so the build context is the two-file `.render`
directory — the application source is not even reachable from it.

> **No longer true.** `.render/Dockerfile` and `.render/start.sh` are deleted —
> the links above are dead, and kept only so the finding still reads as
> written. `render.yaml` builds `.github/deployment/node/Dockerfile` at
> `dockerContext: .`, and the two jobs `start.sh` performed (hostname default,
> bootstrap before `exec`) moved into Render's `dockerCommand`.

### F5 — The compose stack consumes a published image; it never builds one

`.docker/selfhost/compose.yml:4` and `:24` both set
`image: ghcr.io/toeverything/affine:stable`. Neither service declares a `build:`
key, so `docker compose build` has nothing to build.

> **No longer true.** Both services now carry `image: affine:selfhost` and a
> `build:` at the repository root through a shared YAML anchor, so
> `docker compose build` builds the image and neither service can fall back to
> a registry lookup.

### F6 — Startup bootstrapping exists, in two places, calling the same script

- `.render/start.sh:10` runs `node ./scripts/self-host-predeploy.js`, then
  `exec node ./dist/main.js` (`:12`).
- `compose.yml:29` runs the same script as a one-shot `affine_migration`
  service, which the `affine` service waits on
  (`compose.yml:13-14`, `condition: service_completed_successfully`).

`packages/backend/server/scripts/self-host-predeploy.js` generates
`~/.affine/config/private.key` only if absent (`:34-36`), rolls back a known
failed migration while swallowing "already rolled back" errors (`:59-93`), then
runs `yarn prisma migrate deploy` (`:43`) and `yarn cli run` (`:52`).

### F7 — Every existing path expects the database and cache to be outside the image

- `compose.yml:39-64` runs `redis` and `pgvector/pgvector:pg16` as sibling
  containers; the app receives `REDIS_SERVER_HOST=redis` and a `DATABASE_URL`
  pointing at the `postgres` service (`:19-20`).
- `render.yaml:27-40` wires `DATABASE_URL` and `REDIS_SERVER_*` from a managed
  Render database and key-value service.
- `.github/deployment/node/Dockerfile` installs no database or cache server, and
  its `CMD` (`:35`) starts only the Node process.

> **No longer true.** The runtime stage installs PostgreSQL 16 with pgvector and
> Redis, and the image's `ENTRYPOINT` —
> `packages/backend/server/scripts/self-host-entrypoint.sh` — starts them when
> `DATABASE_URL` and `REDIS_SERVER_HOST` are empty. Both remain external when
> those variables are set, which is what compose and `render.yaml` still do, so
> the two paths in this finding are now the *configured* half of a branch rather
> than the only shape available. See
> [running-the-image.md](./running-the-image.md).

### F8 — There is no environment variable that seeds an administrator account

The server binds environment variables through `defineModuleConfig(...)` with an
`env:` key. The complete set of such bindings is inventoried in
**F11**–**F15**; none of them create a user. The first administrator is created
over HTTP instead, by `POST /create-admin-user`
(`packages/backend/server/src/core/selfhost/controller.ts:35-36`), which refuses
once a first user exists (`:41-43`).

### F9 — An environment variable supplies a config _default_; a config file outranks it

`src/base/config/register.ts:349-364` assembles the default configuration: for
every key that declares an `env` binding it reads `process.env`, and applies the
parsed value **only when the raw value is truthy** (`:362`). Both files in
`CONFIG_JSON_PATHS` — `{projectRoot}/config.json` and
`~/.affine/config/config.json` (`:284-287`) — are merged over the result
afterwards (`:388-391`).

Two things follow from those lines alone:

- `DATABASE_URL=""` is indistinguishable from `DATABASE_URL` being unset.
- The mounted config directory (`compose.yml:17`, `render.yaml:20`) outranks
  every variable in the tables below.

Earlier still, `src/prelude.ts` loads `.env` from the working directory (`:21`)
and from `~/.affine/config/.env` (`:23-25`), so that same mounted directory can
inject variables as well as override them.

### F10 — An out-of-range value stops the boot; it does not fall back

- `register.ts:369-379` throws `Invalid config for module [...] with key [...]`
  when a value fails its declared shape. `DATABASE_URL` must parse as a URL
  (`src/base/prisma/config.ts:20`), `REDIS_SERVER_PORT` as a positive integer
  (`src/base/redis/config.ts:37`), `REDIS_SERVER_DATABASE` as an integer in
  `0`–`10` (`:26`).
- `src/env.ts:79-85` throws
  `Invalid value "..." for environment variable ...` for the three allow-listed
  variables of **F14**.

### F11 — Database and cache

| Variable                | Source                         | Required                       | Default                              | Split      |
| ----------------------- | ------------------------------ | ------------------------------ | ------------------------------------ | ---------- |
| `DATABASE_URL`          | `src/base/prisma/config.ts:19` | Server: no. Bootstrap: **yes** | `postgresql://localhost:5432/affine` | endpoint   |
| `REDIS_SERVER_HOST`     | `src/base/redis/config.ts:31`  | No                             | `localhost`                          | endpoint   |
| `REDIS_SERVER_PORT`     | `src/base/redis/config.ts:36`  | No                             | `6379`                               | endpoint   |
| `REDIS_SERVER_DATABASE` | `src/base/redis/config.ts:25`  | No                             | `0`                                  | endpoint   |
| `REDIS_SERVER_USERNAME` | `src/base/redis/config.ts:42`  | No                             | empty                                | credential |
| `REDIS_SERVER_PASSWORD` | `src/base/redis/config.ts:47`  | No                             | empty                                | credential |

`DATABASE_URL` is the one variable with two different answers, because two
different readers consume it:

- The server reads it through the config system, which supplies the localhost
  default (`src/base/prisma/config.ts:18`).
- The Prisma CLI reads it directly — `schema.prisma:10` is
  `url = env("DATABASE_URL")`, with no default. `scripts/self-host-predeploy.js`
  invokes `yarn prisma migrate deploy` (`:43`) and `yarn cli run` (`:52`),
  passing `env: process.env` (`:45`, `:54`, `:68`). With the variable unset,
  the migration step has no datasource url at all.

### F12 — Server addressing

| Variable                     | Source                         | Required | Default     | Split |
| ---------------------------- | ------------------------------ | -------- | ----------- | ----- |
| `AFFINE_SERVER_HOST`         | `src/core/config/config.ts:55` | No       | `localhost` | —     |
| `AFFINE_SERVER_PORT`         | `src/core/config/config.ts:70` | No       | `3010`      | —     |
| `AFFINE_SERVER_HTTPS`        | `src/core/config/config.ts:49` | No       | `false`     | —     |
| `AFFINE_SERVER_EXTERNAL_URL` | `src/core/config/config.ts:36` | No       | empty       | —     |
| `AFFINE_SERVER_SUB_PATH`     | `src/core/config/config.ts:75` | No       | empty       | —     |
| `LISTEN_ADDR`                | `src/core/config/config.ts:65` | No       | `0.0.0.0`   | —     |

`Dockerfile:33` exposes `3010`, matching the `AFFINE_SERVER_PORT` default.
`render.yaml:23-26` overrides the port to `10000` and sets
`AFFINE_SERVER_HTTPS=true`; `.render/start.sh:6` derives `AFFINE_SERVER_HOST`
from `RENDER_EXTERNAL_HOSTNAME` when it is not already set.

### F13 — Crypto and identity

| Variable             | Source                          | Required | Default | Split |
| -------------------- | ------------------------------- | -------- | ------- | ----- |
| `AFFINE_PRIVATE_KEY` | `src/base/helpers/config.ts:14` | No       | empty   | —     |

Three code paths interact here:

- `src/prelude.ts:11-15` fills the variable from
  `~/.affine/config/private.key` when the variable itself is unset and the file
  exists. A value that came from a `.env` file rather than the real environment
  is dropped first (`:19-31`).
- `scripts/self-host-predeploy.js:29-39` writes that file on first boot, only
  when it does not already exist (`:34`).
- If both are absent, `src/base/helpers/crypto.ts:107` generates a key in
  memory: `this.config.crypto.privateKey || generatePrivateKey()`. The server
  starts, but the key differs on every boot.

### F14 — Deployment shape

These five do not share one reader, and only three of them are validated.

- `AFFINE_ENV`, `DEPLOYMENT_TYPE`, `SERVER_FLAVOR` and `DEPLOYMENT_PLATFORM` go
  through `readEnv` (`src/env.ts:69-88`), which returns the default only when
  the variable is `undefined` (`:75-77`). Unlike **F9**, an empty string is a
  value, not an absence.
- The first three of those pass an allow-list and throw on anything outside it
  (`:79-85`), so `AFFINE_ENV=""` stops the boot. `DEPLOYMENT_PLATFORM` passes no
  list (`:103`) and therefore accepts any string.
- `NODE_ENV` never reaches `readEnv`. `src/env.ts:91` reads
  `process.env.NODE_ENV` through `??`, which falls back on `undefined` only and
  validates nothing.

| Variable              | Source              | Required | Default                                  | Split |
| --------------------- | ------------------- | -------- | ---------------------------------------- | ----- |
| `NODE_ENV`            | `src/env.ts:91`     | No       | `production`                             | —     |
| `AFFINE_ENV`          | `src/env.ts:92-96`  | No       | `production` (`dev`/`beta`/`production`) | —     |
| `DEPLOYMENT_TYPE`     | `src/env.ts:97-101` | No       | `selfhosted` outside development         | —     |
| `SERVER_FLAVOR`       | `src/env.ts:102`    | No       | `allinone`                               | —     |
| `DEPLOYMENT_PLATFORM` | `src/env.ts:103`    | No       | `unknown`                                | —     |

### F15 — Mail and telemetry

Unset means the feature is inert, not that the server fails.

| Variable             | Source                            | Required | Default                                    | Split |
| -------------------- | --------------------------------- | -------- | ------------------------------------------ | ----- |
| `MAILER_HOST`        | `src/core/mail/config.ts:46`      | No       | empty                                      | —     |
| `MAILER_PORT`        | `src/core/mail/config.ts:51`      | No       | `465`                                      | —     |
| `MAILER_USER`        | `src/core/mail/config.ts:56`      | No       | empty                                      | —     |
| `MAILER_PASSWORD`    | `src/core/mail/config.ts:61`      | No       | empty                                      | —     |
| `MAILER_SENDER`      | `src/core/mail/config.ts:66`      | No       | `AFFiNE Self Hosted <noreply@example.com>` | —     |
| `MAILER_SERVERNAME`  | `src/core/mail/config.ts:41`      | No       | empty                                      | —     |
| `MAILER_IGNORE_TLS`  | `src/core/mail/config.ts:71`      | No       | `false`                                    | —     |
| `GA4_MEASUREMENT_ID` | `src/core/telemetry/config.ts:32` | No       | empty                                      | —     |
| `GA4_API_SECRET`     | `src/core/telemetry/config.ts:37` | No       | empty                                      | —     |

### F16 — Names that look runtime but are not

| Variable                                                                            | Source                                         | Why it is not a runtime input of the server                  |
| ----------------------------------------------------------------------------------- | ---------------------------------------------- | ------------------------------------------------------------ |
| `AFFiNE_PRO_PUBLIC_KEY`                                                             | `src/base/helpers/crypto.ts:255`               | Guarded by `!env.prod`; ignored in a production build        |
| `AFFiNE_PRO_LICENSE_AES_KEY`                                                        | `src/base/helpers/crypto.ts:271`               | Same guard                                                   |
| `HOSTNAME`, `CONTAINER_NAME`                                                        | `src/plugins/gcloud/metrics.ts:20-24`          | Metric labels in the GCP plugin only                         |
| `npm_lifecycle_event`                                                               | `src/cli.ts:13`                                | Names the CLI program in help output                         |
| `APP_ROOT`, `AFFINE_DOCKER_CLEAN`, `AFFINE_DOCKER_CLEAN_VERBOSE`                    | `scripts/docker-clean.mjs:9-13`                | Build-time cleanup control                                   |
| `TARGETARCH`, `TARGETVARIANT`                                                       | `.github/deployment/node/Dockerfile:12-13`     | BuildKit build args                                          |
| `LD_PRELOAD`                                                                        | `.github/deployment/node/Dockerfile:31`        | Set by the image to preload jemalloc                         |
| `RENDER_EXTERNAL_HOSTNAME`                                                          | `render.yaml:24-28` (was `.render/start.sh:6`) | Supplied by Render; only used to derive `AFFINE_SERVER_HOST` |
| `POSTGRES_USER`, `POSTGRES_DB`, `POSTGRES_INITDB_ARGS`, `POSTGRES_HOST_AUTH_METHOD` | `.docker/selfhost/compose.yml:55-58`           | Read by the sibling `pgvector` image, never by the app       |

### F17 — No environment variable selects a storage path

- Blob and avatar storage default to `~/.affine/storage`
  (`src/core/storage/config.ts:34`, `:45`) with no `env` key on either.
- The config directory is fixed at `~/.affine/config` (`src/env.ts:68`), which
  is where `config.json` (`register.ts:284-287`), `.env` (`prelude.ts:23-25`)
  and `private.key` (`prelude.ts:11-12`) are read from.
- The existing deployments express persistence as mounts, not variables:
  `compose.yml:15-17` and `:26-28` mount `./data/storage` and `./config`, the
  sibling database mounts `./data/postgres` (`:52-53`), and `render.yaml:16-21`
  mounts a 10 GB disk at `/root/.affine`.

---

## Inferences

These follow from the facts above, but no file in the repository asserts them.

### I1 — `docker build -f .github/deployment/node/Dockerfile .` fails on a clean clone

From **F2**: the first `COPY` whose source is missing aborts the build. Since
`dist` directories are gitignored, `Dockerfile:7` is the first such line
(`Dockerfile:6` would succeed, copying source without `dist`/`node_modules`).
Not verified by running a build here — see **U2**.

> **No longer true.** That command is now the documented way to build the
> image from a clean clone — see
> [building-the-image.md](./building-the-image.md). The premise this inference
> rested on (**F2**) is gone; **U2** remains open, since no build has been run
> from this environment either.

### I2 — No change made in this repository can reach the Render deployment

From **F4**: `.render/Dockerfile` pins `:stable`, and its build context excludes
the source tree. The deployed artifact is therefore whatever was last published
under that tag, independent of the commit being deployed.

> **No longer true.** `render.yaml:14-15` builds
> `.github/deployment/node/Dockerfile` with `dockerContext: .`, so the
> deployed artifact is the commit being deployed. The premise (**F4**) is gone.

### I3 — Moving the database and cache into the image is not a Dockerfile-only change

From **F7** and **F1**: the runtime stage is `node:22-bookworm-slim`
(`Dockerfile:21`), which contains neither a Postgres nor a Redis server, and the
image's only process supervisor is `CMD` (`Dockerfile:35`). Adding in-image
services requires new packages in the image and a process that starts more than
one thing.

> **Done, and this is how.** The packages are in the runtime stage; the process
> that starts more than one thing is the entrypoint script, which starts each
> server under its own service account and then execs the application. The
> inference held: it took a Dockerfile change, a new script, and a change to
> both deployment manifests to stop them bootstrapping separately.

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

### I7 — Six variables carry the in-image/external distinction, and nothing else does

From **F11**–**F16**: the only names that address a database or a cache are the
six in **F11**. No variable anywhere in the inventory names a _mode_ — there is
no `AFFINE_EMBEDDED_DB`-style flag to read. A branch between an in-image and an
external service therefore has to be expressed as a test over those six values,
not as a single switch.

### I8 — An in-image service on `localhost` is what the unset case already means

From **F9** and **F11**: with nothing set, the server resolves to
`postgresql://localhost:5432/affine` and `localhost:6379`. Inside a container,
`localhost` is that container. So a database and cache started in the same
container on the standard ports need no variables to be discovered — the empty
case and the in-image case coincide, and setting the variables is what selects
an external target. This is a reading of the defaults, not a tested property.

> **Adopted as the rule, and no longer implicit.** The entrypoint branches on
> exactly this — empty means the server inside the image, set means the one
> outside — but it does not lean on the application's defaults to get there. It
> exports `DATABASE_URL` and the `REDIS_SERVER_*` trio for the servers it
> started, because the bootstrap script's Prisma calls need the value in the
> environment (**I10**) and because the in-image database is reached with a
> generated password rather than on trust. The branch is covered by
> `scripts/self-host-entrypoint.test.sh`, so it is a tested property now.

### I9 — Emptiness is a per-variable signal, and a partially filled set is not detectable

From **F9** (`register.ts:362`, empty is dropped) and **F10** (an invalid value
throws, an absent one does not): a caller that sets `REDIS_SERVER_HOST` but
leaves `DATABASE_URL` empty gets an external cache and a localhost database,
with no error. Nothing in the tree validates the six values of **F11** as a
group.

### I10 — The split must be resolved before the bootstrap script is invoked, not inside it

From **F6** and **F11**: `scripts/self-host-predeploy.js` shells out with
`env: process.env` (`:45`, `:54`, `:68`), and `schema.prisma:10` gives
`DATABASE_URL` no default. Whichever process decides the split has to export the
result into the environment it hands to that script; a decision made afterwards,
or written into `~/.affine/config/config.json`, does not reach the Prisma CLI.

---

## Unverifiable

These cannot be settled from this repository. Each names what would settle it.

### U1 — Whether `ghcr.io/toeverything/affine:stable` matches this repository

`.render/Dockerfile:4` and `compose.yml:4`/`:24` consume a tag whose contents
are decided by a past CI run. Settling this requires pulling the image and
comparing it to a locally produced one.

> **No longer relevant.** Neither consumer reads `:stable` any more —
> `compose.yml` builds `affine:selfhost` from source, and `render.yaml`
> builds the same Dockerfile. Nothing in this repository depends on the
> published tag's contents.

### U2 — Whether the CI install sequence reproduces inside a Docker build

`build-images.yml:246-256` performs `yarn workspaces focus --production`,
`prisma generate`, and a `node_modules` relocation on the CI host. Whether the
same sequence succeeds inside a Docker layer is not observable here: this
worktree has no installed dependencies (`yarn` reports
_"Couldn't find the node_modules state file"_), so no install or build was run
while writing this document.

### U3 — Whether the GitHub Packages registry setup is still required

`build-images.yml:221-226` configures npm against `https://npm.pkg.github.com`
with scope `@toeverything`; `.github/actions/setup-node/action.yml:59` does the
same for every other job. Two kinds of `@toeverything` dependency exist:
workspace links (`@toeverything/infra`, `package.json:103`) and registry
versions — `@toeverything/mermaid-wasm` `^0.1.0`, `@toeverything/pdf-viewer`
`^0.1.1`, `@toeverything/theme` `^1.1.23`
(`packages/frontend/core/package.json:49-51`), `@toeverything/pdfium`
(`blocksuite/playground/package.json:21`). `yarn.lock:16178-16180` resolves
`@toeverything/theme@npm:1.1.23`, but the lockfile does not record which
registry served it. The `build-images` job installs only
`@affine/server --production` (`build-images.yml:250`), whose package declares
no `@toeverything` dependency — so whether that job in particular still needs
the registry, and whether the frontend jobs would fail without it, can only be
determined by running an install with the registry unavailable.

### U4 — Image size and build duration budgets

`scripts/docker-clean.mjs` exists to shrink the image and logs how much it
saved, but no target figure is recorded anywhere in the repository. Without a
stated budget, a restructured build cannot be judged a regression or an
improvement.

### U5 — Whether the multi-architecture matrix must be preserved

`build-images.yml:269` publishes `linux/amd64,linux/arm64,linux/arm/v7`, and
`docker-clean.mjs` prunes per-architecture native binaries and Prisma engines
accordingly. Whether `arm/v7` still has consumers is a product decision, not a
fact in the tree — and it materially changes the cost of building from source.

### U6 — What the initial-setup entrypoint will require from the environment

The bootstrap the ship-ready contract describes — migrations plus a standard
seed, callable from one place on both paths — does not exist in this tree today.
`scripts/self-host-predeploy.js` covers migrations only (`:43`, `:52`), the CLI
exposes `create`, `import` and `run` and nothing that seeds
(`packages/backend/server/src/data/commands/`), and the sole account-creating
path is the HTTP endpoint of **F8**. Its environment surface — whether a
seeded account's credentials arrive as variables at all, and under which names —
cannot be inventoried here. Settling this requires that entrypoint to land.

### U7 — What a single image is expected to persist

**F17** shows persistence expressed only as mounts, and the three existing
deployments disagree on the shape: compose mounts two host directories for the
app and a third for the sibling database (`compose.yml:15-17`, `:52-53`), while
Render mounts one 10 GB disk at `/root/.affine` (`render.yaml:16-21`) and leaves
the database to a managed service. For an image that may run its own database,
nothing in the repository states whether the database directory is expected to
be mounted, whether losing it on restart is acceptable, or what size is assumed.
This is a product decision, not a fact recoverable from the tree.

> **Settled, as a documented choice rather than a forced one.** The image
> declares no `VOLUME`: `/root/.affine`, `/var/lib/postgresql/data` and
> `/var/lib/redis` are the three paths that hold state, and mounting them is the
> operator's decision. [running-the-image.md](./running-the-image.md) lists
> which of the three each path matters on and what is lost without it. No size
> is assumed — that depends on the documents stored, which this repository
> cannot know.

---

## Related documents

- [building-the-image.md](./building-the-image.md) — building the self-host image from source, as it works today
- [running-the-image.md](./running-the-image.md) — running that image, on either side of the database/cache branch
- [BUILDING.md](../BUILDING.md) — building the web app from source
- [developing-server.md](../developing-server.md) — running the server locally
