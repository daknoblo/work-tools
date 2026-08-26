# Deploying the stack

Three containers on one compose network. Only the gateway is reachable from
outside it, and it is the only thing a client ever configures.

```
cloudflared ──▶ 127.0.0.1:8090 ──▶ mcp-gateway ──┬──▶ azure-diagram-builder:3030
                                                 └──▶ markitdown-mcp:3001
```

| Service | Published | Authentication |
| --- | --- | --- |
| [mcp-gateway](../tools/mcp-gateway/README.md) | `127.0.0.1:8090` | `Authorization: Bearer $MCP_GATEWAY_TOKEN` |
| [azure-diagram-builder](../tools/azure-diagram-builder/README.md) | no | `Bearer $DIAGRAMS_MCP_TOKEN`, gateway only |
| [markitdown-mcp](../tools/markitdown-mcp/README.md) | no | none — see its README |

The backends deliberately have no `ports:` entry. `markitdown-mcp` has no
authentication of its own and converts `file://` URIs, so the compose network is
the only thing keeping it private.

## Install

```bash
mkdir -p /opt/work-tools && cd /opt/work-tools
curl -O https://raw.githubusercontent.com/daknoblo/work-tools/main/deploy/docker-compose.yml
curl -O https://raw.githubusercontent.com/daknoblo/work-tools/main/deploy/gateway.config.json
curl -o .env https://raw.githubusercontent.com/daknoblo/work-tools/main/deploy/.env.example

# Two independent tokens; neither has a default.
sed -i "s/^MCP_GATEWAY_TOKEN=.*/MCP_GATEWAY_TOKEN=$(openssl rand -hex 32)/" .env
sed -i "s/^DIAGRAMS_MCP_TOKEN=.*/DIAGRAMS_MCP_TOKEN=$(openssl rand -hex 32)/" .env

docker compose up -d
```

`gateway.config.json` carries no secrets: `${DIAGRAMS_MCP_TOKEN}` is expanded by
the gateway at startup from the environment, so the file is safe to keep in git
and to copy around.

Both variables are declared `${VAR:?...}` in the compose file, so a missing token
stops the stack rather than starting an unauthenticated one.

## Verify

```bash
curl -sS http://127.0.0.1:8090/mcp \
  -H "Authorization: Bearer $MCP_GATEWAY_TOKEN" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}'
```

Or run the repository's own check against the deployed stack, which does the
handshake and asserts the tools are there:

```bash
MCP_BEARER=$MCP_GATEWAY_TOKEN scripts/mcp-smoke.sh \
  http://127.0.0.1:8090/mcp diagrams_list_services markitdown_convert_to_markdown
```

Confirm nothing else is exposed:

```bash
ss -ltnp | grep -E '8090|3030|3001'   # only 127.0.0.1:8090 should appear
```

## Exposing it

The gateway binds to loopback, so put your tunnel in front of it. With
cloudflared, point one hostname at `http://127.0.0.1:8090`. If cloudflared runs
in Docker, join it to the `work-tools_mcp` network and target
`http://mcp-gateway:8000` instead — then nothing is bound on the host at all,
and the `ports:` block can go.

MCP calls are long-lived: allow at least a 300 s read timeout on any proxy in
the path.

Cloudflare Access adds a second, independent layer. It uses its own
`CF-Access-Client-Id` and `CF-Access-Client-Secret` headers, so it does not
collide with the gateway's `Authorization` header — provided you do **not**
enable Access's single-header mode, which would consume `Authorization` itself.
An Access policy protecting an MCP endpoint must use the **Service Auth** action;
any other action redirects to an identity-provider login that an MCP client
cannot complete.

## Update

```bash
cd /opt/work-tools
docker compose pull && docker compose up -d
docker image prune -f
```

All three services track `latest` with `pull_policy: always`. To pin one, replace
its tag with a published version and repeat.

## Troubleshooting

- **Gateway container exits immediately** — `MCP_GATEWAY_TOKEN` is empty. It
  refuses to start rather than serve every backend unauthenticated.
- **`config references ${DIAGRAMS_MCP_TOKEN}, which is not set`** — the variable
  reached compose but not the gateway container; check the `environment:` block.
- **Gateway healthy, tools missing** — a backend failed its handshake. The
  gateway logs one `mounted <name> -> <url>` line per backend at startup.
- **401 from the gateway** — wrong bearer. An HTML login page instead means
  Cloudflare Access is in front and its policy is not *Service Auth*.
- **`denied` on `docker compose pull`** — the GHCR packages are private; log in
  with a PAT that has `read:packages`.
