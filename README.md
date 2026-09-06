<div align="center">

<h1 style="border-bottom: none">
    <b><a href="https://affine.pro">AFFiNE.Pro</a></b><br />
    Write, Draw and Plan All at Once
    <br>
</h1>
<a href="https://affine.pro/download">
    <img alt="affine logo" src="https://cdn.affine.pro/Github_hero_image2.png" style="width: 100%">
</a>
<br/>
<p align="center">
  A privacy-focused, local-first, open-source, and ready-to-use alternative for Notion & Miro. <br />
  One hyper-fused platform for wildly creative minds.
</p>

<br/>

<br/>
<a href="https://www.producthunt.com/posts/affine-3?utm_source=badge-featured&utm_medium=badge&utm_souce=badge-affine&#0045;3" target="_blank"><img src="https://api.producthunt.com/widgets/embed-image/v1/featured.svg?post_id=440671&theme=light" alt="AFFiNE - One&#0032;app&#0032;for&#0032;all&#0032;&#0045;&#0032;Where&#0032;Notion&#0032;meets&#0032;Miro | Product Hunt" style="width: 250px; height: 54px;" width="250" height="54" /></a>
<br/>
<br/>

<div align="center">
    <a href="https://affine.pro">Home Page</a> |
    <a href="https://affine.pro/redirect/discord">Discord</a> |
    <a href="https://app.affine.pro">Live Demo</a> |
    <a href="https://affine.pro/blog/">Blog</a> |
    <a href="https://docs.affine.pro/">Documentation</a>
</div>
<br/>

