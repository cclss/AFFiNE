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
| [conventions/env.md] | Environment variables needed to boot each service, including the two platform names that are translated on the way in |
| [conventions/networking.md] | Ports each service opens and the paths services use to reach one another |
| [conventions/deploy.md] | Image build and boot procedure, including what `.github/deployment/node/Dockerfile` compiles and what its entrypoint decides |
| [preview.toml] | Preview exception configuration |

> **Status — all six are in the repository; `preview.toml` declares the two
> preview commands.**
> Every row above resolves to a tracked file — running
> `git ls-files conventions preview.toml` lists all six. Each guide under
> `conventions/` was written against this repository, with the `file:line` it
> was read from next to every claim, rather than copied from a canonical
> original; see [Assumptions]. The preview exception configuration is at the
> root and carries four keys — `model`, `[build] command`, `[serve] command`
> and `[serve] port_env` (`preview.toml:31,33-36,38-45`) — naming the build and
> start scripts under `scripts/preview/`, because the root `build` script
> refuses without a target and auto-detection has nothing to find. Every value
> was read off this repository — the two commands name scripts in it, and
> `model` and `port_env` cite the `file:line` they were read from. Nothing
> beyond those four is declared: the key names themselves come from the preview
> platform's contract rather than from any file here — see [Assumptions]. Do not
> read the four as permission to invent a fifth.

## Run It Locally

Two commands, both run from the repository root, turn a clean checkout into a
server answering on one port. They are the two `preview.toml` names
(`preview.toml:36,41`), and they are the container image's build and boot with
the container taken away — the same install, the same toolchain pin, four of the
image's five builds, then the same bootstrap script
(`scripts/preview/build.sh:14-28`, `scripts/preview/start.sh:11-21`).

### Prerequisites

- Node — the major version `.nvmrc` pins (`22.23.2`), inside the `engines` range
  the root manifest declares (`package.json:17-19`). A different major builds and
  is reported rather than refused (`scripts/preview/build.sh:105-124`).
- A reachable PostgreSQL holding an empty database, and a role that may create
  tables in it. Neither command provisions one, and the start command refuses
  rather than guess a connection string (`scripts/preview/start.sh:115-117`). See
  [conventions/datastore.md].
- Network access on the first build — dependencies come from the npm registry,
  and the Rust channel `rust-toolchain.toml` pins is installed when the host has
  neither `rustup` nor `cargo` (`scripts/preview/build.sh:177-189`).

Yarn is **not** a prerequisite: both scripts point the name `yarn` at the release
vendored in `.yarn/releases`, for their own process and its children, and remove
the shim afterwards (`scripts/preview/build.sh:139-157`,
`scripts/preview/start.sh:131-150,205-207`). Neither is a Rust toolchain, on the
terms above. A key-value store is optional — with `REDIS_URL` unset the server
looks for one at `localhost:6379` — see [conventions/env.md].

### Build And Start

```sh
# The database this run should use. It is the one value with no default; the
# start command stops before it connects to anything when it is empty
# (scripts/preview/start.sh:115-117).
export DATABASE_URL='postgresql://affine@localhost:5432/affine'

# The port the platform expects. Translated into AFFINE_SERVER_PORT, which is
# the name this server listens on
# (packages/backend/server/scripts/runtime-env.sh:106-123).
export PORT=3010

# Installs the workspace, builds the native addon, the web and admin frontends
# and the server bundle, then stages the frontends where the server serves them
# from (scripts/preview/build.sh:272-303).
sh scripts/preview/build.sh

# Applies the schema and data migrations, seeds the first account, then execs
# the bundle in this process (scripts/preview/start.sh:200-218).
sh scripts/preview/start.sh
```

Both scripts print one line per decision and per step, each prefixed
`[preview]`. The first screen is then at `http://localhost:3010`, served over
plain HTTP by the same process that answers `/api`, `/graphql` and `/socket.io`
— one listener, and no redirect to a second one
(`packages/backend/server/src/server.ts:131`,
`scripts/preview/start.sh:180-184`). What is bootstrapped before the server
accepts a request is [First-Time Setup].

