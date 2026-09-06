# Networking

Which port each process in this repository opens, which paths answer on the
server's port, and the address one service uses to reach another. Every claim
below is followed by the `file:line` it was read from. Where the repository does
not back a claim, it is marked `(assumption — needs confirming)` rather than
filled in.

## Scope Statement

This guide answers three questions:

- Which port each process binds, and what sets it.
- Which paths the server answers on, and which of them exist only in some
  configurations.
- How each pair of services in this repository addresses the other.

It does not answer: what the variables behind these numbers default to
([conventions/env.md]), what the stores on the far end must provide
([conventions/datastore.md]), or how the image that opens these ports is
produced ([conventions/deploy.md]). The commands that start the two dev
processes are in the contract, not here — see [AGENTS.md].

One rule underlies the whole page: the server binds **one** port and serves the
REST API, GraphQL, websockets, and the static frontend on it
(`packages/backend/server/src/server.ts:131`). There is no second listener.

## Ports

| Port            | Opened By                                                                            | Bound To                                   | Evidence                                                                                               |
| --------------- | ------------------------------------------------------------------------------------ | ------------------------------------------ | ------------------------------------------------------------------------------------------------------ |
| `3010`          | `@affine/server`, default                                                            | `0.0.0.0`, the `server.listenAddr` default | `packages/backend/server/src/core/config/config.ts:62-71`, `packages/backend/server/src/server.ts:131` |
| `10000`         | The same server in the Render deployment, via `AFFINE_SERVER_PORT`                   | as above                                   | `render.yaml:41-42`                                                                                    |
| `$PORT`         | The same server under the preview scripts — `PORT` is translated into `AFFINE_SERVER_PORT` before the bundle is exec'd | as above                                   | `packages/backend/server/scripts/runtime-env.sh:106-123`, `preview.toml:45`                            |
| `8080`          | The rspack dev server, for every frontend target **(assumption — needs confirming)** | `0.0.0.0`, with `allowedHosts: 'all'`      | `tools/cli/src/bundle-shared.ts:31-32,43`                                                              |
| `5432`          | The dev PostgreSQL container, published to the host                                  | host and container both `5432`             | `.docker/dev/compose.yml.example:7-8`                                                                  |
| `6379`          | The dev key-value container, published to the host                                   | host and container both `6379`             | `.docker/dev/compose.yml.example:18-19`                                                                |
| `1025` / `8025` | The dev mail catcher — SMTP and its web UI                                           | published to the host                      | `.docker/dev/compose.yml.example:24-26`                                                                |

The dev server's port is the one number on this page that no file in the
repository sets — see [Known Gaps]. The self-host compose file publishes the
server at `3010:3010` and publishes neither store
(`.docker/selfhost/compose.yml:24-25,43-68`). The image itself declares
`EXPOSE 3010` (`.github/deployment/node/Dockerfile:511`) and, when neither store
variable is set, also opens `5432` and `6379` on its own loopback for the
PostgreSQL and Redis it starts inside itself
(`packages/backend/server/scripts/self-host-entrypoint.sh:32-46,356-368`).

## Paths On The Server Port

