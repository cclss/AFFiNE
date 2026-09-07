# Deploy

How a runnable image of this application is produced, what goes into it, and
what runs between container start and the server accepting requests. Every claim
below is followed by the `file:line` it was read from. Where the repository does
not back a claim, it is marked `(assumption — needs confirming)` rather than
filled in.

## Scope Statement

This guide answers three questions:

- What the image build compiles, in which stage, and in what order.
- What ends up inside the image, and where.
- What the container does, in order, before the server listens — and which of
  those decisions the operator makes rather than the image.

It does not answer: what the variables the entrypoint reads mean
([conventions/env.md]), which port the started process opens
([conventions/networking.md]), or what the stores it migrates must provide
([conventions/datastore.md]). The `docker build` invocation itself is the
contract's entry point, not this guide's — see [AGENTS.md]. The step-by-step
walkthroughs, including build arguments and verification commands, are in
[docs/self-host/building-the-image.md] and [docs/self-host/running-the-image.md].

The headline fact: **there is one Dockerfile and it compiles everything.**
`.github/deployment/node/Dockerfile` builds the native addon, the four frontend
bundles and the server bundle inside the build; nothing is pulled from a
published tag (`.github/deployment/node/Dockerfile:198-223`,
`render.yaml:12-15`). The same file is what CI hands to `buildx`
(`.github/workflows/build-images.yml:54-68`) and what
`.docker/selfhost/compose.yml:18-22` builds, so there is one image definition
and three ways to ask for it.

## The Build

Seven stages, all on the same `ARG NODE_IMAGE=node:22-bookworm-slim` base
(`.github/deployment/node/Dockerfile:8`).

| #   | Stage            | Evidence                                     | What It Produces                                                                                                                                                                              |
| --- | ---------------- | -------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | `manifests`      | `.github/deployment/node/Dockerfile:18-33`   | Every workspace `package.json`, the lockfile, `.yarnrc.yml` and `.yarn/releases`, extracted into `/manifests` so that an install layer invalidates on a manifest change and not on a source edit |
| 2   | `deps`           | `:38-81`                                     | The workspace `node_modules`, installed from the lockfile with `--immutable --mode=skip-build` behind a Yarn cache mount (`:74-81`); stage 3 installs a second time, with the tree complete, so the deferred build scripts run (`:173-177`) |
| 3   | `build`          | `:95-223`                                    | The Rust toolchain `rust-toolchain.toml` pins (`:134-142`), then five builds in dependency order — see below                                                                                   |
| 4   | `runtime-deps`   | `:238-285`                                   | `yarn workspaces focus @affine/server --production`, `prisma generate`, and the resulting tree moved to the server package root, in one layer                                                  |
| 5   | `runtime-assets` | `:294-338`                                   | The assembled `/app`: production `node_modules`, three static bundles, `scripts/`, `schema.prisma`, `migrations/`, the server manifest, then `docker-clean.mjs`, then `dist`                   |
| 6   | `pgdg-key`       | `:360-383`                                   | The PostgreSQL apt signing key, fetched and checked against a pinned fingerprint (`:373`)                                                                                                      |
| 7   | `runtime`        | `:407-521`                                   | PostgreSQL and Redis installed into the image, jemalloc preloaded (`:494`), `/app` copied forward, `ENTRYPOINT` and `CMD` set (`:520-521`)                                                     |

Stage 3 builds five artifacts, each in its own layer so that a change to one
frontend does not rebuild the others.

| Order | Command                                  | Asserted Artifact                                     | Evidence  |
| ----- | ---------------------------------------- | ----------------------------------------------------- | --------- |
| 1     | `yarn workspace @affine/server-native build` | `packages/backend/native/server-native.node`       | `:198-203` |
| 2     | `yarn affine @affine/web build`          | `packages/frontend/apps/web/dist/selfhost.html`       | `:205-207` |
| 3     | `yarn affine @affine/admin build`        | `packages/frontend/admin/dist/selfhost.html`          | `:209-211` |
| 4     | `yarn affine @affine/mobile build`       | `packages/frontend/apps/mobile/dist/selfhost.html`    | `:213-215` |
| 5     | `yarn workspace @affine/server build`    | `dist/main.js` and `dist/server-native.node`          | `:219-223` |

The addon comes first because the server bundler emits `server-native.node`
beside `main.js` (`:217-218`). Every step asserts what it wrote with `test -f`,
so a tool that exits zero without producing its artifact fails the build there
rather than four stages later. Two build arguments steer the output —
`BUILD_TYPE`, the release channel baked into the frontend bundles, and
`GITHUB_SHA`, stamped into the HTML and the assets manifest, which must be
supplied because `.dockerignore:5` keeps `.git` out of the context
(`:185-188`).

`scripts/preview/build.sh` is stage 3 with the container taken away: the same
install, the same toolchain pin, and four of the same five builds in the same
order, staged into the server package instead of into an image
(`scripts/preview/build.sh:272-303`). The mobile bundle is the one it omits,
because that bundle is reached only on the canary namespace
(`scripts/preview/build.sh:26-28`).

