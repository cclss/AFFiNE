# Developing the AFFiNE Server

> **Warning**
> This document is not guaranteed to be up-to-date.
> If you find any outdated information, please feel free to open an issue or submit a PR.
>
> **Note**
> This guide covers running the server (`@affine/server`) locally with Docker.
> For building and developing the web app, see [BUILDING.md](./BUILDING.md).

## Run required dev services in docker compose

Running yarn's server package (@affine/server) requires some dev services to be running, i.e.:

- postgres
- redis
- mailhog

You can run these services in docker compose by running the following command:

```sh
cp ./.docker/dev/compose.yml.example ./.docker/dev/compose.yml
cp ./.docker/dev/.env.example ./.docker/dev/.env

docker compose -f ./.docker/dev/compose.yml up
```

### Notify

> Starting from AFFiNE 0.20, compose.yml includes a breaking change: the default database image has switched from `postgres:16` to `pgvector/pgvector:pg16`. If you were previously using another major version of Postgres, please change the number after `pgvector/pgvector:pg` to the major version you are using.

## Build native packages (you need to setup rust toolchain first)

Server also requires native packages to be built, you can build them by running the following command:

```sh
# build native
yarn affine @affine/server-native build
```

## Prepare dev environment

The server reads its configuration from `packages/backend/server/.env`. Copy the example and uncomment the variables you need — at minimum `DATABASE_URL`, which the next step connects with:

```sh
cp packages/backend/server/.env.example packages/backend/server/.env
```

## Set up the local environment

One command, from the project root, takes the checkout the rest of the way:

```sh
yarn setup
```

It runs the following in order, and stops at the first step that fails:

1. Install workspace dependencies (a no-op if you already ran `yarn install`).
2. Apply pending database migrations.
3. Run pending data migrations.
4. Seed the [standard accounts](#sign-in) below.

Every step is safe to repeat. Run `yarn setup` again whenever new migrations land, or against a database that already holds your data — it brings the schema up to date and leaves existing rows, including the seeded accounts, untouched.

To see the steps without running them:

```sh
yarn affine setup --dry-run
```

## Start server

```sh
# at project root
yarn affine server dev
```

## Sign in

`yarn setup` creates two fixed accounts, and prints them again on every run:

| Email                | Password       | Role  | Can open the admin panel |
| -------------------- | -------------- | ----- | ------------------------ |
| `dev@affine.local`   | `affine-dev`   | user  | no                       |
| `admin@affine.local` | `affine-admin` | admin | yes                      |

> **Warning**
> These credentials are for local development only. They are published in this repository, so treat any environment that accepts them as public — never seed them into a shared or production database. The seed refuses to run with `NODE_ENV=production`.

### Admin panel

The admin app is a separate dev target. Sign in to it with `admin@affine.local`:

```sh
# at project root
yarn dev -p @affine/admin
```

It serves on the same **<http://localhost:8080>** port as the web app, so stop one before starting the other.

## Start frontend

```sh
# at project root
yarn dev
```

You can sign in with `dev@affine.local` / `affine-dev` to test the server.

## Done

Now you should be able to start developing affine with server enabled.

## Bonus

### Enable prisma studio (Database GUI)

```sh
# available at http://localhost:5555
yarn affine server prisma studio
```

### Seed the db

The standard accounts above cover the common case. To create extra fixtures — additional users, workspaces, team entitlements — use the seed command directly:

```sh
yarn affine server seed -h
```
