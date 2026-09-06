# Environment

Where a configuration value comes from, in what order the sources are applied,
and what each variable the server reads defaults to when it is absent. Every
claim below is followed by the `file:line` it was read from. Where the
repository does not back a claim, it is marked
`(assumption — needs confirming)` rather than filled in.

## Scope Statement

This guide answers three questions:

- Which sources supply a value, and which one wins when two disagree.
- What each variable is named, which config key it fills, and what it defaults
  to.
- How the server private key is produced, stored, and loaded.

It does not answer: what a connection string must point at
([conventions/datastore.md]), which port a value opens
([conventions/networking.md]), or which of these the deployable image sets for
you ([conventions/deploy.md]). The commands that run migrations and read these
values are in the contract, not here — see [AGENTS.md].

Variables are not required to be exported by hand. Every one below has a default
in its descriptor, so the server boots with none of them set — it just boots
pointing at `localhost`.

## Resolution Order

Six steps run before the first config read, in this order.

| #   | Step                                                                                                                                                       | Evidence                                                                                |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| 1   | `dotenv` loads `.env` from the working directory                                                                                                           | `packages/backend/server/src/prelude.ts:21`                                             |
| 2   | `dotenv` loads `.env` from `~/.affine/config`                                                                                                              | `packages/backend/server/src/prelude.ts:23-25`, `packages/backend/server/src/env.ts:68` |
| 3   | `AFFINE_PRIVATE_KEY` is **deleted** unless it was already in `process.env` before step 1 — "The old AFFINE_PRIVATE_KEY in old .env is somehow not working" | `packages/backend/server/src/prelude.ts:19,27-31`                                       |
| 4   | `~/.affine/config/private.key` is read into `AFFINE_PRIVATE_KEY` when that variable is unset and the file exists                                           | `packages/backend/server/src/prelude.ts:10-16`                                          |
| 5   | Each descriptor takes its declared default, then overwrites it with the parsed environment value when the variable is set and non-empty                    | `packages/backend/server/src/base/config/register.ts:357-364`                           |
| 6   | `config.json` from the project root and from `~/.affine/config` is merged over the result                                                                  | `packages/backend/server/src/base/config/register.ts:284-287,388-391`                   |

Step 6 runs after step 5, so **`config.json` beats the environment** — see
[Known Gaps]. The project-root one is gitignored at the server package
(`packages/backend/server/.gitignore:1`); the one under `~/.affine/config` sits
outside the repository, so no ignore rule reaches it. A schema-annotated
skeleton is at `packages/backend/server/config.example.json:1-3`.

A descriptor declares its variable either as a bare name, which is normalised to
type `string`, or as a `[name, type]` pair
(`packages/backend/server/src/base/config/register.ts:155-159`). Four parsers
exist — `string`, `integer`, `float`, and `boolean`, where boolean is true only
for `1` or a case-insensitive `true`
(`packages/backend/server/src/base/config/env.ts:6-25`).

## Core Variables

| Variable                     | Config Key           | Type                       | Default                                           | Defined At                                                 |
| ---------------------------- | -------------------- | -------------------------- | ------------------------------------------------- | ---------------------------------------------------------- |
| `DATABASE_URL`               | `db.datasourceUrl`   | string, validated as a URL | `postgresql://localhost:5432/affine`              | `packages/backend/server/src/base/prisma/config.ts:16-21`  |
| `REDIS_SERVER_HOST`          | `redis.host`         | string                     | `localhost`                                       | `packages/backend/server/src/base/redis/config.ts:28-32`   |
| `REDIS_SERVER_PORT`          | `redis.port`         | integer, positive          | `6379`                                            | `packages/backend/server/src/base/redis/config.ts:33-38`   |
| `REDIS_SERVER_DATABASE`      | `redis.db`           | integer, `0`–`10`          | `0`                                               | `packages/backend/server/src/base/redis/config.ts:22-27`   |
| `REDIS_SERVER_USERNAME`      | `redis.username`     | string                     | `''`                                              | `packages/backend/server/src/base/redis/config.ts:39-43`   |
| `REDIS_SERVER_PASSWORD`      | `redis.password`     | string                     | `''`                                              | `packages/backend/server/src/base/redis/config.ts:44-48`   |
| `AFFINE_SERVER_HOST`         | `server.host`        | string                     | `localhost`                                       | `packages/backend/server/src/core/config/config.ts:52-56`  |
| `AFFINE_SERVER_PORT`         | `server.port`        | integer                    | `3010`                                            | `packages/backend/server/src/core/config/config.ts:67-71`  |
| `AFFINE_SERVER_HTTPS`        | `server.https`       | boolean                    | `false`                                           | `packages/backend/server/src/core/config/config.ts:46-51`  |
| `AFFINE_SERVER_EXTERNAL_URL` | `server.externalUrl` | string, URL or empty       | `''` — falls back to `[protocol]://[host][:port]` | `packages/backend/server/src/core/config/config.ts:31-45`  |
| `AFFINE_SERVER_SUB_PATH`     | `server.path`        | string                     | `''`                                              | `packages/backend/server/src/core/config/config.ts:72-76`  |
| `LISTEN_ADDR`                | `server.listenAddr`  | string                     | `0.0.0.0`                                         | `packages/backend/server/src/core/config/config.ts:62-66`  |
| `AFFINE_PRIVATE_KEY`         | `crypto.privateKey`  | string                     | `''`                                              | `packages/backend/server/src/base/helpers/config.ts:11-17` |

