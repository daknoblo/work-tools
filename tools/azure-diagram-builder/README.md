# Azure Diagram Builder MCP server

Self-hosted build of the MCP server from
[Arturo-Quiroga-MSFT/azure-architecture-diagram-builder](https://github.com/Arturo-Quiroga-MSFT/azure-architecture-diagram-builder)
(MIT). Upstream publishes no image.

| | |
| --- | --- |
| Pipeline | [.github/workflows/tool-azure-diagram-builder.yml](../../.github/workflows/tool-azure-diagram-builder.yml) |
| Sync | [.github/workflows/sync-azure-diagram-builder.yml](../../.github/workflows/sync-azure-diagram-builder.yml) |
| Image | `ghcr.io/daknoblo/azure-diagram-builder` |
| Vendored at | [vendor/azure-architecture-diagram-builder](../../vendor/azure-architecture-diagram-builder) |
| Container port | `3030`, path `/mcp`, health `/healthz` |

Only the MCP server ships. Upstream is also a React web app with a token server
behind nginx and an Azure OpenAI integration; none of that is in this image.
Reached through the gateway, its tools carry the `diagrams_` prefix.

## What it can do without a single credential

All thirteen tools are deterministic — no LLM, and no outbound network calls at
all. Pricing, the service catalogue, WAF rules and all 714 Azure icons are
distilled into sidecar files at build time and read from disk at runtime.

| | |
| --- | --- |
| Catalogue | `list_services`, `get_waf_rules` |
| Review | `validate_architecture`, `harden_architecture` |
| Cost | `estimate_costs`, `compare_region_costs` |
| Generate | `generate_bicep`, `generate_terraform`, `generate_manifest`, `generate_deployment_guide` |
| Render / exchange | `render_diagram`, `export_reactflow_scene`, `import_architecture` |

That is what makes the MCP-only cut worthwhile: no `AZURE_OPENAI_ENDPOINT`, no
API key, no managed identity, nothing to leak. The web app's AI features are the
part that needed those, and they are not here.

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `MCP_AUTH_TOKEN` | unset | Bearer token. **Unset means the endpoint is open** |
| `MCP_HTTP_PORT` | `3030` | Listen port |
| `MCP_HTTP_HOST` | `0.0.0.0` | Bind address |
| `MCP_HTTP_PATH` | `/mcp` | Endpoint path |

`GET /healthz` and an unparameterised `GET /mcp` stay open for probes; the bearer
check runs ahead of any MCP handling, so a wrong token is a flat `401` rather
than a protocol error.

The transport is stateless — a fresh server instance per request, no session
affinity — which is what makes it well behaved behind the aggregating gateway.

## Building

The build context is the vendored repository root, not `mcp-server/`: upstream's
prebuild scripts read the web app's data as the single source of truth, which is
why [upstream.json](upstream.json) mirrors `src/data`,
`src/services/armExtractor.ts` and `Azure_Public_Service_Icons` alongside
`mcp-server/`.

```bash
docker build \
  -f vendor/azure-architecture-diagram-builder/mcp-server/Dockerfile \
  --build-arg NPM_REGISTRY=https://registry.npmjs.org/ \
  -t azure-diagram-builder vendor/azure-architecture-diagram-builder
```

That `--build-arg` is not optional: upstream's Dockerfile defaults
`NPM_REGISTRY` to a Microsoft-internal package proxy, which nothing outside
Microsoft can reach.

Beware that `npm ci` reports failure while still exiting `0` — it prints
`Exit handler never called!`, leaves empty package directories behind, and the
build only falls over later at `tsc`. The pipeline builds and smoke-tests the
image before it pushes anything, so a half-installed build can never move the
`latest` tag.

## Versioning

Images are tagged with the version in upstream's root `package.json`. The sync
workflow follows the newest upstream **tag**, not the newest release: upstream
tags every release but has published exactly one GitHub Release, so following
releases would pin the mirror many versions behind.

## Verifying a build by hand

```bash
docker run --rm -d --name adb -e MCP_AUTH_TOKEN=local -p 127.0.0.1:3030:3030 \
  ghcr.io/daknoblo/azure-diagram-builder:latest

curl -fsS http://127.0.0.1:3030/healthz

MCP_BEARER=local MCP_SMOKE_CALL='{"name":"list_services","arguments":{}}' \
  scripts/mcp-smoke.sh http://127.0.0.1:3030/mcp list_services render_diagram

docker rm -f adb
```

Calling a tool matters more than listing one: the pricing and icon sidecars are
generated during the build, and only a real call notices if they came out empty.
