# MCP gateway

The single endpoint every client adds. It mounts each backend behind one
authenticated Streamable HTTP endpoint and re-offers their tools under a
namespace, so adding a tool to the stack never means touching client config
again.

| | |
| --- | --- |
| Pipeline | [.github/workflows/tool-mcp-gateway.yml](../../.github/workflows/tool-mcp-gateway.yml) |
| Image | `ghcr.io/daknoblo/mcp-gateway` |
| Container port | `8000`, path `/mcp` |
| Built from | this repository — no upstream, nothing under `vendor/` |

Unlike the other tools here this one is ours, roughly forty lines on top of
[FastMCP](https://gofastmcp.com). The version that matters is therefore the
pinned FastMCP release in [requirements.txt](requirements.txt), which is also
recorded on the image as `io.workflow.fastmcp.version`.

## Why an aggregator and not a proxy

Most things called "MCP proxy" are transport bridges: they put each backend on
its own route (`/markitdown/mcp`, `/diagrams/mcp`), which still leaves one client
entry per backend. Aggregation means one endpoint whose tool list is the union of
all backends, which is what FastMCP's `create_proxy` plus `mount(namespace=...)`
gives.

Namespacing is not cosmetic: it is what allows two backends to expose a tool of
the same name.

| Backend | Tool | Seen by the client as |
| --- | --- | --- |
| `diagrams` | `list_services` | `diagrams_list_services` |
| `markitdown` | `convert_to_markdown` | `markitdown_convert_to_markdown` |
| `graphviz` | `generate_diagram` | `graphviz_generate_diagram` |

The current stack offers 17 tools this way: 13 under `diagrams`, 3 under
`graphviz`, 1 under `markitdown`. Which to reach for is covered in the
[repository README](../../README.md#which-tool-for-what).

Renaming a backend key in the config renames every tool it offers, which breaks
prompts and saved tool references. Treat those keys as API.

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `MCP_GATEWAY_TOKEN` | — | Bearer token clients must present. **Required**; the gateway exits without it |
| `MCP_GATEWAY_BACKENDS` | — | Backends as JSON, keyed by namespace. **Required** |
| `MCP_GATEWAY_NAME` | `work-tools` | Server name shown to clients |
| `MCP_GATEWAY_HOST` | `0.0.0.0` | Bind address inside the container |
| `MCP_GATEWAY_PORT` | `8000` | Listen port |
| `MCP_GATEWAY_PATH` | `/mcp` | Endpoint path |

The backend map is a JSON object whose keys are namespaces and whose values take
the same shape as an entry in any MCP client's `mcpServers`:

```json
{
  "diagrams": {
    "url": "http://azure-diagram-builder:3030/mcp",
    "transport": "http",
    "headers": { "Authorization": "Bearer ${DIAGRAMS_MCP_TOKEN}" }
  },
  "markitdown": {
    "url": "http://markitdown-mcp:3001/mcp/",
    "transport": "http"
  }
}
```

It is an environment variable rather than a file so that deploying is a compose
file and an `.env`, with nothing to copy onto the host beside them.

Any `${VAR}` inside it is resolved from the environment at startup, which keeps
backend credentials out of the map itself — the map can then live in the compose
file while the secrets stay in `.env`. A referenced variable that is not set is a
startup error, never an empty header.

Mind the trailing slash on `markitdown`: it serves at `/mcp/` and answers `/mcp`
with a `307` that the gateway's HTTP client does not follow.

See the `mcp-gateway` service in
[deploy/docker-compose.yml](../../deploy/docker-compose.yml) for the deployed
configuration.

## Adding a backend

1. Add an entry to `MCP_GATEWAY_BACKENDS` in
   [deploy/docker-compose.yml](../../deploy/docker-compose.yml), keyed by the
   namespace you want its tools to carry.
2. Add the service to the same file with no `ports:`, and add it to the gateway's
   `depends_on`.
3. `docker compose up -d`.

No client changes anywhere. The new tools appear on the next `tools/list`.

## Client configuration

VS Code (`.vscode/mcp.json`), with every secret prompted rather than committed:

```json
{
  "servers": {
    "work-tools": {
      "type": "http",
      "url": "https://tools.example.com/mcp",
      "headers": {
        "Authorization": "Bearer ${input:gateway-token}",
        "CF-Access-Client-Id": "${input:cf-id}",
        "CF-Access-Client-Secret": "${input:cf-secret}"
      }
    }
  },
  "inputs": [
    { "id": "gateway-token", "type": "promptString", "description": "MCP gateway token", "password": true },
    { "id": "cf-id", "type": "promptString", "description": "CF Access Client Id" },
    { "id": "cf-secret", "type": "promptString", "description": "CF Access Client Secret", "password": true }
  ]
}
```

Drop the two `CF-Access-*` headers if you are not fronting the tunnel with
Cloudflare Access.

## Authentication

A static bearer token, checked by FastMCP's `StaticTokenVerifier`. FastMCP's
documentation calls that verifier development-only because it stores tokens in
plain text and they never expire — which is precisely what a static bearer token
is, so the label describes the mechanism rather than a defect in this use. It is
one layer; Cloudflare Access in front of the tunnel is the other, and the two use
different headers.

Swap in `JWTVerifier` (HS256 shared secret) in
[src/gateway.py](src/gateway.py) if you want tokens that expire. Nothing else
changes.

On Streamable HTTP a session is bound to the credential that created it, so a
leaked session id is useless without the token that opened it.

## Cost of the extra hop

Proxying adds a round trip. FastMCP measures roughly 300–400 ms for a proxied
`tools/list` and 200–500 ms per proxied call, against 1–2 ms for a local one.
Backend tool lists are cached for 300 s, so the listing cost is paid once per
window rather than per request.

## Troubleshooting

- **Container exits at startup** — read the message: a missing
  `MCP_GATEWAY_TOKEN`, an unset `${VAR}` inside `MCP_GATEWAY_BACKENDS`, or a map
  that is empty or not valid JSON all stop the process deliberately.
- **A backend's tools are missing** — the gateway logs `mounted <name> -> <url>`
  per backend. If the line is there but the tools are not, the backend rejected
  the handshake; check its own auth.
- **Tool names changed** — someone renamed a key in `mcpServers`.