`AFFINE_SERVER_PORT` and `REDIS_SERVER_HOST` — the server's own names — win over
`PORT` and `REDIS_URL` whenever both are set, and the unread one is named in the
log rather than dropped in silence
(`packages/backend/server/scripts/runtime-env.sh:106-107,127-128`).

### Branch Checks Without A Toolchain

```sh
# Runs scripts/preview/build.sh against stub binaries and asserts every branch
# it takes: the Node and Rust reports, the Yarn shim, the six steps in order,
# and the artifact assertions after each. Needs no toolchain and no network.
sh scripts/preview/build.test.sh

# The same for scripts/preview/start.sh: the five refusals, the translation of
# PORT and REDIS_URL, the bootstrap call, and what the exec'd server is handed.
# Needs no database and no build.
sh scripts/preview/start.test.sh
```

Both were run on 2026-09-06 and both print `all branch assertions passed.` They
are what stands behind the two commands above until a host with room for the
real build runs them end to end — see [Assumptions].

### Dev Servers For Contributors

`dev` and `build` under `yarn affine` both take a target. Always pass one
explicitly; neither has a useful default — see [Known Gaps].

```sh
# Installs workspace dependencies. The postinstall hook runs `yarn affine init`,
# which generates tsconfigs, `.oxlintrc.json`, and `workspace.gen.ts`
# (package.json:35, tools/cli/src/init.ts:23-33). `scripts/preview/build.sh`
# runs this itself, with `--immutable`.
yarn install

# The native addon every server entry point loads on its first line. `yarn
# install` does not build it (`.yarnrc.yml:9`), and `yarn affine dev -p server`
# crashes without it — see Known Gaps. This is the build script's second step
# (scripts/preview/build.sh:275-277) run on its own.
yarn workspace @affine/server-native build

# Frontend dev server. Proxies /api, /graphql, and /socket.io to
# http://localhost:3010 (tools/cli/src/bundle-shared.ts:57-71). Serves on 8080.
yarn affine dev -p web

# Backend server. Runs `nodemon ./src/index.ts`; listens on 3010 by default
# (packages/backend/server/src/core/config/config.ts:67-71).
yarn affine dev -p server
```

Run the last two in separate shells — the frontend dev server expects the
backend to already be answering on `3010`. This is the contributor's
watch-and-reload path, not the path a preview takes; a server that has to come
up from a clean checkout uses the two commands under [Build And Start].

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

There is no separate bootstrap step to run. `sh scripts/preview/start.sh` hands
the database to `packages/backend/server/scripts/self-host-predeploy.js` before
the server accepts a request (`scripts/preview/start.sh:200-201`), and the
container image's entrypoint calls the same script on both of its paths
(`packages/backend/server/scripts/self-host-entrypoint.sh:373`). One definition
of what a first start does, reached from either direction.

### What The Bootstrap Does

Four steps, in this order
(`packages/backend/server/scripts/self-host-predeploy.js:170-174`). Each asks
what it finds rather than whether this is the first start, which is what makes a
second start over the same database repeat nothing and fail nothing.

| Step | On An Empty Database | On A Database It Has Run Against Before |
|---|---|---|
| `private.key` (`:67,47-65`) | Generated under `~/.affine/config` | Kept — sessions signed before the restart stay valid |
| Schema migrations (`:103-105`) | All applied — `yarn prisma migrate deploy` | Only the ones not yet applied |
| Data migrations (`:107-109`) | All applied — `yarn cli run` | Only the ones not yet recorded |
| The standard seed (`:122-124`) | Creates one administrator — `yarn cli standard-seed` | Creates nothing, because the database already holds a user |

A known-failed migration is rolled back before the schema migrations run, so a
database left mid-failure by an earlier attempt is not a dead end
(`packages/backend/server/scripts/self-host-predeploy.js:126-133,171`).

### The First Account

The seed leaves one administrator behind, and it is the account to sign in with
(`packages/backend/server/src/data/commands/standard-seed.ts:17-21`).

| Field | Value |
|---|---|
| Name | `Admin` |
| E-mail | `admin@example.com` |
| Password | `change-me` |

The three values are a source constant, so they are the same in every checkout —
a published default rather than a secret. `example.com` is reserved for
documentation by RFC 2606, so the address can collide with no real mailbox.

> **Warning**
> Anyone who can reach the port can sign in as this administrator until the
> password is changed. Change it at `/admin/accounts` before this server is
> reachable by anybody but you.

### Running The Steps By Hand

Run these from `packages/backend/server`, with PostgreSQL reachable at
`DATABASE_URL`, when you want one step rather than the sequence.

```sh
# The whole bootstrap, exactly as both entry points invoke it. Safe on every
# boot (packages/backend/server/scripts/self-host-predeploy.js:170-174).
node ./scripts/self-host-predeploy.js