[![Releases](https://img.shields.io/github/downloads/toeverything/AFFiNE/total)](https://github.com/toeverything/AFFiNE/releases/latest)
[![All Contributors][all-contributors-badge]](#contributors)
[![TypeScript-version-icon]](https://www.typescriptlang.org/)

</div>

<br />
<div align="center">
<em>Docs, canvas and tables are hyper-merged with AFFiNE - just like the word affine (əˈfʌɪn | a-fine).</em>
</div>
<br />

<div align="center">
<img src="https://github.com/toeverything/AFFiNE/assets/79301703/49a426bb-8d2b-4216-891a-fa5993642253" style="width: 100%"/>
</div>

## Getting started & staying tuned with us.

Star us, and you will receive all release notifications from GitHub without any delay!

<img src="https://user-images.githubusercontent.com/79301703/230891830-0110681e-8c7e-483b-b6d9-9e42b291b9ef.gif" style="width: 100%"/>

## What is AFFiNE

[AFFiNE](https://affine.pro) is an open-source, all-in-one workspace and an operating system for all the building blocks that assemble your knowledge base and much more -- wiki, knowledge management, presentation and digital assets. It's a better alternative to Notion and Miro.

## Run it locally

Two commands turn a clean checkout into a running server — one builds it, one
starts it. They are the steps the container image takes, with the container
taken away, and both are run from the repository root.

### Before you start

- **Node**, the major version [`.nvmrc`](.nvmrc) pins. Yarn is not needed on the
  host: the build points the name at the release vendored in `.yarn/releases`.
- **A PostgreSQL you can reach**, holding an empty database and a role that may
  create tables in it. The commands below provision no database and refuse
  rather than guess a connection string.
- **Network access on the first build** — dependencies come from the npm
  registry, and the Rust toolchain [`rust-toolchain.toml`](rust-toolchain.toml)
  pins is installed when the host has neither `rustup` nor `cargo`.

A `pgvector/pgvector:pg16` image is the PostgreSQL these migrations are written
against. A stock `postgres:16` migrates and runs — the migration that needs the
extension downgrades its own failure to a warning — but the embedding tables
behind AI search are then never created. See
[conventions/datastore.md](./conventions/datastore.md).

### Configuration

Every value below is read from the environment. None of them is read from a file
in this repository, and no credential belongs in one.

| Variable | What It Names | When It Is Unset |
|---|---|---|
| `DATABASE_URL` | The PostgreSQL the migrations and the server both use | The start command stops before it connects to anything — this is the one value with no default |
| `PORT` | The port the server listens on | The server listens on `3010` |
| `REDIS_URL` | The cache, as one URL — host, port and credentials | The server looks for a cache at `localhost:6379` |
| `AFFINE_SERVER_HTTPS` | That this deployment serves TLS itself | The server speaks plain HTTP and redirects nothing to https, which is what a TLS terminator in front of it expects |
| `LISTEN_ADDR` | The one address to accept connections on | The server accepts connections on every interface |

`PORT` and `REDIS_URL` are a hosting platform's names for two things this server
names differently, so they are translated on the way in — and the server's own
`AFFINE_SERVER_PORT` and `REDIS_SERVER_HOST` win whenever both are set. Every
variable the server reads is listed in [conventions/env.md](./conventions/env.md).

### Build and start

```sh
# The database this run should use. It is the one value with no default.
export DATABASE_URL='postgresql://affine@localhost:5432/affine'
export PORT=3010

# Installs the workspace, builds the native addon, both frontends and the
# server bundle, then stages the frontends where the server serves them from.
sh scripts/preview/build.sh

# Applies the migrations, seeds the first account, then becomes the server.
sh scripts/preview/start.sh
```

Both scripts print one line per decision and per step, each prefixed `[preview]`.
The first screen is then at <http://localhost:3010>, served over plain HTTP by
the same process that answers `/api` and `/graphql` — one port, and no redirect
to a second one.

### What the first start does to an empty database

`scripts/preview/start.sh` hands the database to
`packages/backend/server/scripts/self-host-predeploy.js` before the server
accepts a request. Each of its four steps asks what it finds rather than whether
this is the first start, so starting again over the same database repeats
nothing and fails nothing.

| Step | On An Empty Database | On A Database It Has Run Against Before |
|---|---|---|
| `private.key` | Generated under `~/.affine/config` | Kept — sessions signed before the restart stay valid |
| Schema migrations | All applied — `yarn prisma migrate deploy` | Only the ones not yet applied |
| Data migrations | All applied — `yarn cli run` | Only the ones not yet recorded |
| The standard seed | Creates one administrator — `yarn cli standard-seed` | Creates nothing, because the database already holds a user |

### The first account

The seed leaves one administrator behind, and it is the account to sign in with:

| Field | Value |
|---|---|
| Name | `Admin` |
| E-mail | `admin@example.com` |
| Password | `change-me` |

The three values are a constant in
[`standard-seed.ts`](./packages/backend/server/src/data/commands/standard-seed.ts),
so they are the same in every checkout of this repository — a published default
rather than a secret. The address is under `example.com`, which RFC 2606
reserves for documentation, so it can collide with no real mailbox.

> **Warning**
> Anyone who can reach the port can sign in as this administrator until the
> password is changed. Change it at `/admin/accounts` before this server is
> reachable by anybody but you.

The seed creates nothing as soon as the database holds any user, so pointing
`DATABASE_URL` at an existing deployment grows no extra account there. For the
same migrations and the same first account brought up by `docker run` instead of
these two commands, see
[running the self-host image](./docs/self-host/running-the-image.md); for the
dev servers and watch builds a contributor works against, see [BUILDING.md].

## Features

**A true canvas for blocks in any form. Docs and whiteboard are now fully merged.**

- Many editor apps claim to be a canvas for productivity, but AFFiNE is one of the very few which allows you to put any building block on an edgeless canvas -- rich text, sticky notes, any embedded web pages, multi-view databases, linked pages, shapes and even slides. We have it all.

**Multimodal AI partner ready to kick in any work**

- Write up professional work report? Turn an outline into expressive and presentable slides? Summary an article into a well-structured mindmap? Sorting your job plan and backlog for tasks? Or... draw and code prototype apps and web pages directly all with one prompt? With you, [AFFiNE AI](https://affine.pro/ai) pushes your creativity to the edge of your imagination, just like [Canvas AI](https://affine.pro/blog/best-canvas-ai) to generate mind map for brainstorming.

**Local-first & Real-time collaborative**

- We love the idea of local-first that you always own your data on your disk, in spite of the cloud. Furthermore, AFFiNE supports real-time sync and collaborations on web and cross-platform clients.

**Self-host & Shape your own AFFiNE**

- You have the freedom to manage, self-host, fork and build your own AFFiNE. Plugin community and third-party blocks are coming soon. More tractions on [Blocksuite](https://blocksuite.io). Check there to learn how to [self-host AFFiNE](https://docs.affine.pro/self-host-affine).

## Acknowledgement

“We shape our tools and thereafter our tools shape us”. A lot of pioneers have inspired us along the way, e.g.:

- Quip & Notion with their great concept of “everything is a block”
- Trello with their Kanban
- Airtable & Miro with their no-code programmable datasheets
- Miro & Whimiscal with their edgeless visual whiteboard
- Remote & Capacities with their object-based tag system

There is a large overlap of their atomic “building blocks” between these apps. They are not open source, nor do they have a plugin system like Vscode for contributors to customize. We want to have something that contains all the features we love and also goes one step even further.

Thanks for checking us out, we appreciate your interest and sincerely hope that AFFiNE resonates with you! 🎵 Checking https://affine.pro/ for more details ions.

## Contributing

| Bug Reports                                                                                                                                         | Feature Requests                                                                                                                                               | Questions/Discussions                                                         | AFFiNE Community                                                  |
| --------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- | ----------------------------------------------------------------- |
| [Create a bug report](https://github.com/toeverything/AFFiNE/issues/new?assignees=&labels=bug%2Cproduct-review&template=BUG-REPORT.yml&title=TITLE) | [Submit a feature request](https://github.com/toeverything/AFFiNE/issues/new?assignees=&labels=feat%2Cproduct-review&template=FEATURE-REQUEST.yml&title=TITLE) | [Check GitHub Discussion](https://github.com/toeverything/AFFiNE/discussions) | [Visit the AFFiNE's Discord](https://affine.pro/redirect/discord) |
| Something isn't working as expected                                                                                                                 | An idea for a new feature, or improvements                                                                                                                     | Discuss and ask questions                                                     | A place to ask, learn and engage with others                      |

Calling all developers, testers, tech writers and more! Contributions of all types are more than welcome, you can read more in [docs/types-of-contributions.md](docs/types-of-contributions.md). If you are interested in contributing code, read our [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) and feel free to check out our GitHub issues to get stuck in to show us what you’re made of.

**Before you start contributing, please sign our [Contributor License Agreement] — it takes less than a minute with your GitHub account. Pull requests cannot be merged until every committer has signed (the `license/cla` check on your PR). Full text: [CLA.md](.github/CLA.md).**

For **bug reports**, **feature requests** and other **suggestions** you can also [create a new issue](https://github.com/toeverything/AFFiNE/issues/new/choose) and choose the most appropriate template for your feedback.

For **translation** and **language support** you can visit our [Discord](https://affine.pro/redirect/discord).

If you have questions, you are welcome to contact us. One of the best places to get more info and learn more is in the [Discord](https://affine.pro/redirect/discord) where you can engage with other like-minded individuals.

## Templates

AFFiNE now provides pre-built [templates](https://affine.pro/templates) from our team. Following are the Top 10 most popular templates among AFFiNE users,if you want to contribute, you can contribute your own template so other people can use it too.

- [vision board template](https://affine.pro/templates/category-vision-board-template)
- [one pager template](https://affine.pro/templates/category-one-pager-template-free)
- [sample lesson plan math template](https://affine.pro/templates/sample-lesson-plan-math-template)
- [grr lesson plan template free](https://affine.pro/templates/grr-lesson-plan-template-free)
- [free editable lesson plan template for pre k](https://affine.pro/templates/free-editable-lesson-plan-template-for-pre-k)
- [high note collection planners](https://affine.pro/templates/high-note-collection-planners)
- [digital planner](https://affine.pro/templates/category-digital-planner)
- [ADHD Planner](https://affine.pro/templates/adhd-planner)
- [Reading Log](https://affine.pro/templates/reading-log)
- [Cornell Notes Template](https://affine.pro/templates/category-cornell-notes-template)

## Blog

Welcome to the AFFiNE blog section! Here, you’ll find the latest insights, tips, and guides on how to maximize your experience with AFFiNE and AFFiNE AI, the leading Canvas AI tool for flexible note-taking and creative organization.

- [vision board template](https://affine.pro/blog/8-free-printable-vision-board-templates-examples-2023)
- [ai homework helper](https://affine.pro/blog/ai-homework-helper)
- [vision board maker](https://affine.pro/blog/vision-board-maker)
- [itinerary template](https://affine.pro/blog/free-customized-travel-itinerary-planner-templates)
- [one pager template](https://affine.pro/blog/top-12-one-pager-examples-how-to-create-your-own)
- [cornell notes template](https://affine.pro/blog/the-cornell-notes-template-and-system-learning-tips)
- [swot chart template](https://affine.pro/blog/top-10-free-editable-swot-analysis-template-examples)
- [apps like luna task](https://affine.pro/blog/apps-like-luna-task)
- [note taking ai from rough notes to mind map](https://affine.pro/blog/dynamic-AI-notes)
- [canvas ai](https://affine.pro/blog/best-canvas-ai)
- [one pager](https://affine.pro/blog/top-12-one-pager-examples-how-to-create-your-own)
- [SOP Template](https://affine.pro/blog/how-to-write-sop-step-by-step-guide-5-best-free-tools-templates)
- [Chore Chart](https://affine.pro/blog/10-best-free-chore-chart-templates-kids-adults)

## Ecosystem

| Name                                             |                            |                                                                                                                                         |
| ------------------------------------------------ | -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| [@affine/component](packages/frontend/component) | AFFiNE Component Resources | ![](https://img.shields.io/codecov/c/github/toeverything/affine?style=flat-square)                                                      |
| [@toeverything/theme](packages/common/theme)     | AFFiNE theme               | [![](https://img.shields.io/npm/dm/@toeverything/theme?style=flat-square&color=eee)](https://www.npmjs.com/package/@toeverything/theme) |

## Upstreams

We would also like to give thanks to open-source projects that make AFFiNE possible:

- [Blocksuite](https://github.com/toeverything/BlockSuite) - 💠 BlockSuite is the open-source collaborative editor project behind AFFiNE.
- [y-octo](https://github.com/y-crdt/y-octo) - 🐙 y-octo is a native, high-performance, thread-safe YJS CRDT implementation, serving as the core engine enabling the AFFiNE Client/Server to achieve "local-first" functionality.
- [OctoBase](https://github.com/toeverything/OctoBase) - 🐙 OctoBase is the open-source database behind AFFiNE, local-first, yet collaborative. A light-weight, scalable, data engine written in Rust.

- [yjs](https://github.com/yjs/yjs) - Fundamental support of CRDTs for our implementation on state management and data sync on web.
- [electron](https://github.com/electron/electron) - Build cross-platform desktop apps with JavaScript, HTML, and CSS.
- [React](https://github.com/facebook/react) - The library for web and native user interfaces.
- [napi-rs](https://github.com/napi-rs/napi-rs) - A framework for building compiled Node.js add-ons in Rust via Node-API.
- [Jotai](https://github.com/pmndrs/jotai) - Primitive and flexible state management for React.
- [async-call-rpc](https://github.com/Jack-Works/async-call-rpc) - A lightweight JSON RPC client & server.
- [Vite](https://github.com/vitejs/vite) - Next generation frontend tooling.
- Other upstream [dependencies](https://github.com/toeverything/AFFiNE/network/dependencies).

Thanks a lot to the community for providing such powerful and simple libraries, so that we can focus more on the implementation of the product logic, and we hope that in the future our projects will also provide a more easy-to-use knowledge base for everyone.

## Contributors

We would like to express our gratitude to all the individuals who have already contributed to AFFiNE! If you have any AFFiNE-related project, documentation, tool or template, please feel free to contribute it by submitting a pull request to our curated list on GitHub: [awesome-affine](https://github.com/toeverything/awesome-affine).

<a href="https://github.com/toeverything/affine/graphs/contributors">
  <img alt="contributors" src="https://opencollective.com/affine/contributors.svg?width=890&button=false" />
</a>

## Self-Host

Begin with Docker to deploy your own feature-rich, unrestricted version of AFFiNE. Our team is diligently updating to the latest version. For more information on how to self-host AFFiNE, please refer to our [documentation](https://docs.affine.pro/self-host-affine).

Prefer to build the image yourself? Clone this repository and run a single `docker build` — no host toolchain required. See [building the self-host image from source](./docs/self-host/building-the-image.md). The image carries its own database and cache, so it also runs with nothing configured — see [running the self-host image](./docs/self-host/running-the-image.md).

[![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/toeverything/AFFiNE)

[![Run on Sealos](https://sealos.io/Deploy-on-Sealos.svg)](https://sealos.io/products/app-store/affine)

## Feature Request

For feature requests, please see [discussions](https://github.com/toeverything/AFFiNE/discussions/categories/ideas).

## Building

### Codespaces

From the GitHub repo main page, click the green "Code" button and select "Create codespace on master". This will open a new Codespace with the (supposedly auto-forked
AFFiNE repo cloned, built, and ready to go).

### Local

See [BUILDING.md] for instructions on how to build AFFiNE from source code.

## Contributing

We welcome contributions from everyone.
See [docs/contributing/tutorial.md](./docs/contributing/tutorial.md) for details.

## License

### Editions

- AFFiNE Community Edition (CE) is the current available version, it's free for self-host under the MIT license.

- AFFiNE Enterprise Edition (EE) is yet to be published, it will have more advanced features and enterprise-oriented offerings, including but not exclusive to rebranding and SSO, advanced admin and audit, etc., you may refer to https://affine.pro/pricing for more information

See [LICENSE] for details.

[all-contributors-badge]: https://img.shields.io/github/contributors/toeverything/AFFiNE
[license]: ./LICENSE
[building.md]: ./docs/BUILDING.md
[update page]: https://affine.pro/blog?tag=Release%20Note
[jobs available]: ./docs/jobs.md
[latest packages]: https://github.com/toeverything/AFFiNE/pkgs/container/affine-self-hosted
[contributor license agreement]: https://cla-assistant.io/toeverything/AFFiNE
[stars-icon]: https://img.shields.io/github/stars/toeverything/AFFiNE.svg?style=flat&logo=github&colorB=red&label=stars
[codecov]: https://codecov.io/gh/toeverything/affine/branch/canary/graphs/badge.svg?branch=canary
[typescript-version-icon]: https://img.shields.io/github/package-json/dependency-version/toeverything/affine/dev/typescript
[react-version-icon]: https://img.shields.io/github/package-json/dependency-version/toeverything/AFFiNE/react?filename=packages%2Ffrontend%2Fcore%2Fpackage.json&color=rgb(97%2C228%2C251)
[blocksuite-icon]: https://img.shields.io/github/package-json/dependency-version/toeverything/AFFiNE/@blocksuite/store?color=6880ff&filename=packages%2Ffrontend%2Fcore%2Fpackage.json&label=blocksuite
