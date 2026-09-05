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

> **Status — all six are in the repository; `preview.toml` declares nothing.**
> The five guides under `conventions/` are tracked — `git ls-files conventions`
> lists all five. Each was written against this repository, with the
> `file:line` it was read from next to every claim, rather than copied from a
> canonical original; see [Assumptions]. The preview exception configuration is
> at the root, but it holds comments only and parses as an empty TOML document:
> no upstream text or schema for it was found, so no keys were invented. Do not
> treat the empty file as permission to invent its contents. That it configures
> nothing yet is recorded as a gap — see [Known Gaps].

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
path segment. Do not trust a copied list of aliases — make the CLI print it:

```sh
# Passing an unknown target makes the validator reject it and enumerate every
# accepted literal — 246 entries, full package names first, then the aliases.
# Exits 1; the list is the point, not the exit code. The accepted set is built
# in `tools/cli/src/command.ts:32-37` from the workspace package names plus the
# `AliasToPackage` keys (`tools/utils/src/distribution.ts:16-30`).
yarn affine dev -p nosuchpkg
```

`-h` does **not** print the target list — it prints only the `--package,-p` and
`--deps` option descriptions.

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
`cross-env SERVER_FLAVOR=script node ./dist/main.js`
(`packages/backend/server/package.json:21`), so build the server before invoking
it. `init` is the source-mode equivalent for local work.

The self-host path wraps the same work in one script: it generates
`~/.affine/config/private.key` on first boot if absent, then runs the Prisma and
data migrations (`packages/backend/server/scripts/self-host-predeploy.js:7,27-38,95-98`).
It is safe to run on every boot. Key generation and the rest of the environment
contract are in [conventions/env.md].

### Seed

```sh
# Prints usage, examples, and where the entity list lives.
yarn run seed

# Creates one User with random attributes.
yarn run seed User

# Creates three Users.
yarn run seed User 3
```

`seed` builds entities from mock factories using the arguments you pass
(`packages/backend/server/src/seed/index.ts:9-42`). The entity names live in
`server/src/__tests__/mocks/*.mock.ts`; passing an unknown one prints the full
list (`:32-36`). It creates **no fixed accounts** — see [Known Gaps].

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
| The preview exception configuration declares nothing | `preview.toml:1-9` | The file is at the root and every line in it is a comment, so it parses as an empty TOML document and configures no preview exception. No upstream text or schema for it was found, so no keys were invented — see [Assumptions]. None of the five guides describes one either. Anything reading this file for a preview exception today gets nothing |
| Server scripts need a native module `yarn install` does not build | `packages/backend/native/index.js:11`, `packages/backend/server/package.json:19` | After a clean `yarn install`, `yarn run seed` exits with `Error: Cannot find module './server-native.x64.node'`. `@affine/server-native` is a Rust napi module and its binary is not produced by install, so every First-Time Setup command sits behind a build step this contract cannot yet name — building it was attempted and the local linker failed, so no verified command is printed here **(assumption — needs confirming)** |

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
  found in this repository. The five guides were therefore written against this
  repository — each claim carries the `file:line` it was read from — rather than
  copied from a canonical original. That the result is what the contract naming
  them intended is **(assumption — needs confirming)**.
- The schema `preview.toml` must satisfy is unknown. The file therefore carries
  a header comment stating its role and no keys, and it stays that way until the
  schema is confirmed **(assumption — needs confirming)**. The same note is at
  the top of the file itself (`preview.toml:1-9`), so a reader who opens it
  without this contract still sees why it is empty.

[conventions/stack.md]: ./conventions/stack.md
[conventions/datastore.md]: ./conventions/datastore.md
[conventions/env.md]: ./conventions/env.md
[conventions/networking.md]: ./conventions/networking.md
[conventions/deploy.md]: ./conventions/deploy.md
[preview.toml]: ./preview.toml
[Topic Guides]: #topic-guides
[Known Gaps]: #known-gaps
[Assumptions]: #assumptions
