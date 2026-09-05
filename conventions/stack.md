# Stack

Monorepo layout, the `affine` command set from `tools/cli`, and how a package
alias resolves to a package. Every claim below is followed by the `file:line` it
was read from. Where the repository does not back a claim, it is marked
`(assumption — needs confirming)` rather than filled in.

## Scope Statement

This guide answers three questions:

- Which directories are workspace packages, and what installs them.
- What each `affine` subcommand is, what it accepts, and what it runs.
- How a name typed after `-p` becomes a package name.

It does not answer: which datastores the server needs
([conventions/datastore.md]), which environment variables a target reads
([conventions/env.md]), which ports a target opens
([conventions/networking.md]), or how the deployable image is produced
([conventions/deploy.md]). The commands you run to start a target and to
bootstrap the database are in the contract, not here — see [AGENTS.md].

## Workspace Layout

The root `package.json` is a private Yarn workspace root (`package.json:4,7`).
Eight glob patterns define the member set (`package.json:7-16`).

| Pattern | Evidence | What It Picks Up |
|---|---|---|
| `.` | `package.json:8` | The root package itself is a workspace member |
| `blocksuite/**/*` | `package.json:9` | The vendored BlockSuite tree — 74 of the 122 members |
| `packages/*/*` | `package.json:10` | `packages/backend/*`, `packages/common/*`, `packages/frontend/*` |
| `packages/frontend/apps/*` | `package.json:11` | The app targets — `web`, `mobile`, `ios`, `android`, `electron`, `electron-renderer`, `mobile-shared` |
| `tools/*` | `package.json:12` | `tools/cli`, `tools/utils`, and nine more |
| `docs/reference` | `package.json:13` | `@affine/docs` |
| `tools/@types/*` | `package.json:14` | Ambient type packages |
| `tests/*` | `package.json:15` | `tests/affine-local`, `tests/kit`, and six more |

`packages/frontend/apps/*` is listed separately because `packages/*/*` stops one
level short of it — it matches `packages/frontend/apps` as a directory, not the
targets inside.

The member list is not discovered at runtime on every invocation. It is
generated into `tools/utils/src/workspace.gen.ts`, a committed file marked
`DO NOT MODIFY THIS FILE MANUALLY` (`tools/utils/src/workspace.gen.ts:1-2`). It
holds 122 entries in `PackageList` (`tools/utils/src/workspace.gen.ts:3-1457`)
and the same 122 names as the `PackageName` union
(`tools/utils/src/workspace.gen.ts:1459-1581`). `affine init` regenerates both
from `yarn workspaces list` output (`tools/cli/src/init.ts:83-97`,
`tools/utils/src/yarn.ts:22-23`), and `postinstall` runs `affine init`
(`package.json:35`), so a clean install rewrites it.

## Package Manager

| Setting | Value | Evidence |
|---|---|---|
| Package manager | `yarn@4.18.0` | `package.json:131` |
| Yarn binary | `.yarn/releases/yarn-4.18.0.cjs` | `.yarnrc.yml:21` |
| Node linker | `node-modules` | `.yarnrc.yml:13` |
| `node_modules` mode | `hardlinks-local` | `.yarnrc.yml:11` |
| Lifecycle scripts | disabled — `enableScripts: false` | `.yarnrc.yml:9` |
| Node engine | `>=22.12.0 <23.0.0` | `package.json:17-19` |

`enableScripts: false` means dependency install scripts do not run. Any native
artifact a package would normally produce during install is therefore not
produced by `yarn install` — see [Known Gaps].

## The `affine` Command

`affine` is a [clipanion] CLI built in `tools/cli`. Two spellings reach it:

| Spelling | Evidence | Resolution |
|---|---|---|
| `yarn affine` / `yarn af` | `package.json:21-22` | Both expand to `r affine.ts` |
| `affine` binary | `tools/cli/package.json:6-9` | `bin/cli.js` re-spawns `yarn r affine.ts` (`tools/cli/bin/cli.js:4-6`) |