# Prints usage, examples, and where the entity list lives. `seed` builds
# entities from mock factories using the arguments you pass, with random
# attributes (packages/backend/server/src/seed/index.ts:9-42) — it is for
# fixtures, not for the account above.
yarn run seed

# Creates three Users with random attributes.
yarn run seed User 3
```

`yarn run init` (`packages/backend/server/package.json:18`) is the development
spelling of the same idea and does **not** complete unattended — see
[Known Gaps]. `run` is not optional in either command: `yarn init` alone hits
Yarn's built-in init command, not the package script.

## Ship It As A Container

One Dockerfile, built from the repository root, compiles everything and produces
a runnable image (`.github/deployment/node/Dockerfile:18-521`). Nothing is pulled
from a published tag.

```sh
# Builds the deployable image from source. The context is the repository root,
# not the Dockerfile's directory — the build compiles the workspace, so it needs
# the workspace (.docker/selfhost/compose.yml:19-22).
docker build -f .github/deployment/node/Dockerfile -t affine:selfhost .
```

Seven stages produce it: the manifest set, the workspace install, the compile of
the native addon and the four bundles, the server's production dependency
closure, the assembled application root, the PostgreSQL signing key, and the
runtime (`.github/deployment/node/Dockerfile:18,38,95,238,294,360,407`). The
runtime stage also installs PostgreSQL and Redis into the image (`:407-494`),
which is what makes the single-container shape below possible.

What the image does at boot: the entrypoint decides, per store, whether to use
the one inside the image or the one the operator pointed it at, runs the
bootstrap script, then execs the command
(`packages/backend/server/scripts/self-host-entrypoint.sh:356-388`).

| Deployment | Definition | Stores |
|---|---|---|
| One container | `docker run affine:selfhost` with `DATABASE_URL` and `REDIS_SERVER_HOST` both unset | Both started inside the image (`packages/backend/server/scripts/self-host-entrypoint.sh:356-368`) |
| Compose | `.docker/selfhost/compose.yml:15-68` | Both filled, so the entrypoint uses the `postgres` and `redis` services and leaves the embedded pair alone (`:39-40`) |
| Render | `render.yaml:8-70` | Managed PostgreSQL 16 and key-value service, injected as `DATABASE_URL`, `REDIS_SERVER_HOST` and `REDIS_SERVER_PORT` (`:45-58`); health check on `/info` (`:23`); 10 GB disk at `/root/.affine` (`:24-29`) |

The wiring between the pieces, the ports each opens, and what the build stages
do in detail are in [conventions/networking.md] and [conventions/deploy.md]. The
step-by-step build and run walkthroughs are in
[docs/self-host/building-the-image.md] and
[docs/self-host/running-the-image.md].

## Known Gaps

These are the places where the repository does not do what this contract would
otherwise promise. They are recorded here rather than papered over. Each one is
a defect to close, not a rule to follow.

| Gap | Evidence | What Happens Today |
|---|---|---|
| The root `build` and `dev` scripts do not reach the build that works | `package.json:23-24`, `tools/cli/src/command.ts:40-44,106-133`, `tools/cli/src/affine.ts:29`, `preview.toml:36` | `yarn build` expands to `yarn affine build`, whose `--package,-p` is `required: true`, so it errors out instead of building anything. `yarn dev` expands to `yarn affine dev`, which falls back to an interactive `inquirer` prompt: with stdin held open it never resolves, and at EOF — `< /dev/null`, the usual CI and agent case — node exits 1 reporting `Detected unsettled top-level await`. Neither names `scripts/preview/build.sh`, which is what `preview.toml` declares and what [Run It Locally] uses, so the two conventional spellings still lead nowhere |
| `yarn install` alone leaves the server's native addon unbuilt | `.yarnrc.yml:9`, `packages/backend/native/index.js:4-11`, `packages/backend/native/package.json:32`, `scripts/preview/build.sh:275-277` | `enableScripts: false` means no install hook builds `@affine/server-native`, and after a clean `yarn install` anything that loads the server's prelude exits with `Error: Cannot find module './server-native.x64.node'` — `yarn affine dev -p server`, `yarn run seed` in any form, and `yarn workspace @affine/server genconfig` ([conventions/env.md]) all stop there. `scripts/preview/build.sh` builds it as its second step and the image build compiles it in its own stage, so the artifact has a producer; nothing produces it during install, and no error at that point says so |
| `schema.prisma` and the migration history have diverged | `packages/backend/server/package.json:18`, `packages/backend/server/schema.prisma:5,11` | `yarn run init` runs `prisma migrate dev`, which against an empty database at a reachable `DATABASE_URL` applies all 119 migrations and then asks `Enter a name for the new migration:` — `prisma migrate diff` between the schema and the history emits `CREATE EXTENSION IF NOT EXISTS "vector"` plus foreign-key and index changes. `prisma migrate status` still reports the database up to date. With no terminal the command blocks at the prompt and never reaches `yarn data-migration run`. The bootstrap this page uses runs `prisma migrate deploy` instead (`packages/backend/server/scripts/self-host-predeploy.js:103-105`), which reads the history and never prompts, so the divergence is routed around rather than resolved |
| The preview configuration's schema is not evidenced in this repository | `preview.toml:1-27`, `preview.toml:29-45` | The file declares the preview model, the build command, the serve command and the port variable, every value read off this repository — the two commands name scripts in it, and the other two carry the `file:line` they were read from. The schema those key *names* satisfy is the preview platform's, and it is not a file here, so nothing in this repository can be cited for them — see [Assumptions]. None of the five guides describes one either. A reader who needs to know which other keys are accepted has nothing here to read, and that stays so until the schema is confirmed |

These gaps are scheduled to be closed by later work. When one closes, the
section above it must be rewritten to describe what the command then does —
this page describes the repository as it is, not as it is planned to be. Which
sections that rewrite touches, and what sets it off, is in [Realignment].

## Realignment

This is the second edition of this contract. The first was written on
2026-09-05 and recorded a repository where no single command built the tree, no
bootstrap completed unattended, and the deployment wrapped a published image. Its
three triggers are all discharged here, but not in the same way.

Two landed as work: `scripts/preview/build.sh` and `scripts/preview/start.sh`
are the one-command build and the unattended bootstrap, so [Run It Locally] and
[First-Time Setup] are rewritten around them and the gap rows that explained why
neither existed are closed. The third did not land — it was never true. There is
no `.render/Dockerfile` and no `.render/start.sh` in this repository, and
`render.yaml:12-15` points at `.github/deployment/node/Dockerfile`, which
compiles the whole workspace. [Ship It As A Container] and the two gap rows that
described a published-image wrapper were citing files that do not exist, so they
are replaced rather than updated.

The rule that produced this edition still stands. When a trigger below lands,
the three things in its row are re-read against the new behaviour and rewritten
together, in the same change: the section that carries the command, the
[Known Gaps] rows that explain why the command does not work today, and the
guide the section delegates to. A command corrected in one place and left stale
in the other two is how this page starts lying — which is exactly what happened
to the container path between the first edition and this one.

| Trigger | Sections And Gap Rows On This Page | Guides To Re-Read |
|---|---|---|
| A root `build` or `dev` that reaches the build that works | [Run It Locally] — and the gap row for the root scripts not reaching it | [conventions/stack.md] |
| An install that leaves the native addon built, or an error at install time that says it did not | [Run It Locally] — and the gap row for `yarn install` leaving the addon unbuilt | [conventions/stack.md], [conventions/deploy.md] |
| `schema.prisma` reconciled with the migration history | [First-Time Setup] — and the gap row for the divergence | [conventions/datastore.md], [conventions/env.md] |
| The preview platform's schema confirmed | [Topic Guides]'s status note and the [Assumptions] bullet on the four keys — and the gap row for the unevidenced schema | [preview.toml] |

[Assumptions] is not in the table: it is settled item by item as evidence
arrives rather than on a trigger. Until a trigger lands, its row's section keeps
the commands this repository declares today, and its gap rows stay as they are.
Nothing on this page is written ahead of the behaviour it describes.

## Assumptions

Unresolved. Recorded so the next reader does not mistake them for settled facts.

- The two commands under [Build And Start] have not been run end to end. Their
  branch behaviour is covered by `scripts/preview/build.test.sh` and
  `scripts/preview/start.test.sh`, which run them against stub toolchains and
  need neither a network nor a database; both were run on 2026-09-06 and both
  passed. The real sequence was not attempted here because the volume this page
  was verified on was full — the same condition that stopped the addon build a
  day earlier — so that the real toolchain produces a server which answers its
  first screen is **(assumption — needs confirming)**.
- The frontend dev server port is not set explicitly in the CLI config; the
  client websocket URL is `ws://0.0.0.0:8080/ws`
  (`tools/cli/src/bundle-shared.ts:43`), which implies `8080`, the
  `rspack-dev-server` default. Running `yarn affine dev -p web` on 2026-09-05
  bound `0.0.0.0:8080` and printed `Local: http://localhost:8080/`, so `8080` is
  what the command did then. That it stays `8080` rests on the bundled
  `rspack-dev-server` default rather than on anything this repository sets, so a
  dependency bump can move it without a change here
  **(assumption — needs confirming)**.
