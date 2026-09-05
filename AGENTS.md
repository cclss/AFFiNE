# AGENTS.md

The run and ship contract for this repository. If you are a coding agent, read
this page first — it is the entry point for three things and nothing else:
running AFFiNE locally, bootstrapping it the first time, and exporting it as a
container. Everything below that is a detail, and details live in the topic
guides.

Every command on this page was read off the repository at the file and line
cited next to it. Where the repository does not back a claim, the claim is
marked `(assumption — needs confirming)` rather than filled in. Where the
repository contradicts what you would expect, it is written down under
[Known Gaps] instead of being smoothed over. A contract whose
commands do not run is worse than no contract.

## Topic Guides

This page holds entry points. These six files hold the rules.

| Guide | What It Covers |
|---|---|
| [conventions/stack.md] | Monorepo package layout, the `affine` command set from `tools/cli`, and the package aliases |
| [conventions/datastore.md] | The datastores the server requires — PostgreSQL and a key-value store — and how they are provisioned |
| [conventions/env.md] | Environment variables needed to boot each service, and where their values come from |
| [conventions/networking.md] | Ports each service opens and the paths services use to reach one another |
| [conventions/deploy.md] | Image build and boot procedure, including what `.render/Dockerfile` does and does not do |
| [preview.toml] | Preview exception configuration |

> **Status — none of these six files exist in the repository yet.** This
> contract is the first document of the set to land. Until the rest arrive,
> every row above is a forward reference, and the detail you need is in the
> source paths cited on this page. Do not treat a missing guide as permission to
> invent its contents. The absence is recorded as a gap — see [Known Gaps].

## Run It Locally

### Prerequisites

- Node — `>=22.12.0 <23.0.0` (`package.json:17-19`). The pinned version is in
  `.nvmrc`.
- Yarn — `yarn@4.18.0` (`package.json:131`). This is a Yarn workspace monorepo
  with `nodeLinker: node-modules` (`.yarnrc.yml`).
- Rust toolchain — `rust-toolchain.toml` at the root. `@affine/server-native`
  (`packages/backend/native`) is a napi module built from Rust, so the server
  path needs it.
- A running PostgreSQL and a running key-value store before the server boots.
  See [conventions/datastore.md]; `.docker/dev/compose.yml.example` is the
  in-repo starting point.

### Install

```sh
# Installs workspace dependencies. The postinstall hook runs `yarn affine init`,
# which generates tsconfigs, `.oxlintrc.json`, and `workspace.gen.ts`
# (package.json:35, tools/cli/src/init.ts:23-33).
yarn install
```

### Start A Target

`dev` and `build` both take a target. Always pass one explicitly.

```sh
# Frontend dev server. Proxies /api, /graphql, and /socket.io to
# http://localhost:3010 (tools/cli/src/bundle-shared.ts:57-71).
yarn affine dev -p web

# Backend server. Runs `nodemon ./src/index.ts`; listens on 3010 by default
# (packages/backend/server/src/core/config/config.ts:67-71).
yarn affine dev -p server
```

Run the two in separate shells — the frontend dev server expects the backend to
already be answering on `3010`.

`-p` accepts a full package name (`@affine/web`) or an alias (`web`). Aliases
come from `AliasToPackage` in `tools/utils/src/distribution.ts`, which maps ten
names by hand and then derives one alias per workspace package from its last
path segment. Do not trust a copied list of aliases — ask the CLI:

```sh
# Prints the accepted targets for a command.
yarn affine dev -h
```

`yarn affine dev` without `-p` offers an interactive picker over eight targets:
`@affine/web`, `@affine/server`, `@affine/electron`, `@affine/electron-renderer`,
`@affine/mobile`, `@affine/ios`, `@affine/android`, `@affine/admin`
(`tools/cli/src/dev.ts:8-17`). Do not rely on that path — see
[Known Gaps].

## First-Time Setup

Setup is a server-package concern. Run these from
`packages/backend/server` with PostgreSQL reachable at `DATABASE_URL`.

### Migrate

```sh
# Development: applies Prisma migrations, then the data migrations
# (packages/backend/server/package.json:18). `run` is not optional here —
# `yarn init` alone hits Yarn's built-in init command, not this script.
yarn run init

# Deployment: admits legacy context blobs, applies migrations with
# `prisma migrate deploy`, then runs data migrations
# (packages/backend/server/package.json:22). Requires a built `dist/main.js`.
yarn run predeploy
```

`predeploy` runs against compiled output — `cli` is
`node ./dist/main.js` (`packages/backend/server/package.json:21`), so build the
server before invoking it. `init` is the source-mode equivalent for local work.

The self-host path wraps the same work in one script: it generates
`~/.affine/config/private.key` on first boot if absent, then runs the Prisma and
data migrations (`packages/backend/server/scripts/self-host-predeploy.js:7,27-38,95-98`).
It is safe to run on every boot. Key generation and the rest of the environment
contract are in [conventions/env.md].

