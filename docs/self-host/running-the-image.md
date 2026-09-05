# Running the Self-Host Image

> **Warning**
> This document is not guaranteed to be up-to-date.
> If you find any outdated information, please feel free to open an issue or submit a PR.

The image carries a PostgreSQL 16 server with pgvector and a Redis server of its
own. Whether they are used is decided at startup, by two variables and nothing
else: leave `DATABASE_URL` and `REDIS_SERVER_HOST` empty and the servers inside
the image start; fill them and the container connects to the ones you point it
at. That decision lives in exactly one file —
[`packages/backend/server/scripts/self-host-entrypoint.sh`](../../packages/backend/server/scripts/self-host-entrypoint.sh),
the image's `ENTRYPOINT` — so `docker run`, the compose stack and Render all
reach the same behaviour without any of them restating it.

Everything below assumes an image tagged `affine:selfhost`. See
[building-the-image.md](./building-the-image.md) for how to produce one.

## Table of Contents

- [Run it with nothing configured](#run-it-with-nothing-configured)
- [Run it against your own database and cache](#run-it-against-your-own-database-and-cache)
- [Persisting the data inside the image](#persisting-the-data-inside-the-image)
- [Restarting](#restarting)
- [The first account](#the-first-account)
- [Reading the startup log](#reading-the-startup-log)
- [Related Documents](#related-documents)

## Run it with nothing configured

```sh
docker run --detach --name affine \
  --publish 3010:3010 \
  --volume affine-app:/root/.affine \
  --volume affine-postgres:/var/lib/postgresql/data \
  --volume affine-redis:/var/lib/redis \
  affine:selfhost
```

That is the whole deployment: one container holding the server, its database and
its cache. Open <http://localhost:3010> once the log settles, and go on to
[the first account](#the-first-account).

The three `--volume` flags are what keep the data across `docker rm`; they are
covered in [persisting the data inside the image](#persisting-the-data-inside-the-image).
Drop them for a throwaway run and the container is genuinely one command with no
leftovers.

What happens before the server starts, in order:

1. The PostgreSQL data directory is initialised, if it does not already hold a
   cluster, and the server is started on `127.0.0.1:5432`.
2. The `affine` role and the `affine` database are created, if the cluster does
   not already have them, along with the `vector` and `pgcrypto` extensions.
3. Redis is started on `127.0.0.1:6379`.
4. The initial setup runs — the server's private key, then the schema and data
   migrations.
5. The server takes over the container.

Both embedded servers listen on the loopback address only, and both are reached
with a password that is minted fresh on every boot and never written to disk.
Nothing outside the container can connect to either, and no credential of theirs
is yours to keep or rotate.

Two consequences of that design are worth knowing before you rely on it:

- **The container must run as root on this path.** PostgreSQL refuses to run as
  root, so the entrypoint starts each server under its own service account —
  which is a move only root can make. `docker run --user` on this path stops
  with a sentence saying so, rather than failing later on a permission error.
- **The address the server publishes is still `localhost`.** That is the default
  of `AFFINE_SERVER_HOST`, and it is what links in invitations and e-mails will
  say. Serving anything but your own machine means setting it:

```sh
docker run --detach --name affine \
  --publish 3010:3010 \
  --env AFFINE_SERVER_HOST=affine.example.com \
  --env AFFINE_SERVER_HTTPS=true \
  --volume affine-app:/root/.affine \
  --volume affine-postgres:/var/lib/postgresql/data \
  --volume affine-redis:/var/lib/redis \
  affine:selfhost
```

## Run it against your own database and cache

```sh
docker run --detach --name affine \
  --publish 3010:3010 \
  --env DATABASE_URL='postgresql://affine:PASSWORD@postgres.internal:5432/affine' \
  --env REDIS_SERVER_HOST='redis.internal' \
  --volume affine-app:/root/.affine \
  affine:selfhost
```

Set, the two variables select an external target; empty or unset, they select
the one inside the image. Setting a variable to nothing —
`docker run --env DATABASE_URL` with no value — is a request for the in-image
database, not an attempt to connect to the empty string.

| Variable            | Empty                                        | Set                                                     |
| ------------------- | -------------------------------------------- | ------------------------------------------------------- |
| `DATABASE_URL`      | Starts PostgreSQL inside the image           | Connects to that connection string; starts nothing      |
| `REDIS_SERVER_HOST` | Starts Redis inside the image                | Connects to that host; starts nothing                   |

The two are independent. An external database with the in-image cache, or the
reverse, is a supported combination — each target is decided on its own.

`REDIS_SERVER_PORT` and `REDIS_SERVER_PASSWORD` are yours to set on the external
path. On the in-image path the entrypoint overwrites both with the values of the
cache it just started, because a port and a password belonging to some other
cache do not describe that one.

Your database needs a little more than an empty PostgreSQL: the migrations
declare `CREATE EXTENSION IF NOT EXISTS "vector"` and `"pgcrypto"`, so both
extensions have to be installable, and the role in `DATABASE_URL` has to own the
database it connects to. `pgvector/pgvector:pg16` is the image the compose stack
uses for exactly this reason.

The compose stack is this path written down — see
[`.docker/selfhost/compose.yml`](../../.docker/selfhost/compose.yml), which sets
both variables and runs the database and cache as sibling containers. Emptying
them there, and dropping the two services with them, moves the same stack onto
the path above.

## Persisting the data inside the image

The image declares no `VOLUME`. Where the data lives is your decision, and an
image that made it for you would be making it wrong for somebody. What that
means in practice: mount these paths, or lose what they hold when the container
is removed.

| Path                        | Holds                                                     | Mount it when                     |
| --------------------------- | --------------------------------------------------------- | --------------------------------- |
| `/root/.affine`             | The server's private key, uploaded blobs and avatars      | Always                            |
| `/var/lib/postgresql/data`  | The in-image database cluster — every document and user   | `DATABASE_URL` is empty           |
| `/var/lib/redis`            | The in-image cache's snapshots                            | `REDIS_SERVER_HOST` is empty      |

`/root/.affine` matters on both paths and is the one people forget. Losing it
loses the uploaded blobs, and it loses `private.key` — which the next boot
regenerates, signing out every session that was issued under the old one.

> **Note**
> `docker stop` sends its signal to the server, which is the container's main
> process; the embedded servers are killed rather than asked to stop. PostgreSQL
> replays its write-ahead log on the next start and Redis rolls back to its last
> snapshot, so neither is corrupted, but a cache write from the final seconds may
> not survive. Stopping under load is best followed by a look at the startup log.

## Restarting

Starting the same image again over data it has already written is a supported,
unremarkable thing to do — `docker restart affine`, `docker compose up` a second
time, or a fresh container over the same volumes. Every step of the startup asks
before it acts:

- The database cluster is initialised only when the data directory holds none.
- The role, the database and the two extensions are created only when the
  catalog says they are missing.
- The private key is generated only when the file is absent.
- `prisma migrate deploy` applies the migrations that have not been applied, and
  the data migrations record what they have run.

So a second boot repeats nothing and fails nothing. This holds for a database
populated by an entirely different container too, which is what makes upgrading
the image a matter of replacing the container.

The one thing that does not survive a restart is the pair of passwords for the
in-image database and cache. They are minted per boot and exist only in the
running container, so a volume that outlives it carries no credential with it.

## The first account

The image ships no account, and no environment variable creates one. The first
administrator is created once, in the browser, on a server that has no users
yet.

1. Open <http://localhost:3010/admin>. While no user exists, the server sends
   you to `/admin/setup` instead of a sign-in page.
2. Fill in a name, an e-mail address and a password.

That form posts to `/api/setup/create-admin-user`, which refuses once a first
user exists. The account it creates is an administrator, you are signed in as it
immediately, and from then on `/admin` is an ordinary sign-in.

> **Warning**
> Until that first account exists, the setup page accepts anyone who can reach
> the port — that is what "no users yet" means for an endpoint that has nobody to
> authenticate against. Create the account as soon as the container is up, or
> keep the port unreachable until you have.

## Reading the startup log

`docker logs affine` opens with one line per target — the database, then the
cache. They are not necessarily adjacent: a server that is being started inside
the image logs its own startup between them. On the in-image path:

```text
[entrypoint] `DATABASE_URL` is empty — starting the database inside this image; set it to a connection string to use one outside.
[entrypoint] `REDIS_SERVER_HOST` is empty — starting the cache inside this image; set it to a host name to use one outside.
```

and on the external path:

```text
[entrypoint] `DATABASE_URL` is set — using the database outside this image; unset it to start the one inside.
[entrypoint] `REDIS_SERVER_HOST` is set — using the cache outside this image; unset it to start the one inside.
```

There are always two, one per target, and they can disagree — a container with
`DATABASE_URL` set and `REDIS_SERVER_HOST` empty prints one of each. If a line
is missing, the container is not running this image's entrypoint.

The lines name the variable, never its value: a connection string carries a
password, and `docker logs` keeps what it is given.

Both embedded servers write to the same stdout as the application, so a database
or cache that fails to start says why, in place, rather than leaving the server
to fail later against something that was never there.

## Related Documents

- [building-the-image.md](./building-the-image.md) — building this image from source, before you can run it
- [container-build-audit.md](./container-build-audit.md) — the state the build and startup definitions were in before this behaviour existed, kept as the baseline the change was reviewed against
- [developing-server.md](../developing-server.md) — running the server on your machine instead, without Docker
