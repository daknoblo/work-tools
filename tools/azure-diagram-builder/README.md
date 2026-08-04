# Azure Architecture Diagram Builder

Self-hosted build of [Arturo-Quiroga-MSFT/azure-architecture-diagram-builder](https://github.com/Arturo-Quiroga-MSFT/azure-architecture-diagram-builder)
(MIT). Upstream ships a `Dockerfile` but publishes no image, so this repository
builds one and pushes it to GHCR.

| | |
| --- | --- |
| Pipeline | [.github/workflows/tool-azure-diagram-builder.yml](../../.github/workflows/tool-azure-diagram-builder.yml) |
| Image | `ghcr.io/<owner>/azure-diagram-builder` |
| Container port | `80` (nginx) |
| Extra endpoint | `/mcp` (Model Context Protocol, streamable HTTP) |

## How configuration is split

The app is a Vite SPA, so anything the browser needs is compiled into the
bundle. That splits configuration in two:

- **Build time** — the list of Azure OpenAI *deployment names* the model picker
  offers, plus feature flags. These end up in public JavaScript, so they are
  supplied by a GitHub repository **variable**, not a secret. Changing them
  requires a rebuild.
- **Runtime** — the Azure OpenAI endpoint and API key, the MCP token, and other
  server-side settings. These stay on the VPS in `.env` and are never baked
  into the image.

## 1. Configure the build

Create the repository variable `AADB_BUILD_ENV`
(*Settings → Secrets and variables → Actions → Variables*) with one `KEY=VALUE`
per line. Only keys that map to a real deployment in your Azure OpenAI resource
should be listed — every entry becomes a selectable model in the UI.

```dotenv
VITE_AZURE_OPENAI_ENDPOINT=https://your-resource.openai.azure.com/
VITE_AZURE_OPENAI_DEPLOYMENT_GPT51=gpt-5.1
VITE_AZURE_OPENAI_DEPLOYMENT_GPT54=gpt-5.4
VITE_AZURE_OPENAI_DEPLOYMENT_GPT54MINI=gpt-5.4-mini
```

`VITE_AZURE_OPENAI_ENDPOINT` is only a flag telling the UI that AI is
configured; the real call is proxied server-side. The full list of supported
keys is in the upstream [`.env.example`](https://github.com/Arturo-Quiroga-MSFT/azure-architecture-diagram-builder/blob/main/.env.example).

The pipeline rejects values containing whitespace, because the upstream
`Dockerfile` sources this file through `xargs`.

Do not put an Azure OpenAI API key here. It would be shipped to every browser.

## 2. Build the image

The workflow runs:

- **manually** — *Actions → tool - azure-diagram-builder → Run workflow*, with
  optional inputs for the upstream ref (branch, tag or commit), an extra image
  tag, target platforms, and a build-only dry run;
- **weekly** (Mondays, 04:17 UTC) — rebuilds only when upstream `main` moved,
  by checking whether the `upstream-<sha>` tag already exists;
- **on push** to `main` when this tool's files or its workflow change.

Every run first builds the image locally and smoke-tests it — nginx must serve
the SPA, the static Azure icons must be present, and both Node processes (token
server, MCP server) must answer through nginx. Only then is the image pushed, so
a broken build can never move the `latest` tag your VPS pulls. This matters
because `npm ci` can report a failure while still exiting 0, which would
otherwise ship an image whose backend services are silently missing.

Every successful run publishes:

| Tag | Purpose |
| --- | --- |
| `latest` | Rolling tag for the VPS |
| `upstream-<sha>` | Exact upstream commit — use it to pin or roll back |
| `<YYYYMMDD>-<sha>` | Chronological history |
| custom | Whatever you passed as `image_tag` |

Images are pushed with an SBOM, `provenance=max`, and a signed build
provenance attestation:

```bash
gh attestation verify oci://ghcr.io/<owner>/azure-diagram-builder:latest --owner <owner>
```

First run only: after the initial push, open the package in GitHub → *Package
settings* and either keep it private (then `docker login ghcr.io` on the VPS
with a PAT that has `read:packages`) or make it public.

## 3. Run it on the VPS

```bash
mkdir -p /opt/azure-diagram-builder && cd /opt/azure-diagram-builder
curl -O https://raw.githubusercontent.com/<owner>/work-tools/main/tools/azure-diagram-builder/docker-compose.yml
curl -o .env https://raw.githubusercontent.com/<owner>/work-tools/main/tools/azure-diagram-builder/.env.example
# edit .env, then:
docker compose up -d
```

The container is published on `127.0.0.1:8080` only. Put a reverse proxy in
front of it for TLS **and authentication** — the app has none of its own, and
anyone who can reach it can spend your Azure OpenAI quota through
`/api/openai`.

Minimal Caddy example:

```caddy
diagrams.example.com {
    basicauth {
        you <bcrypt-hash>
    }
    reverse_proxy 127.0.0.1:8080
}
```

nginx needs `proxy_read_timeout 300s;` and `client_max_body_size 12m;` —
reasoning models take minutes and image import posts base64 payloads.

If you do not use the MCP server, block `/mcp` in the proxy. Otherwise set
`MCP_AUTH_TOKEN` in `.env`; without it the endpoint is unauthenticated.

## 4. Update

```bash
cd /opt/azure-diagram-builder
docker compose pull
docker compose up -d
docker image prune -f
```

To move to a specific build instead of `latest`, set `IMAGE_TAG=upstream-<sha>`
in `.env` and repeat. The same works for rolling back.

To pick up an upstream change immediately, run the workflow manually instead of
waiting for the weekly schedule.

## Feature availability when self-hosted

Upstream targets Azure Container Apps and uses managed identity for several
features. On a VPS:

| Feature | Works | Note |
| --- | --- | --- |
| Diagram generation, chat, WAF validation, deployment guides | yes | via `AZURE_OPENAI_API_KEY` |
| Cost estimation, exports (PNG/SVG/PPTX/VSDX/draw.io) | yes | client-side / public pricing API |
| MCP server at `/mcp` | yes | set `MCP_AUTH_TOKEN` |
| Avatar presenter / narration | no | needs an Azure Speech managed identity |
| Cloud sync, feedback storage | no | needs Cosmos DB with managed identity |
| Import from Azure | limited | needs a credential for the server identity |

## Troubleshooting

- **AI calls return 500/503** — `AZURE_OPENAI_ENDPOINT` is missing or the key is
  wrong. Check `docker compose logs azure-diagram-builder`.
- **Model picker is empty** — `AADB_BUILD_ENV` was empty at build time; set it
  and rebuild.
- **504 from the proxy** — raise the proxy read timeout, not a container issue.
- **`denied` on `docker compose pull`** — the GHCR package is private; log in
  with a PAT that has `read:packages`.