| Path                     | Served By                                                                                                                            | Present When                                                                                                                                | Evidence                                                                                                                                                                                                                              |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/info`                  | `AppController`, marked `@Public()` and `@SkipThrottle()`. This is the deployment's health check target                              | Always — the controller is registered on the compiled module, outside any flavor check                                                      | `packages/backend/server/src/app.controller.ts:6-18`, `packages/backend/server/src/app.module.ts:158`, `render.yaml:23`                                                                                                               |
| `/graphql`               | The Nest GraphQL module. `graphiql` is on only when `NODE_ENV` is development                                                        | Under the `graphql` flavor, and so also under the default `allinone`                                                                        | `packages/backend/server/src/base/graphql/index.ts:33-34,42`, `packages/backend/server/src/app.module.ts:198-200`, `packages/backend/server/src/env.ts:144-146,150`                                                                   |
| `/socket.io`             | The socket.io endpoint of `SocketIoAdapter`, transports `websocket` and `polling` **(assumption — needs confirming)**                | The adapter is installed unconditionally; the gateways that attach to it are gated on role (`app.module.ts:170`) and on flavor (`:189-193`) | `packages/backend/server/src/server.ts:113-114`, `packages/backend/server/src/base/websocket/adapter.ts:19-54`, `packages/backend/server/src/base/websocket/config.ts:15-28`, `packages/backend/server/src/app.module.ts:170,189-193` |
| `/api/...`               | Fifteen REST controllers, each declaring its own `/api` subtree — fourteen as literals, one behind the `STORAGE_PROXY_ROOT` constant | Depends on the module each controller belongs to                                                                                            | `packages/backend/server/src/core/auth/controller.ts:68`, `packages/backend/server/src/base/storage/utils.ts:69`, and the `grep` in [Commands]                                                                                        |
| `/api/docs`              | Swagger UI                                                                                                                           | Development only                                                                                                                            | `packages/backend/server/src/server.ts:116-128`                                                                                                                                                                                       |
| `/workspace/*path`       | The doc renderer, reading prebuilt HTML from `static/` and `static/mobile`                                                           | Under the `renderer` or `front` flavor — the first of those also accepts `allinone`                                                         | `packages/backend/server/src/core/doc-renderer/controller.ts:54,66-68,80`, `packages/backend/server/src/app.module.ts:186-187`                                                                                                        |
| `/admin`, `/admin/*path` | Static admin bundle from `<projectRoot>/static/admin`, with an SPA fallback                                                          | Two separate modules cover this — see below                                                                                                 | `packages/backend/server/src/core/selfhost/static.ts:47-77`, `packages/backend/server/src/core/static-files/static.ts:88-89`                                                                                                          |
| `/`, `/*path`            | Static web bundle from `<projectRoot>/static`, with a mobile bundle layered under the same prefix                                    | as above                                                                                                                                    | `packages/backend/server/src/core/selfhost/static.ts:79-122`, `packages/backend/server/src/core/static-files/static.ts:94-128`                                                                                                        |

Two different modules serve the last two rows. `SelfhostModule` is enabled when
the process is not worker-only and is either in development or self-hosted
(`packages/backend/server/src/app.module.ts:216-221`), and self-hosted is the
default outside development
(`packages/backend/server/src/env.ts:97-101,107-109`). `StaticFileModule` is
enabled only when `SERVER_FLAVOR` is exactly `front` — not under `allinone`,
because that row of `flavors` compares for equality where every other row also
accepts `allinone` (`packages/backend/server/src/env.ts:148-158`,
`packages/backend/server/src/app.module.ts:222-223`).

`<projectRoot>` is the directory above the compiled `dist`
(`packages/backend/server/src/env.ts:105`); what is placed there is
[conventions/deploy.md]'s subject.

Every path above is prefixed by `server.path` when that is non-empty, because it
becomes the Nest global prefix and the static routes concatenate it by hand
(`packages/backend/server/src/server.ts:86-88`,
`packages/backend/server/src/core/static-files/static.ts:36-37`). The variable
that fills it is in [conventions/env.md].

## Service To Service

| From → To                               | Address                                                                                                                                                             | Evidence                                                                                                       |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| Frontend dev server → backend           | `http://localhost:3010`, for `/api`, `/graphql`, and `/socket.io`. Only the socket.io entry sets `ws: true`, so only it upgrades                                    | `tools/cli/src/bundle-shared.ts:57-71`                                                                         |
| Electron dev → frontend dev server      | `DEV_SERVER_URL=http://localhost:8080`                                                                                                                              | `packages/frontend/apps/electron/package.json:25`                                                              |
| iOS dev shell → frontend dev server     | `CAP_SERVER_URL=http://localhost:8080`                                                                                                                              | `packages/frontend/apps/ios/package.json:12`                                                                   |
| Android dev shell → frontend dev server | `CAP_SERVER_URL=http://10.0.2.2:8080` **(assumption — needs confirming)**                                                                                           | `packages/frontend/apps/android/package.json:10`                                                               |
| Self-host app container → stores        | Compose service names — `postgres:5432` in the connection string, `redis` as the key-value host, both on the default compose network                                | `.docker/selfhost/compose.yml:34-40`                                                                           |
| Single-container image → stores         | `127.0.0.1` on `5432` and `6379`, the servers the entrypoint starts inside the image when neither variable is set                                                   | `packages/backend/server/scripts/self-host-entrypoint.sh:32-46,356-368`                                        |
| Preview host → stores                   | Whatever `DATABASE_URL` names, which the start command refuses to guess; the cache defaults to `localhost:6379` unless `REDIS_URL` names another                    | `scripts/preview/start.sh:115-117`, `packages/backend/server/scripts/runtime-env.sh:127-230`                   |
| Render web service → stores             | Injected at deploy time from the managed services; both stores set `ipAllowList: []`, which the file annotates as internal connections only                         | `render.yaml:45-58,64,70`                                                                                      |
| Render platform → web service           | `GET /info` as the health check                                                                                                                                     | `render.yaml:23`                                                                                               |
| Browser → server                        | Any origin outside the computed allowlist is refused. The allowlist is the server's own origin, plus additional hosts, plus fixed mobile and desktop client origins | `packages/backend/server/src/base/cors.ts:5-15,78-84`, `packages/backend/server/src/base/helpers/url.ts:51-76` |

The server's own origin includes the port only when the host is `localhost` or a
literal IP; for a named host the port is dropped
(`packages/backend/server/src/base/helpers/url.ts:239-246`). A deployment behind
a proxy that terminates on a non-default port therefore needs
`AFFINE_SERVER_EXTERNAL_URL` rather than host plus port — that variable is
described in [conventions/env.md].

The websocket adapter shares the HTTP listener's allowlist and additionally
fans its own messages across instances through the key-value store
(`packages/backend/server/src/base/websocket/adapter.ts:30-53,73-76`).

## Commands

```sh
# List every path prefix the server declares, with the file and line. This is
# the generator of the /api row above; seventeen controllers today, fifteen of
# them under /api.
grep -rn "@Controller(" packages/backend/server/src --include=*.ts | grep -v __tests__

# Ask a running server what it is. This is the same response the deployment's
# health check reads (render.yaml:23), so a non-200 here is a failing deploy.
# A checkout reaches a server on this port with the two commands in AGENTS.md:
# `sh scripts/preview/build.sh` then `PORT=3010 sh scripts/preview/start.sh`.
curl -sS http://localhost:3010/info

# Show which of the ports above are actually bound on this machine right now.
ss -ltn '( sport = :3010 or sport = :8080 or sport = :5432 or sport = :6379 )'
```

## Known Gaps

| Gap                                                              | Evidence                                                                                             | What Happens Today                                                                                                                                                                                                                                                                                                           |
| ---------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| The frontend dev server port is not configured                   | `tools/cli/src/bundle-shared.ts:30-44`, `tools/cli/src/bundle.ts:281-304`                            | `DEFAULT_DEV_SERVER_CONFIG` sets `host` but never `port`, and the only caller merges a config that no command line flag reaches. The effective port comes from the bundler's own default, while three client scripts and the dev client's `webSocketURL` hardcode `8080`. Changing the default would break all four silently |
| The dev proxy target is a literal                                | `tools/cli/src/bundle-shared.ts:57-71`, `packages/backend/server/src/core/config/config.ts:67-71`    | `http://localhost:3010` is written three times in the proxy table and read from no config. A backend started with `AFFINE_SERVER_PORT` set to anything else is running, healthy, and unreachable through the dev server                                                                                                      |
| The image advertises a port it does not listen on                | `.github/deployment/node/Dockerfile:511`, `render.yaml:41-42`                                        | The image declares `EXPOSE 3010`; the Render deployment sets the process to bind `10000`. Any tool that reads image metadata to decide where to connect points at a closed port                                                                                                                                           |
| The websocket mount path is pinned on one side only              | `packages/backend/server/src/base/websocket/config.ts:15-33`, `tools/cli/src/bundle-shared.ts:62-66` | The dev proxy matches the literal `/socket.io`; the server configures transports and buffer size but no `path`, leaving the library default in force. Nothing fails today, and nothing would catch it if the two stopped agreeing                                                                                            |
| The static frontend is off under the default flavor's own module | `packages/backend/server/src/env.ts:148-158`, `packages/backend/server/src/app.module.ts:222-223`    | `flavors.front` is the one entry that does not also accept `allinone`, so `StaticFileModule` never loads in the default flavor. The paths still answer, but through `SelfhostModule`, which is gated on a different condition — two modules serve the same routes under conditions that can both be false at once            |

## Assumptions

- The frontend dev server listens on `8080` **for every frontend target**.
  Nothing in the repository sets it; the number is inferred from the dev
  client's `webSocketURL` (`tools/cli/src/bundle-shared.ts:43`) and from the
  three client packages that point at `8080`. One target has been observed:
  `yarn affine dev -p web` bound `0.0.0.0:8080` and printed
  `Local: http://localhost:8080/`. The other frontend targets were not started,
  and the bundler's default that produces the number is a library fact rather
  than a repository fact, so both the coverage and the stability of `8080` are
  **(assumption — needs confirming)**.
- `/socket.io` is the path the server actually mounts. No `path` is configured
  (`packages/backend/server/src/base/websocket/config.ts:15-33`), so this is the
  socket.io library default, corroborated only by the dev proxy entry that
  matches it **(assumption — needs confirming)**.
- `10.0.2.2` in the Android sync script
  (`packages/frontend/apps/android/package.json:10`) is read here as the
  emulator's alias for the host machine. That mapping belongs to the emulator,
  and no file here states it **(assumption — needs confirming)**.
- Which networks can reach a service marked `ipAllowList: []`
  (`render.yaml:64,70`) is decided by the hosting platform. The file's own
  comment says internal connections only; nothing in the repository defines what
  internal means **(assumption — needs confirming)**.

[AGENTS.md]: ../AGENTS.md
[conventions/datastore.md]: ./datastore.md
[conventions/env.md]: ./env.md
[conventions/deploy.md]: ./deploy.md
[Commands]: #commands
[Known Gaps]: #known-gaps
