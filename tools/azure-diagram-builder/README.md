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

## What each tool does

They are built to chain rather than to be used one at a time: almost all of them
take or return the same `{services, connections, groups}` object, so one tool's
output is the next one's input.

| Tool | What it does |
| --- | --- |
| `list_services` | The catalogue — names, categories, aliases, whether pricing data exists, cost ranges. Start here to learn which service names the other tools accept. |
| `get_waf_rules` | The rule base behind the review: architecture-wide patterns plus per-service best practices, filterable by WAF pillar. |
| `validate_architecture` | Scores the architecture 0-100 against the Well-Architected Framework, with findings grouped by pillar and concrete recommendations. |
| `harden_architecture` | Fixes the findings a *diagram* can express, then re-validates. Deliberately conservative: it will not invent a database replica without a target, and Front Door alone does not clear a single-region finding — pass `secondaryRegion` to resolve those for real. |
| `estimate_costs` | Monthly fixed-price baseline with low/expected/high, what was excluded and why, and which region the numbers actually came from. Not a total: usage-based services are left out by design. |
| `compare_region_costs` | The same architecture priced across 2-14 regions with quantities and tiers held identical. Ranks only when every region has native data — never a heuristic multiplier. |
| `generate_bicep` | Deployable Bicep with secure defaults already set (HTTPS-only, TLS 1.2, managed identity, Key Vault purge protection, …) plus a map of which WAF finding each setting resolves. |
| `generate_terraform` | The same for Terraform (`azurerm`), including resource group and provider block. |
| `generate_manifest` | The `az prototype` interchange manifest — the format the web app and `az prototype build` read. |
| `generate_deployment_guide` | A Markdown runbook: prerequisites, login, IaC commands, a post-deploy hardening checklist derived from the findings, per-service smoke tests, teardown. |
| `render_diagram` | SVG for embedding in documents, or self-contained interactive HTML with pan, zoom and tooltips. Label every connection with a short phrase saying what flows and why — that is what makes the picture readable. |
| `export_reactflow_scene` | A React Flow scene the Diagram Builder web app opens directly. |
| `import_architecture` | The way *in*. Reads an interchange manifest, a React Flow scene, or an **ARM template / `az group export`** and normalises it into the canonical shape. |

The last one is easy to overlook and is the most useful entry point: point it at
an exported resource group and you can validate, cost, harden and render an
architecture that already exists, without describing it by hand first.

Nothing here deploys. `generate_bicep`, `generate_terraform` and
`generate_deployment_guide` all stop at producing text.

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