## Inside The Image

| Path In Image        | Source                                        | Evidence                                |
| -------------------- | --------------------------------------------- | --------------------------------------- |
| `/app/node_modules`  | The production closure from `runtime-deps`    | `.github/deployment/node/Dockerfile:309` |
| `/app/static`        | `packages/frontend/apps/web/dist`             | `:310`                                  |
| `/app/static/admin`  | `packages/frontend/admin/dist`                | `:311`                                  |
| `/app/static/mobile` | `packages/frontend/apps/mobile/dist`          | `:312`                                  |
| `/app/scripts`       | `packages/backend/server/scripts`             | `:313`                                  |
| `/app/schema.prisma` | `packages/backend/server/schema.prisma`       | `:314`                                  |
| `/app/package.json`  | `packages/backend/server/package.json` — `yarn cli run` is a script in it | `:315-318`   |
| `/app/migrations`    | `packages/backend/server/migrations`          | `:319-322`                              |
| `/app/dist`          | `packages/backend/server/dist`                | `:338`                                  |

That layout is what the server's static routes read at runtime — it resolves
`static/` relative to the directory above `dist`
(`packages/backend/server/src/env.ts:105`,
`packages/backend/server/src/core/selfhost/static.ts:29`). Which of those routes
are mounted is [conventions/networking.md]'s subject.

`docker-clean.mjs` runs with `AFFINE_DOCKER_CLEAN=1` between the assets and
`dist` (`.github/deployment/node/Dockerfile:330-334`). It is a no-op without that
variable (`packages/backend/server/scripts/docker-clean.mjs:12,757-760`) and
otherwise deletes every `.map` under `static` and `node_modules`, hardlinks
duplicate static assets, keeps only the current architecture's Prisma query
engine, and removes `src`, `typescript`, `@types`, `tsconfig.json`, and
`config.example.json` (`:762-826`). `dist` is copied **after** it, on purpose:
the script's dist rule keeps the one `server-native.<arch>.node` matching
`TARGETARCH`, and this build compiles exactly one, named `server-native.node`,
which that rule would not recognise and would delete
(`.github/deployment/node/Dockerfile:324-329`).

## Boot Sequence

`ENTRYPOINT` is `packages/backend/server/scripts/self-host-entrypoint.sh` and
`CMD` is `node ./dist/main.js`
(`.github/deployment/node/Dockerfile:520-521`). Render overrides only `CMD`, so
the entrypoint runs on every path (`render.yaml:16-22`). Four things happen, in
this order.

| #   | Step                                                                                                                                                        | Evidence                                                                       |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| 1   | `set -eu`, then the application root is resolved from the script's own location rather than from `WORKDIR`                                                   | `packages/backend/server/scripts/self-host-entrypoint.sh:26,52-57`               |
| 2   | `PORT` and `REDIS_URL` are translated into the names this server reads, ahead of the branch below — see [conventions/env.md]                                 | `packages/backend/server/scripts/self-host-entrypoint.sh:337-347`                |
| 3   | The branch, once per store: an empty `DATABASE_URL` starts the PostgreSQL inside the image, an empty `REDIS_SERVER_HOST` starts the Redis inside it, and a filled one means the operator's own | `packages/backend/server/scripts/self-host-entrypoint.sh:356-368`                |
| 4   | `node ./scripts/self-host-predeploy.js` — private key, schema migrations, data migrations, standard seed — then `exec` of the command                        | `packages/backend/server/scripts/self-host-entrypoint.sh:373,381-388`            |

Step 3 is the only branch on where the data lives. Nothing downstream repeats
it — not the server, not the predeploy script, not the compose file
(`packages/backend/server/scripts/self-host-entrypoint.sh:18-21`,
`.docker/selfhost/compose.yml:34-38`). Step 4 runs on both of its paths and is
idempotent by construction: the key is written only when missing, `migrate
deploy` applies only what is outstanding, and the seed stops as soon as the
database holds a user
(`packages/backend/server/scripts/self-host-predeploy.js:170-174`).

`exec` replaces the shell, so the server is PID 1 and receives the container's
stop signal directly. That also gives up the chance to forward the signal to the
embedded servers, which are killed rather than asked to stop — survivable, and
recorded as a trade rather than left to be rediscovered
(`packages/backend/server/scripts/self-host-entrypoint.sh:379-388`).

`scripts/preview/start.sh` is this sequence with the image taken away: the same
`runtime-env.sh` is sourced, the same predeploy script is run, and the same
bundle is exec'd — minus step 3, because a host has no embedded stores to start
and an empty `DATABASE_URL` is refused instead
(`scripts/preview/start.sh:110-117,164,200-218`).

## Deployment Shapes

The image is the same in all three; only who supplies the stores changes.