`r` is the second binary of `@affine-tools/cli` (`tools/cli/package.json:8`). It
resolves a bare `affine.ts` by searching the current directory, then
`tools/cli/src`, then the project root, trying the name plus `.js` and `.ts`
(`tools/cli/bin/runner.js:21-46`) — which is how `r affine.ts` run from the root
finds `tools/cli/src/affine.ts`. It then loads a TypeScript runtime register
before spawning the file (`tools/cli/bin/runner.js:59-72`).

Seven commands are registered, in this order
(`tools/cli/src/affine.ts:21-27`).

| Command | Paths | Package Option | What It Does |
|---|---|---|---|
| `run` | `[]`, `run`, `r` (`tools/cli/src/run.ts:36`) | Positional, required (`tools/cli/src/run.ts:71-77`) | Runs a named script from the package's `package.json`; falls back to running the arguments as a command inside the package when no such script exists (`tools/cli/src/run.ts:94-102`) |
| `init` | `init`, `i`, `codegen` (`tools/cli/src/init.ts:15`) | None | Regenerates root `tsconfig.json`, `tools/utils/src/workspace.gen.ts`, `.oxlintrc.json`, and one `tsconfig.json` per TypeScript package (`tools/cli/src/init.ts:25-43`) |
| `clean` | `clean` (`tools/cli/src/clean.ts:8`) | None | Removes build output. `--dist`, `--rust`, `--node-modules`, `--all,-a` (`tools/cli/src/clean.ts:10-13`); `--rust` shells out to `cargo clean` (`tools/cli/src/clean.ts:69`) |
| `build` | `build`, `b` (`tools/cli/src/build.ts:4`) | `-p` required (`tools/cli/src/command.ts:40-44`) | Proxies to the target's `build` script (`tools/cli/src/build.ts:13-15`) |
| `dev` | `dev`, `d` (`tools/cli/src/dev.ts:6`) | `-p` optional (`tools/cli/src/command.ts:106-109`) | Proxies to the target's `dev` script (`tools/cli/src/dev.ts:31-33`) |
| `bundle` | `bundle`, `pack`, `bun` (`tools/cli/src/bundle.ts:203`) | `-p` required (`tools/cli/src/command.ts:40-44`) | Bundles the target with rspack. `--dev,-d` runs the dev server instead of a production build (`tools/cli/src/bundle.ts:209-211`) |
| `cert` | `cert` (`tools/cli/src/cert.ts:16`) | None | Manages the local development CA. `--install`, `--uninstall`, `--domain` (`tools/cli/src/cert.ts:18-29`), writing under `.docker/dev/certs` (`tools/cli/src/cert.ts:5-10`) |

`run` claims the empty path (`tools/cli/src/run.ts:36`), so it is the default —
`affine web build` and `affine run web build` are the same invocation.

`--deps` runs the same command across the target's workspace dependencies first
(`tools/cli/src/command.ts:57-60`); `build` additionally forces `--wait-deps`
when it is set (`tools/cli/src/build.ts:9-11`). `bundle` hard-disables both
(`tools/cli/src/bundle.ts:205-207`).

Three commands take no package: `init`, `clean`, and `cert` extend the bare
`Command` class (`tools/cli/src/init.ts:14`, `tools/cli/src/clean.ts:7`,
`tools/cli/src/cert.ts:15`), which carries no `--package` option
(`tools/cli/src/command.ts:11-30`).

## Package Aliases

`-p` accepts either a full package name or an alias. Resolution is a single map
lookup with the raw input as the fallback (`tools/cli/src/command.ts:47-49`), so
a full name passes through untouched.

`AliasToPackage` is built in two layers (`tools/utils/src/distribution.ts:16-30`).

| Layer | Evidence | Rule |
|---|---|---|
| Hand-written | `tools/utils/src/distribution.ts:17-26` | Ten entries, including the ones that are not derivable — `desktop` and `renderer` both map to `@affine/electron-renderer`, `gql` maps to `@affine/graphql` |
| Derived | `tools/utils/src/distribution.ts:27-29` | One alias per workspace package: the last `/`-separated segment of its name |

The derived layer is spread **after** the hand-written entries, so on a key
collision the derived entry wins.

The four aliases the contract names:

