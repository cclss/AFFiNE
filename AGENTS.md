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

> **Status — all six are in the repository; `preview.toml` declares the two
> preview commands.**
> Every row above resolves to a tracked file — running
> `git ls-files conventions preview.toml` lists all six. Each guide under
> `conventions/` was written against this repository, with the `file:line` it
> was read from next to every claim, rather than copied from a canonical
> original; see [Assumptions]. The preview exception configuration is at the
> root and carries four keys — `model`, `[build] command`, `[serve] command`
> and `[serve] port_env` (`preview.toml:29-45`) — naming the build and start
> scripts under `scripts/preview/`, because the root `build` script refuses
> without a target and auto-detection has nothing to find. Every value was read
> off this repository — the two commands name scripts in it, and `model` and
> `port_env` cite the `file:line` they were read from. Nothing beyond those four
> is declared: the key names themselves come from the preview platform's
> contract rather than from any file here — see [Assumptions]. Do not read the
> four as permission to invent a fifth.

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

`-p web` starts and serves on `8080`. `-p server` does not start after a clean
`yarn install` — it crashes on a native module the install does not build, and
`nodemon` restarts the crash rather than exiting. Nothing ever binds `3010`.
See [Known Gaps].

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
| Root `dev` has no non-interactive path | `package.json:23`, `tools/cli/src/command.ts:106-133`, `tools/cli/src/affine.ts:29` | `yarn dev` expands to `yarn affine dev`. `DevCommand` extends `PackageSelectorCommand`, which falls back to an interactive `inquirer` list prompt when `-p` is absent. Neither outcome without a terminal is a build: with stdin held open the prompt never resolves and the process blocks; with stdin at EOF — `< /dev/null`, the usual CI and agent case — the prompt cannot resolve either, and node exits 1 reporting `Detected unsettled top-level await` |
| No dummy account to document | `packages/backend/server/src/seed/index.ts:29-42,43-85` | `seed` generates entities from arguments with random attributes. There are no fixed credentials in the repository, so this contract cannot print a login to try |
| The Dockerfile does not build the app | `.render/Dockerfile:4-8` | It starts `FROM ghcr.io/toeverything/affine:stable` and copies in a start script. Nothing is compiled inside it. There is no from-source image build path in the repository yet |
| Deployment is not a single container | `render.yaml:8-52` | Web, PostgreSQL, and the key-value store are three separate services. Any instruction that assumes one self-contained container is wrong against this repository |
| The preview configuration's schema is not evidenced in this repository | `preview.toml:1-27`, `preview.toml:29-45` | The file declares the preview model, the build command, the serve command and the port variable, every value read off this repository — the two commands name scripts in it, and the other two carry the `file:line` they were read from. The schema those key *names* satisfy is the preview platform's, and it is not a file here, so nothing in this repository can be cited for them — see [Assumptions]. None of the five guides describes one either. A reader who needs to know which other keys are accepted has nothing here to read, and that stays so until the schema is confirmed |
| Every server entry point needs a native module `yarn install` does not build | `packages/backend/native/index.js:11`, `packages/backend/server/package.json:19,20`, `.yarnrc.yml:9` | After a clean `yarn install`, anything that loads the server's prelude exits with `Error: Cannot find module './server-native.x64.node'`. That is not only First-Time Setup: `yarn affine dev -p server`, `yarn run seed` in any form, and `yarn workspace @affine/server genconfig` ([conventions/env.md]) all stop there. `@affine/server-native` is a Rust napi module; `enableScripts: false` means no install hook builds it, and no script in this repository builds it either. `yarn workspace @affine/server-native build:debug` was run here: it compiled and then failed at the link step with `collect2: fatal error: ld terminated with signal 7 [Bus error]` on a volume that had reached 100 percent, so the failure is not established as a toolchain defect and no verified build command is printed **(assumption — needs confirming)** |
| `yarn run init` stops on an interactive prompt | `packages/backend/server/package.json:18`, `packages/backend/server/schema.prisma:5,11` | Against an empty database at a reachable `DATABASE_URL`, `prisma migrate dev` applies all 119 migrations and then asks `Enter a name for the new migration:`, because `schema.prisma` and the migration history diverge — `prisma migrate diff` between them emits `CREATE EXTENSION IF NOT EXISTS "vector"` plus foreign-key and index changes. `prisma migrate status` still reports the database up to date. With no terminal the command blocks at the prompt and never reaches `yarn data-migration run` |
| First-Time Setup cannot be reached from a checkout | this table's two rows above, `packages/backend/server/package.json:22` | Following the section in order gets nowhere today: `init` blocks at the prompt, `predeploy` exits with `Cannot find module '.../dist/main.js'` because nothing here builds `dist`, and `seed` exits on the missing native module. The section records the commands the repository declares, not a path that completes |