### Seed

```sh
# Prints the available entities and their inputs.
yarn run seed

# Creates one User with random attributes.
yarn run seed User

# Creates three Users.
yarn run seed User 3
```

`seed` builds entities from mock factories using the arguments you pass
(`packages/backend/server/src/seed/index.ts:9-42`). It creates **no fixed
accounts** — see [Known Gaps].

## Ship It As A Container

The container path is `.render/Dockerfile` plus `render.yaml`.

```sh
# Builds the deployable image. Build context is ./.render, matching
# render.yaml:13-14.
docker build -f .render/Dockerfile .render
```

What the image does at boot: `.render/start.sh` resolves the external hostname
into `AFFINE_SERVER_HOST`, runs `self-host-predeploy.js` (key generation plus
migrations), then execs `node ./dist/main.js`.

`render.yaml` describes one project with three pieces:

| Piece | Definition | Notes |
|---|---|---|
| Web service | `render.yaml:8-40` | Docker runtime, `dockerfilePath: ./.render/Dockerfile`, health check on `/info`, `AFFINE_SERVER_PORT=10000`, 10 GB disk at `/root/.affine` for blobs and the generated private key |
| Key-value store | `render.yaml:42-46` | `maxmemoryPolicy: noeviction`, internal connections only; supplies `REDIS_SERVER_HOST` and `REDIS_SERVER_PORT` |
| PostgreSQL | `render.yaml:48-52` | Major version 16, internal connections only; supplies `DATABASE_URL` |

Wiring between the three, and the ports each opens, are in
[conventions/networking.md] and [conventions/deploy.md].

## Known Gaps

These are the places where the repository does not do what this contract would
otherwise promise. They are recorded here rather than papered over. Each one is
a defect to close, not a rule to follow.

| Gap | Evidence | What Happens Today |
|---|---|---|
| Root `build` fails with no arguments | `package.json:24`, `tools/cli/src/command.ts:40-44`, `tools/cli/src/build.ts:3` | `yarn build` expands to `yarn affine build`. `BuildCommand` extends `PackageCommand`, whose `--package,-p` option is `required: true`. With no target the command errors out instead of building anything |
| Root `dev` hangs when not attached to a terminal | `package.json:23`, `tools/cli/src/command.ts:106-133` | `yarn dev` expands to `yarn affine dev`. `DevCommand` extends `PackageSelectorCommand`, which falls back to an interactive `inquirer` list prompt when `-p` is absent. In CI, a container, or an agent session there is nobody to answer, so it blocks |
| No dummy account to document | `packages/backend/server/src/seed/index.ts:29-42,43-85` | `seed` generates entities from arguments with random attributes. There are no fixed credentials in the repository, so this contract cannot print a login to try |
| The Dockerfile does not build the app | `.render/Dockerfile:4-8` | It starts `FROM ghcr.io/toeverything/affine:stable` and copies in a start script. Nothing is compiled inside it. There is no from-source image build path in the repository yet |
| Deployment is not a single container | `render.yaml:8-52` | Web, PostgreSQL, and the key-value store are three separate services. Any instruction that assumes one self-contained container is wrong against this repository |
| The topic guides this page delegates to do not exist | Repository tree — there is no `conventions/` directory at the root, and `git ls-files conventions preview.toml` returns nothing | Every link in [Topic Guides] resolves to a missing file. The six rows state the contract's document set, not the repository's current contents. Until each guide lands, the only detail available is the source paths cited on this page. No upstream text for the guides was found either — see [Assumptions] |

These gaps are scheduled to be closed by later work. When one closes, the
section above it must be rewritten to describe what the command then does —
this page describes the repository as it is, not as it is planned to be.

## Assumptions

Unresolved. Recorded so the next reader does not mistake them for settled facts.

- The frontend dev server port is not set explicitly in the CLI config; the
  client websocket URL is `ws://0.0.0.0:8080/ws`
  (`tools/cli/src/bundle-shared.ts:43`), which implies `8080`, the
  `rspack-dev-server` default. The effective port is
  **(assumption — needs confirming)**.
- No upstream source text for the five topic guides or for `preview.toml` was
  found in this repository. Their contents will be written against this
  repository rather than copied from a canonical original
  **(assumption — needs confirming)**.
- The schema `preview.toml` must satisfy is unknown. It will be kept minimal
  until the schema is confirmed **(assumption — needs confirming)**.

[conventions/stack.md]: ./conventions/stack.md
[conventions/datastore.md]: ./conventions/datastore.md
[conventions/env.md]: ./conventions/env.md
[conventions/networking.md]: ./conventions/networking.md
[conventions/deploy.md]: ./conventions/deploy.md
[preview.toml]: ./preview.toml
[Topic Guides]: #topic-guides
[Known Gaps]: #known-gaps
[Assumptions]: #assumptions
