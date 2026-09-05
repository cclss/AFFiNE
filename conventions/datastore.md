# Datastores

The stores the server opens a connection to, what each one must provide, and how
the three provisioning paths in this repository stand them up. Every claim below
is followed by the `file:line` it was read from. Where the repository does not
back a claim, it is marked `(assumption — needs confirming)` rather than filled
in.

## Scope Statement

This guide answers three questions:

- Which stores the server requires, and what in the code requires them.
- What PostgreSQL must provide beyond being reachable — extensions, version.
- How the key-value store is partitioned across the four clients that open it.

It does not answer: which variable carries a connection string and what it
defaults to ([conventions/env.md]), which port each store listens on and who may
reach it ([conventions/networking.md]), or how the deployable image is produced
([conventions/deploy.md]). The migration commands that populate a fresh database
are in the contract, not here — see [AGENTS.md].

The dev compose file also starts a mail catcher (`mailpit`,
`.docker/dev/compose.yml.example:22-33`). It is not a datastore and is not
covered here.

## Required Stores

| Store | Required By | Evidence |
|---|---|---|
| PostgreSQL | The Prisma datasource. `PrismaModule` sits in the unconditional module list, not behind a flavor check | `packages/backend/server/schema.prisma:8-12`, `packages/backend/server/src/app.module.ts:112` |
| Key-value store | Four `ioredis` clients constructed at module init. `RedisModule` is likewise unconditional | `packages/backend/server/src/base/redis/instances.ts:54-100`, `packages/backend/server/src/app.module.ts:115` |
| Local filesystem | Default storage provider for uploaded blobs and avatars is `fs`, bucket `blobs` / `avatars`, rooted at `~/.affine/storage` | `packages/backend/server/src/core/storage/config.ts:28-47` |

The filesystem store is why every deployment path in the repository mounts
persistent storage at `~/.affine` — `render.yaml:16-21` attaches a 10 GB disk at
`/root/.affine`, and `.docker/selfhost/compose.yml:15-17` binds
`./data/storage` and `./config` into the same tree.

## PostgreSQL

| Requirement | Value | Evidence |
|---|---|---|
| Provider | `postgresql` | `packages/backend/server/schema.prisma:9` |
| Connection string | Read from the `DATABASE_URL` environment variable by Prisma itself | `packages/backend/server/schema.prisma:10` |
| Declared extension | `pgvector`, mapped to the extension name `vector`, enabled through the `postgresqlExtensions` preview feature | `packages/backend/server/schema.prisma:5,11` |
| Major version, deployment | `16` | `render.yaml:51` |
| Image, self-host | `pgvector/pgvector:pg16` | `.docker/selfhost/compose.yml:50` |
| Image, local dev | `pgvector/pgvector:pg${DB_VERSION:-16}` — `DB_VERSION=16` in the example env file | `.docker/dev/compose.yml.example:6`, `.docker/dev/.env.example:1-2` |

Two extensions are created by migrations rather than assumed present, and
**neither aborts the migration when it cannot be created**:

| Extension | Migration | Behaviour When Missing |
|---|---|---|
| `vector` | `packages/backend/server/migrations/20250210090228_ai_context_embedding/migration.sql:3-30` | `RAISE WARNING` with instructions to switch to a `pgvector/pgvector` image; the migration continues |
| `pgcrypto` | `packages/backend/server/migrations/20260109090137_tokens_and_otp/migration.sql:4-13` | `RAISE WARNING`; access tokens are left unhashed and are "lazily migrated on use" |

A plain `postgres:16` image therefore passes migration with warnings, not with an
error. That is the reason all three provisioning paths name a `pgvector` image.

## Key-Value Store

Four clients are constructed from the same host/port/credentials, each on its own
database index derived from `redis.db`.

| Client | Database Index | Evidence |
|---|---|---|
| `CacheRedis` | `redis.db` | `packages/backend/server/src/base/redis/instances.ts:54-59` |
| `SessionRedis` | `redis.db + 2` | `packages/backend/server/src/base/redis/instances.ts:61-72` |
| `SocketIoRedis` | `redis.db + 3` | `packages/backend/server/src/base/redis/instances.ts:74-85` |
| `QueueRedis` | `redis.db + 4`, with `maxRetriesPerRequest: null` — "required explicitly set to `null` by bullmq" | `packages/backend/server/src/base/redis/instances.ts:87-100` |

`redis.db` defaults to `0` and is validated as a non-negative integer with a
maximum of `10`, described as "Must be less than 10"
(`packages/backend/server/src/base/redis/config.ts:22-27`). Index `1` is not
claimed by any of the four clients.

The store holds more than a cache: sessions, the socket.io adapter, and the
bullmq queue all live in it. The deployment configuration sets
`maxmemoryPolicy: noeviction` (`render.yaml:45`) — the repository states the
setting but not its reason, see [Assumptions].

## Provisioning