These gaps are scheduled to be closed by later work. When one closes, the
section above it must be rewritten to describe what the command then does —
this page describes the repository as it is, not as it is planned to be. Which
sections that rewrite touches, and what sets it off, is in [Realignment].

## Realignment

This is the first edition of this contract. Everything on it was read off the
repository, and every command under [Run It Locally] and [First-Time Setup] was
run against it on 2026-09-05 — it is a record of current behaviour, not of
planned behaviour. Three pieces of work are expected to change that behaviour,
and each one invalidates part of this page when it lands.

When a trigger below lands, the three things in its row are re-read against the
new behaviour and rewritten together, in the same change: the section that
carries the command, the [Known Gaps] rows that explain why the command does
not work today, and the guide the section delegates to. A command corrected in
one place and left stale in the other two is how this page starts lying.

| Trigger | Sections And Gap Rows On This Page | Guides To Re-Read |
|---|---|---|
| A local run that takes one command | [Run It Locally] — and the gap rows for root `build` with no arguments, root `dev` with no non-interactive path, and the native module `yarn install` does not build | [conventions/stack.md] |
| A bootstrap that completes without a prompt | [First-Time Setup] — and the gap rows for `yarn run init` stopping on a prompt, First-Time Setup being unreachable from a checkout, and there being no dummy account to document | [conventions/datastore.md], [conventions/env.md] |
| A deployment that is one container | [Ship It As A Container] — and the gap rows for the Dockerfile not building the app and for deployment not being a single container | [conventions/deploy.md], [conventions/networking.md] |

The native-module row appears once, under the first trigger, because that is
where the fix belongs; it also blocks [First-Time Setup] today, so closing it
means re-reading both sections. [Topic Guides] and [Assumptions] are not in the
table: the first states the document set the contract requires, which none of
the three triggers changes, and the second is settled item by item as evidence
arrives rather than on a trigger.

Until a trigger lands, its row's section keeps the commands this repository
declares today, and its gap rows stay as they are. Nothing on this page is
written ahead of the behaviour it describes.

## Assumptions

Unresolved. Recorded so the next reader does not mistake them for settled facts.

- The frontend dev server port is not set explicitly in the CLI config; the
  client websocket URL is `ws://0.0.0.0:8080/ws`
  (`tools/cli/src/bundle-shared.ts:43`), which implies `8080`, the
  `rspack-dev-server` default. Running `yarn affine dev -p web` here bound
  `0.0.0.0:8080` and printed `Local: http://localhost:8080/`, so `8080` is what
  the command does today. That it stays `8080` rests on the bundled
  `rspack-dev-server` default rather than on anything this repository sets, so a
  dependency bump can move it without a change here
  **(assumption — needs confirming)**.
- The container path on this page has been read, not run. `docker build`, and
  the `docker compose` and `docker image inspect` commands the guides carry,
  were checked out against `.render/Dockerfile:4-8`, `.render/start.sh:2-12`,
  and `render.yaml:8-52` only — no Docker daemon was available where this page
  was verified, so what the built image does at boot is read off those files
  rather than observed **(assumption — needs confirming)**. Everything under
  [Run It Locally] and [First-Time Setup], by contrast, was executed, and what
  it did is what this page and [Known Gaps] record.
- No upstream source text for the five topic guides was found in this
  repository. They were therefore written against this repository — each claim
  carries the `file:line` it was read from — rather than copied from a canonical
  original. That the result is what the contract naming them intended is
  **(assumption — needs confirming)**.
- The four keys in `preview.toml` are the ones the preview platform's contract
  names. Their values were read off this repository, but the key names and the
  values each of them accepts have no source here, so that the file
  satisfies the schema is **(assumption — needs confirming)**. The same note is
  at the top of the file itself (`preview.toml:1-27`), so a reader who opens it
  without this contract still sees which part of it is evidenced and which is
  not.
- The two commands `preview.toml` names have not been run end to end. Their
  branch behaviour is covered by `scripts/preview/build.test.sh` and
  `scripts/preview/start.test.sh`, which run them against stub toolchains and
  need neither a network nor a database; that the real toolchain then produces a
  server which answers its first screen is **(assumption — needs confirming)**.

[conventions/stack.md]: ./conventions/stack.md
[conventions/datastore.md]: ./conventions/datastore.md
[conventions/env.md]: ./conventions/env.md
[conventions/networking.md]: ./conventions/networking.md
[conventions/deploy.md]: ./conventions/deploy.md
[preview.toml]: ./preview.toml
[Topic Guides]: #topic-guides
[Run It Locally]: #run-it-locally
[First-Time Setup]: #first-time-setup
[Ship It As A Container]: #ship-it-as-a-container
[Known Gaps]: #known-gaps
[Realignment]: #realignment
[Assumptions]: #assumptions