| Alias | Resolves To | Evidence |
|---|---|---|
| `web` | `@affine/web` | `tools/utils/src/distribution.ts:18` |
| `server` | `@affine/server` | `tools/utils/src/distribution.ts:25` |
| `mobile` | `@affine/mobile` | `tools/utils/src/distribution.ts:22` |
| `admin` | `@affine/admin` | `tools/utils/src/distribution.ts:17` |

The full set is derived at runtime and is not reproduced here — 122 package
names plus 124 alias keys. Print it with the command below instead of copying a
list that goes stale on the next package added.

`PackageToDistribution` (`tools/utils/src/distribution.ts:3-14`) is a different
map with overlapping keys — it labels seven packages with a build distribution
(`admin`, `web`, `desktop`, `mobile`, `ios`, `android`). It is not consulted by
`-p` resolution.

## Commands

```sh
# Print the 122 workspace members with their locations. This is the same call
# `affine init` uses to regenerate workspace.gen.ts
# (tools/utils/src/yarn.ts:22-23).
yarn workspaces list -v --json

# Regenerate tsconfigs, .oxlintrc.json, and workspace.gen.ts after adding or
# removing a package (tools/cli/src/init.ts:23-43). `postinstall` already runs
# this (package.json:35) — run it by hand only when the tree changed since.
yarn affine init

# Print every accepted -p literal. The validator is built from the 122 package
# names plus the 124 AliasToPackage keys (tools/cli/src/command.ts:33-38), and
# rejecting an unknown target makes clipanion enumerate all 246. Exits 1.
yarn affine build -p nosuchpkg
```

## Known Gaps

| Gap | Evidence | What Happens Today |
|---|---|---|
| Root `build` fails with no arguments | `package.json:24`, `tools/cli/src/build.ts:3`, `tools/cli/src/command.ts:40-44` | `yarn build` expands to `yarn affine build`. `BuildCommand` extends `PackageCommand`, whose `--package,-p` is `required: true`, so the command errors before reaching `execute()`. There is no default target and no aggregate build across the 122 members |
| Root `dev` hangs when not attached to a terminal | `package.json:23`, `tools/cli/src/dev.ts:5`, `tools/cli/src/command.ts:106-133` | `yarn dev` expands to `yarn affine dev`. `DevCommand` extends `PackageSelectorCommand`, whose `-p` is optional; when it is absent `getPackage()` awaits an `inquirer` list prompt over the eight targets at `tools/cli/src/dev.ts:8-17`. With no TTY there is nobody to answer, so it blocks rather than failing |
| One alias is ambiguous and silently resolves to one package | `tools/utils/src/distribution.ts:27-29`, `tools/utils/src/workspace.gen.ts:1053,1100` | `@blocksuite/docs` and `@affine/docs` both derive the alias `docs`. `@affine/docs` appears later in `PackageList`, so its entry overwrites the other. `-p docs` reaches `@affine/docs`, and `@blocksuite/docs` has no alias — reachable only by its full name. Nothing warns about the collision |
| `-h` does not list the accepted targets | `tools/cli/src/command.ts:40-44,57-68` | `--package,-p` carries only its own one-line description. The 246 accepted literals live in the validator, which is exercised on rejection, not on help. The Commands block above uses a deliberate rejection to get the list |

## Assumptions

- The counts on this page — 122 workspace members, 124 alias keys, 246 accepted
  literals — were read from the committed `tools/utils/src/workspace.gen.ts`.
  That file is regenerated by `affine init` (`tools/cli/src/init.ts:83-97`), so
  the numbers move with the package tree. Whether the committed copy is current
  against the working tree at any given moment is
  **(assumption — needs confirming)**.
- `blocksuite/**/*` matches 74 members and `tools/*` matches 11, counted from
  the `location` fields in `tools/utils/src/workspace.gen.ts`. Attributing each
  member to the pattern that claimed it is an inference from the path prefix,
  not something the repository records
  **(assumption — needs confirming)**.

[AGENTS.md]: ../AGENTS.md
[conventions/datastore.md]: ./datastore.md
[conventions/env.md]: ./env.md
[conventions/networking.md]: ./networking.md
[conventions/deploy.md]: ./deploy.md
[clipanion]: https://github.com/arcanis/clipanion
[Known Gaps]: #known-gaps