| Shape         | Definition                                | Stores                                                                                                                                                 |
| ------------- | ----------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| One container | `docker run` with neither variable set    | Both started inside the image by the entrypoint (`packages/backend/server/scripts/self-host-entrypoint.sh:356-368`)                                     |
| Compose       | `.docker/selfhost/compose.yml:15-68`      | `REDIS_SERVER_HOST=redis` and `DATABASE_URL=postgresql://affine@postgres:5432/affine`, so the embedded pair is left alone (`:34-40`)                    |
| Render        | `render.yaml:8-70`                        | Managed PostgreSQL 16 and key-value service, injected as `DATABASE_URL`, `REDIS_SERVER_HOST` and `REDIS_SERVER_PORT` (`:45-58`, `:60-70`)               |

There is no separate migration container in any of them. The compose file used
to carry one and no longer does, because the entrypoint runs the bootstrap on
every start (`.docker/selfhost/compose.yml:8-13`). The disk Render mounts at
`/root/.affine` is what keeps the generated private key and the uploaded blobs
across restarts (`render.yaml:24-29`, and see [conventions/env.md]).

## Commands

```sh
# List every Dockerfile the repository tracks. Two today: the image build and a
# PostgreSQL image for the Helm chart.
git ls-files '*Dockerfile*'

# Build the image from source. The context is the repository root, not the
# Dockerfile's directory — the build compiles the workspace, so it needs the
# workspace (.docker/selfhost/compose.yml:19-22).
docker build -f .github/deployment/node/Dockerfile -t affine:selfhost .

# Print the boot steps in order, without running them. This is the file the
# image makes its ENTRYPOINT (.github/deployment/node/Dockerfile:520).
cat packages/backend/server/scripts/self-host-entrypoint.sh

# Assert the entrypoint's branches against stub binaries. Needs neither Docker
# nor a database, so it is the one check on this page a checkout can run.
sh packages/backend/server/scripts/self-host-entrypoint.test.sh
```

## Known Gaps

| Gap                                                       | Evidence                                                                                                    | What Happens Today                                                                                                                                                                                                                                                                                                                          |
| --------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Migrations run inside the serving container on every boot | `packages/backend/server/scripts/self-host-entrypoint.sh:373`, `render.yaml:8-58`                            | The web service is the migration runner. Scale it past one instance and two containers can run `prisma migrate deploy` against the same database at the same time; nothing in this path takes a lock. The compose file no longer has a separate job to avoid this with (`.docker/selfhost/compose.yml:8-13`), so every shape shares the risk |
| The embedded servers are killed rather than stopped       | `packages/backend/server/scripts/self-host-entrypoint.sh:379-388`                                            | `exec` replaces the shell, so nothing is left to forward `SIGTERM` to the PostgreSQL and Redis the entrypoint started. They are terminated with the container and recover on the next start from crash recovery and snapshots. Correct for the data, but the shutdown is unclean and no measurement of the recovery cost is recorded here   |
| A nested ignore file has no build to apply to             | `packages/backend/server/.dockerignore:1-2`, `.dockerignore:1-2`, `.github/deployment/node/Dockerfile:314`   | The server package carries a `.dockerignore` excluding `schema.prisma`, but the build context is the repository root, whose own `.dockerignore` does not exclude it. The nested file appears to be inert **(assumption — needs confirming)** — and the schema is copied deliberately, so following the nested file's intent would break the build |
| The image advertises a port it does not listen on         | `.github/deployment/node/Dockerfile:511`, `render.yaml:41-42`                                                | The image declares `EXPOSE 3010`; the Render deployment sets the process to bind `10000`. Any tool that reads image metadata to decide where to connect points at a closed port                                                                                                                                                             |

## Assumptions

- That the hosting platform builds `.github/deployment/node/Dockerfile` with the
  repository root as the context exactly as a local `docker build` would
  (`render.yaml:12-15`) is taken from the configuration file's own fields. The
  platform's build behaviour is not defined in this repository
  **(assumption — needs confirming)**.
- No `docker build`, `docker run` or `docker compose` command on this page was
  executed where this guide was verified — no Docker daemon was available. Every
  claim about what the image contains and does is read off the Dockerfile, the
  entrypoint and the compose file **(assumption — needs confirming)**. The
  entrypoint's branch behaviour is the exception: it is asserted by
  `packages/backend/server/scripts/self-host-entrypoint.test.sh`, which runs
  against stub binaries.
- Docker consults only the build context's root ignore file, which is why the
  gap row above calls `packages/backend/server/.dockerignore` inert. That is
  builder behaviour, not a repository fact, and no test here pins it
  **(assumption — needs confirming)**.
- `yarn cli run`, the data-migration step
  (`packages/backend/server/scripts/self-host-predeploy.js:107-109`), is assumed
  to be idempotent because the entrypoint runs it on every boot. The script's
  header says the sequence is safe to re-run
  (`packages/backend/server/scripts/self-host-entrypoint.sh:370-372`); the
  migrations themselves were not read to confirm it
  **(assumption — needs confirming)**.

[AGENTS.md]: ../AGENTS.md
[conventions/datastore.md]: ./datastore.md
[conventions/env.md]: ./env.md
[conventions/networking.md]: ./networking.md
[docs/self-host/building-the-image.md]: ../docs/self-host/building-the-image.md
[docs/self-host/running-the-image.md]: ../docs/self-host/running-the-image.md