Thirteen of the twenty-two descriptors that declare a variable are above. The
other nine belong to optional features — seven `MAILER_*`
(`packages/backend/server/src/core/mail/config.ts:37-73`) and two `GA4_*`
(`packages/backend/server/src/core/telemetry/config.ts:29-38`). They are not
reproduced here; the command below regenerates the full list.

## Runtime Mode Variables

These are read by the `Env` class rather than by a config descriptor, so they
take no `config.json` override and no dotenv-independent default.

| Variable              | Default                                               | Accepted Values                                                            | Defined At                                        |
| --------------------- | ----------------------------------------------------- | -------------------------------------------------------------------------- | ------------------------------------------------- |
| `NODE_ENV`            | `production`                                          | `development`, `test`, `production` — anything else throws at construction | `packages/backend/server/src/env.ts:91,184-190`   |
| `AFFINE_ENV`          | `production`                                          | `dev`, `beta`, `production`                                                | `packages/backend/server/src/env.ts:38-42,92-96`  |
| `DEPLOYMENT_TYPE`     | `selfhosted`, or `affine` when `NODE_ENV=development` | `affine`, `selfhosted`                                                     | `packages/backend/server/src/env.ts:50-53,97-101` |
| `SERVER_FLAVOR`       | `allinone`                                            | `allinone`, `graphql`, `sync`, `renderer`, `front`, `worker`, `script`     | `packages/backend/server/src/env.ts:21-29,102`    |
| `DEPLOYMENT_PLATFORM` | `unknown`                                             | Unconstrained — no value list is passed                                    | `packages/backend/server/src/env.ts:55-58,103`    |

An out-of-list value throws with the accepted set in the message
(`packages/backend/server/src/env.ts:79-86`). `SERVER_FLAVOR=script` is what the
server package's `cli` script sets to run one-shot commands
(`packages/backend/server/package.json:21`).

## The Private Key

`AFFINE_PRIVATE_KEY` is the one variable with a generator behind it. Four things
can produce its value, in the order the resolution steps reach them.

| Source                                                                                                          | Format                                   | Persisted                                   | Evidence                                                              |
| --------------------------------------------------------------------------------------------------------------- | ---------------------------------------- | ------------------------------------------- | --------------------------------------------------------------------- |
| A real process environment variable                                                                             | Whatever is supplied                     | Caller's problem                            | `packages/backend/server/src/prelude.ts:19`                           |
| `~/.affine/config/private.key`, written by the self-host predeploy script on first boot when the file is absent | EC `prime256v1`, exported as `sec1` PEM  | Yes — the file is only written when missing | `packages/backend/server/scripts/self-host-predeploy.js:7,9-22,27-39` |
| `config.json` under `crypto.privateKey`                                                                         | Free-form string                         | Yes                                         | `packages/backend/server/src/base/config/register.ts:284-287`         |
| `CryptoHelper` falling back to an in-process generator when the config value is empty                           | EC `prime256v1`, exported as `pkcs8` PEM | **No**                                      | `packages/backend/server/src/base/helpers/crypto.ts:34-45,107`        |

The loader accepts either export format — it tries `pkcs8`, then `sec1`, then
auto-detection (`packages/backend/server/src/base/helpers/crypto.ts:49-63`),
which is why the script's `sec1` output and the in-process `pkcs8` output are
both readable.

Because the file lives under `~/.affine/config`, keeping it means keeping that
directory: `render.yaml:16-21` mounts a disk at `/root/.affine`, and
`.docker/selfhost/compose.yml:17,28` binds `./config` into both the app and the
migration container.

## What Deployment Sets

| Where                             | Variables                                                                                                                                                                                             | Evidence                                                               |
| --------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| `render.yaml`                     | `AFFINE_SERVER_PORT=10000`, `AFFINE_SERVER_HTTPS=true`, `DATABASE_URL` from the managed database's `connectionString`, `REDIS_SERVER_HOST` and `REDIS_SERVER_PORT` from the managed key-value service | `render.yaml:22-40`                                                    |
| `.render/start.sh`                | `AFFINE_SERVER_HOST`, defaulted to `RENDER_EXTERNAL_HOSTNAME` and then to `localhost`, and only when it is not already set                                                                            | `.render/start.sh:6`                                                   |
| `.docker/selfhost/compose.yml`    | `REDIS_SERVER_HOST=redis` and `DATABASE_URL=postgresql://affine@postgres:5432/affine`, on both the app and the migration container                                                                    | `.docker/selfhost/compose.yml:18-20,30-32`                             |
| `.docker/dev/compose.yml.example` | `DB_VERSION`, `DB_PASSWORD`, `DB_USERNAME`, `DB_DATABASE_NAME` — consumed by the PostgreSQL container, not by the server                                                                              | `.docker/dev/compose.yml.example:4-12`, `.docker/dev/.env.example:1-6` |

