# work-tools

Personal collection of self-hosted MCP servers, built here and published to
GitHub Container Registry so they can run on my VPS with docker compose.

Everything is reached through **one** MCP endpoint. Clients add the gateway once;
the tools behind it can come and go without touching client configuration.

```
client ──▶ mcp-gateway ──┬──▶ azure-diagram-builder
                         └──▶ markitdown-mcp
```

## Tools

| Tool | Image | Upstream | Docs |
| --- | --- | --- | --- |
| MCP gateway | `ghcr.io/daknoblo/mcp-gateway` | first-party | [docs](tools/mcp-gateway/README.md) |
| Azure Diagram Builder | `ghcr.io/daknoblo/azure-diagram-builder` | [Arturo-Quiroga-MSFT/azure-architecture-diagram-builder](https://github.com/Arturo-Quiroga-MSFT/azure-architecture-diagram-builder) | [docs](tools/azure-diagram-builder/README.md) |
| MarkItDown | `ghcr.io/daknoblo/markitdown-mcp` | [microsoft/markitdown](https://github.com/microsoft/markitdown) | [docs](tools/markitdown-mcp/README.md) |

Deployment for all three: [deploy/README.md](deploy/README.md).

## Layout

```
.github/workflows/sync-<tool>.yml   mirror an upstream, weekly + on demand
.github/workflows/tool-<name>.yml   build and publish one image
tools/<name>/                       upstream.json, patches/, README, first-party sources
vendor/<upstream-repo>/             verbatim upstream mirror, never edited by hand
deploy/                             the compose stack for the VPS
scripts/                            vendor-sync, vendor-patch, mcp-smoke
```

`vendor/` is named after upstream repositories, `tools/` after the images we
publish. They do not always match: `tools/markitdown-mcp` builds from
`vendor/markitdown`.

## How upstream code gets here

Third-party source is **mirrored into this repository** rather than fetched
during a build. A build therefore depends on nothing but one commit of this
repository, and an upstream change is a reviewable diff before it is an image.

[scripts/vendor-sync.sh](scripts/vendor-sync.sh) does the mirroring; the sync
workflow only calls it, so the same thing happens locally and in CI:

```bash
scripts/vendor-sync.sh markitdown-mcp          # follow the tool's track setting
scripts/vendor-sync.sh markitdown-mcp v0.1.6   # or pin a specific ref
```

Each tool's `upstream.json` declares where it comes from and how far it follows:

| Field | Purpose |
| --- | --- |
| `repository` | `owner/name` on GitHub |
| `ref` | What is currently vendored; the sync updates it |
| `track` | `pinned`, `latest-release`, or `latest-tag` |
| `include` | Optional allowlist of paths to mirror |

`track` is per tool because upstreams differ: MarkItDown publishes a release for
every tag, while the diagram builder tags constantly and has published exactly
one release — following releases there would freeze the mirror nine versions
back.

`include` exists because mirroring is not free. The diagram builder's full tree
is 356 MB, most of it the author's own generated artefacts; restricted to the
paths its build actually reads it is 113 MB. Git never forgets a blob, so this is
worth getting right the first time. A path that disappears upstream fails the
sync loudly instead of quietly shrinking the mirror.

The mirror stays verbatim. Local changes live in `tools/<tool>/patches/` and are
applied at build time, so a sync diff only ever shows upstream's changes:

```bash
# edit files under vendor/<repo>/ as usual, then
scripts/vendor-patch.sh <tool> <patch-name>
git restore vendor/<repo>
```

A patch that stops applying fails the sync rather than rotting silently. There
are none at the moment.

## Conventions

Builds are independent — one workflow, one image per tool, nothing shared, so a
broken build never blocks another tool. Deployment is the opposite: one stack,
because neither backend is useful or safe on its own.

Every pipeline:

- is named `tool - <name>` in `tool-<name>.yml`, with workflow-level `concurrency`;
- runs on `workflow_dispatch` and on pushes touching its own files or its mirror;
- builds the image and smoke-tests it **before** pushing, so a broken build can
  never move the `latest` tag the VPS pulls;
- builds `linux/amd64` and `linux/arm64` on runners of that architecture, so both
  are smoke-tested for real rather than emulated, then joins them into one
  manifest — a half-finished matrix never gets a tag;
- publishes `latest` plus whatever version the upstream declares — no invented
  version numbers;
- pushes with SBOM, provenance and a build provenance attestation;
- keeps runtime secrets out of the image entirely.

The smoke tests call a tool rather than only listing one.
[scripts/mcp-smoke.sh](scripts/mcp-smoke.sh) does the handshake and the
assertions, and works just as well against the deployed stack.

## Adding a tool

For an upstream MCP server:

1. `tools/<name>/upstream.json` with `repository`, `ref`, `track` and, if the
   tree is large, `include`.
2. `scripts/vendor-sync.sh <name>` to populate `vendor/`.
3. Copy `sync-markitdown-mcp.yml` and `tool-markitdown-mcp.yml`, adjusting the
   tool name, vendor directory and expected tools.
4. Add the service to [deploy/docker-compose.yml](deploy/docker-compose.yml) with
   no `ports:`, and a namespaced entry to
   [deploy/gateway.config.json](deploy/gateway.config.json).
5. Add it to the table above with a `README.md`.

Nothing on any client changes — that is the point of the gateway.

## Verifying a published image

```bash
gh attestation verify oci://ghcr.io/daknoblo/<image>:latest --owner daknoblo

docker buildx imagetools inspect ghcr.io/daknoblo/<image>:latest \
  --format '{{ json .Image }}' | grep -E 'image\.(version|revision)'
```

The upstream commit an image was built from is in its labels rather than in a
tag.