- The container path on this page has been read, not run. `docker build`, and
  the `docker compose` and `docker run` commands the guides carry, were checked
  out against `.github/deployment/node/Dockerfile:18-521`,
  `packages/backend/server/scripts/self-host-entrypoint.sh:356-388`,
  `.docker/selfhost/compose.yml:15-68` and `render.yaml:8-70` only — no Docker
  daemon was available where this page was verified, so what the built image does
  at boot is read off those files rather than observed
  **(assumption — needs confirming)**. The entrypoint's own branch behaviour is
  covered by `packages/backend/server/scripts/self-host-entrypoint.test.sh`,
  which needs no Docker.
- The commands under [Dev Servers For Contributors] were run on 2026-09-05 and
  are carried forward unchanged; the host this edition was written on could not
  complete `yarn install`, so they were not re-run. That they still behave as
  recorded is **(assumption — needs confirming)**, and the same holds for the
  246 accepted `-p` literals, which move with the package tree.
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

[conventions/stack.md]: ./conventions/stack.md
[conventions/datastore.md]: ./conventions/datastore.md
[conventions/env.md]: ./conventions/env.md
[conventions/networking.md]: ./conventions/networking.md
[conventions/deploy.md]: ./conventions/deploy.md
[docs/self-host/building-the-image.md]: ./docs/self-host/building-the-image.md
[docs/self-host/running-the-image.md]: ./docs/self-host/running-the-image.md
[preview.toml]: ./preview.toml
[Topic Guides]: #topic-guides
[Run It Locally]: #run-it-locally
[Build And Start]: #build-and-start
[Dev Servers For Contributors]: #dev-servers-for-contributors
[First-Time Setup]: #first-time-setup
[Ship It As A Container]: #ship-it-as-a-container
[Known Gaps]: #known-gaps
[Realignment]: #realignment
[Assumptions]: #assumptions