`RENDER_EXTERNAL_HOSTNAME` is supplied by the hosting platform, not by this
repository — see [Assumptions].

## Commands

```sh
# List every config descriptor that reads an environment variable, with the file
# and line that declares it. This is the generator of the tables above; 22 lines
# today.
grep -rn "env: " packages/backend/server/src --include=config.ts

# Regenerate the JSON schema that config.json is validated against. It skips the
# db, redis, and graphql modules (packages/backend/server/scripts/genconfig.ts:13),
# so it is a view of the optional settings, not of the variables above.
yarn workspace @affine/server genconfig

# Show which of the variables above are set in the current shell, before dotenv
# adds anything. An empty result means the server will boot on its defaults.
env | grep -E '^(DATABASE_URL|REDIS_SERVER_|AFFINE_SERVER_|AFFINE_PRIVATE_KEY|LISTEN_ADDR)'
```

## Known Gaps

| Gap                                                                  | Evidence                                                                         | What Happens Today                                                                                                                                                                                                                                                                                                                                                                                                     |
| -------------------------------------------------------------------- | -------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `config.json` silently outranks the environment                      | `packages/backend/server/src/base/config/register.ts:357-364,388-391`            | Environment values are applied as descriptor defaults, then the two `config.json` paths are merged over them. A stale `~/.affine/config/config.json` overrides a variable the hosting platform injected, with nothing logged about the override                                                                                                                                                                        |
| The example env file sets nothing                                    | `packages/backend/server/.env.example:1-13`                                      | The file is thirteen lines; twelve are comments and one is blank, so nothing is set. Copying the file to `.env` — the path `dotenv` reads at `packages/backend/server/src/prelude.ts:21` — produces an empty environment rather than a working local default                                                                                                                                                           |
| Four names in the example env file are read by nothing               | `packages/backend/server/.env.example:3-5,13`                                    | `COPILOT_FAL_API_KEY`, `COPILOT_OPENAI_API_KEY`, `COPILOT_PERPLEXITY_API_KEY`, and `MAILER_SECURE` match no descriptor. A `grep` for each over `packages/backend/server/src` returns nothing. The mailer's actual TLS switch is `MAILER_IGNORE_TLS` (`packages/backend/server/src/core/mail/config.ts:68-72`)                                                                                                          |
| `AFFINE_PRIVATE_KEY` in a `.env` file is discarded on purpose        | `packages/backend/server/src/prelude.ts:19,27-31`                                | The loader records whether the variable was set before `dotenv` ran and deletes it afterwards if it was not. Putting the key in `.env` therefore has no effect; the supported file path is `~/.affine/config/private.key`                                                                                                                                                                                              |
| The command that regenerates the schema does not run from a checkout | `packages/backend/server/package.json:20`, `packages/backend/native/index.js:11` | `yarn workspace @affine/server genconfig` loads the server prelude, which loads `@affine/server-native`. After a clean `yarn install` that binary does not exist, so the command exits with `Error: Cannot find module './server-native.x64.node'` before writing anything. The generated schema in the repository can be read but not reproduced — the missing build step is the contract's own gap row ([AGENTS.md]) |
| A missing private key is not an error                                | `packages/backend/server/src/base/helpers/crypto.ts:107`                         | With `crypto.privateKey` empty, `CryptoHelper` generates a key in memory at config init and the server starts normally. Nothing is written to disk, so the next restart generates a different key and anything signed by the previous one stops verifying                                                                                                                                                              |

## Assumptions

- Step 2 of the resolution order assumes `dotenv`'s `config()` does not overwrite
  a variable already present in `process.env`, which is why the working-directory
  `.env` wins over the one under `~/.affine/config`. That behaviour belongs to
  the library, not to this repository, and no test here pins it
  **(assumption — needs confirming)**.
- `RENDER_EXTERNAL_HOSTNAME` (`.render/start.sh:6`) is consumed but never
  produced by anything in the repository. That the hosting platform injects it,
  and what it contains, is **(assumption — needs confirming)**.
- The count of twenty-two variable-backed descriptors comes from the `grep` in
  the Commands block, which matches the descriptor's formatting rather than
  parsing the source. A descriptor written on one line, or in a file not named
  `config.ts`, would be missed **(assumption — needs confirming)**.

[AGENTS.md]: ../AGENTS.md
[conventions/datastore.md]: ./datastore.md
[conventions/networking.md]: ./networking.md
[conventions/deploy.md]: ./deploy.md
[Known Gaps]: #known-gaps
[Assumptions]: #assumptions