| Path | PostgreSQL | Key-Value Store | Evidence |
|---|---|---|---|
| Local dev | `pgvector/pgvector:pg${DB_VERSION:-16}`, credentials from `DB_USERNAME` / `DB_PASSWORD` / `DB_DATABASE_NAME`, data in the `postgres_data` volume | `redis:latest`, no volume — this store is not persisted in dev | `.docker/dev/compose.yml.example:3-19,79-82`, `.docker/dev/.env.example:3-6` |
| Self-host | `pgvector/pgvector:pg16`, bind mount `./data/postgres`, `POSTGRES_HOST_AUTH_METHOD: trust`, health-checked with `pg_isready` | `redis`, health-checked with `redis-cli --raw incr ping`, no volume | `.docker/selfhost/compose.yml:39-64` |
| Render | Managed database, `plan: basic-256mb`, `postgresMajorVersion: '16'`, `ipAllowList: []` | Managed `type: keyvalue`, `plan: starter`, `maxmemoryPolicy: noeviction`, `ipAllowList: []` | `render.yaml:42-52` |

The self-host path runs migrations in a separate one-shot container that waits on
both stores being healthy and that the app container in turn waits on
(`.docker/selfhost/compose.yml:8-14,23-37`). The local dev file has no such
container — migrations there are the setup commands in [AGENTS.md].

`.docker/dev/compose.yml.example` is an example, not a compose file. Nothing in
the repository copies it into place — see [Known Gaps].

## Commands

```sh
# Bring up only the two datastores from the dev example file. `-f` makes
# .docker/dev the project directory, which is where the env_file `.env` and the
# ${DB_VERSION} interpolation are resolved from
# (.docker/dev/compose.yml.example:4-6).
cp .docker/dev/.env.example .docker/dev/.env
docker compose -f .docker/dev/compose.yml.example up -d postgres redis

# List installed extensions. Expect `vector` after migrations have run; expect
# `pgcrypto` only if the image or the server could create it
# (packages/backend/server/migrations/20250210090228_ai_context_embedding/migration.sql:4).
# Credentials are the ones from .docker/dev/.env.example:4-6.
docker compose -f .docker/dev/compose.yml.example exec postgres \
  psql -U affine -d affine -c '\dx'

# Show which key-value database indexes hold data. With the default redis.db of
# 0 (packages/backend/server/src/base/redis/config.ts:22-26) a running server
# populates db0, db2, db3, and db4 — never db1.
docker compose -f .docker/dev/compose.yml.example exec redis redis-cli INFO keyspace
```

## Known Gaps

| Gap | Evidence | What Happens Today |
|---|---|---|
| The dev datastores have no ready-to-run compose file | `.docker/dev/compose.yml.example`, `.docker/dev/.env.example`, `.gitignore:137` | Both files carry an `.example` suffix and no script copies them. `.env` is gitignored, `compose.yml` is not, so the intended landing place for each is not stated either. The commands above pass the example file to `-f` directly rather than guess |
| Neither extension guard fails the migration | `packages/backend/server/migrations/20250210090228_ai_context_embedding/migration.sql:8-28`, `packages/backend/server/migrations/20260109090137_tokens_and_otp/migration.sql:7-12` | Both wrap `CREATE EXTENSION` in an exception handler that downgrades the failure to `RAISE WARNING`. A migration run against a stock `postgres:16` reports success. The embedding tables are then guarded by a second `IF EXISTS` check on the extension (`migration.sql:31-32`) and are simply never created, so the mismatch surfaces at query time rather than at migration time |
| The key-value index guard is dead code | `packages/backend/server/src/base/redis/instances.ts:43-51`, `packages/backend/server/src/base/redis/config.ts:26` | `assertValidDBIndex` is defined on the base class and called from nowhere in `src`. Its own message ("must be between 0 and 11") does not match its check (`db > 15`), and the schema that is actually enforced allows `10`, which puts `QueueRedis` on index 14 |
| The self-host database accepts any client without a password | `.docker/selfhost/compose.yml:58` | `POSTGRES_HOST_AUTH_METHOD: trust` is set, and the app connects with `postgresql://affine@postgres:5432/affine` (`.docker/selfhost/compose.yml:20`) — a URL with no password. Anything that can reach the container is authenticated |
| There is no search datastore | `.docker/dev/compose.yml.example:35-66,82`, `packages/backend/server/src/plugins/indexer/config.ts:29-36` | The Elasticsearch service in the dev file is commented out while the `elasticsearch_data` volume it would use is still declared. The indexer plugin is disabled by default and its default provider is `embedded`, so no fourth store is required to boot |

## Assumptions

- Why the deployment sets `maxmemoryPolicy: noeviction` (`render.yaml:45`) is not
  stated anywhere in the repository. That it is set because the store holds
  sessions and the bullmq queue rather than a pure cache is an inference from
  `packages/backend/server/src/base/redis/instances.ts:61-100`, not a documented
  reason **(assumption — needs confirming)**.
- The repository never names the engine behind Render's `type: keyvalue`
  (`render.yaml:42`). The client is `ioredis`
  (`packages/backend/server/src/base/redis/instances.ts:7`) and both compose
  files use a `redis` image, so the two are treated as interchangeable here.
  Whether the managed service answers every command bullmq issues is
  **(assumption — needs confirming)**.
- The lowest PostgreSQL major version that works is not recorded. `16` is what
  all three paths pin (`render.yaml:51`, `.docker/selfhost/compose.yml:50`,
  `.docker/dev/.env.example:2`), and `DB_VERSION` in the dev file is
  parameterised, which implies others were expected to work. The supported range
  is **(assumption — needs confirming)**.

[AGENTS.md]: ../AGENTS.md
[conventions/env.md]: ./env.md
[conventions/networking.md]: ./networking.md
[conventions/deploy.md]: ./deploy.md
[Known Gaps]: #known-gaps
[Assumptions]: #assumptions
