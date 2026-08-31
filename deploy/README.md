# Deploying the stack

Three containers, all on the shared `docker_global` network. Only the gateway is
meant to be reached from outside, and it is the only thing a client ever
configures.

```
cloudflared ──▶ mcp-gateway ──┬──▶ azure-diagram-builder:3030
                              └──▶ markitdown-mcp:3001
```

| Service | Published | Authentication |
| --- | --- | --- |
| [mcp-gateway](../tools/mcp-gateway/README.md) | `127.0.0.1:8090` | `Authorization: Bearer $MCP_GATEWAY_TOKEN` |
| [azure-diagram-builder](../tools/azure-diagram-builder/README.md) | no | `Bearer $DIAGRAMS_MCP_TOKEN` |
| [markitdown-mcp](../tools/markitdown-mcp/README.md) | no | none |

`docker_global` is declared `external`, so this stack expects it to exist rather
than creating it.

The backends publish nothing. They are reached by service name from the gateway,
and the gateway's own port is bound to loopback, so the only route in is whatever
tunnel you put in front of it.

`markitdown-mcp` has no authentication of any kind and its one tool fetches
whatever `http(s)://` URL it is handed. That is tolerable here because every
container able to reach it is already on `docker_global` and could make the same
request itself — it is not a step up from anywhere. It stops being tolerable the
moment something with a narrower network view can reach it, so do not publish a
port for it or give it a hostname of its own.

## Install

```bash
mkdir -p /opt/work-tools && cd /opt/work-tools
curl -O https://raw.githubusercontent.com/daknoblo/work-tools/main/deploy/docker-compose.yml
curl -o .env https://raw.githubusercontent.com/daknoblo/work-tools/main/deploy/.env.example

# Two independent tokens; neither has a default.
sed -i "s/^MCP_GATEWAY_TOKEN=.*/MCP_GATEWAY_TOKEN=$(openssl rand -hex 32)/" .env
sed -i "s/^DIAGRAMS_MCP_TOKEN=.*/DIAGRAMS_MCP_TOKEN=$(openssl rand -hex 32)/" .env

docker compose up -d
```

Two files on the host and nothing else. Which backends to aggregate is
`MCP_GATEWAY_BACKENDS` in the compose file, so there is no third file to keep in
sync with it.

That map carries no secrets. The `$$` in front of `${DIAGRAMS_MCP_TOKEN}` stops
compose from substituting it, so the container receives a literal placeholder
that the gateway resolves at startup — the token travels only in its own
variable.

Both variables are declared `${VAR:?...}` in the compose file, so a missing token
stops the stack rather than starting an unauthenticated one.

## Three things in the compose file that look wrong and are not

The file carries no comments, so they are recorded here instead.

**`$$` in front of `${DIAGRAMS_MCP_TOKEN}`.** Not a typo. A single `$` would make
compose substitute the token into `MCP_GATEWAY_BACKENDS`, where it would then sit
in `docker inspect` output and in `docker compose config`. Doubled, the container
receives a literal placeholder and the gateway resolves it at startup.

**The trailing slash on `markitdown-mcp:3001/mcp/`.** Its MCP app is mounted at
`/mcp/` and answers `/mcp` with a `307`, which the gateway's HTTP client does not
follow. Without the slash the backend simply appears to speak no MCP.

**`read_only` on two services but not on `azure-diagram-builder`.** That one is
an upstream image whose write behaviour is not ours to assume; the other two are
built in this repository, so their filesystem access is known.

## Exposing it

One hostname, pointed at the gateway. The backends never appear in any tunnel
configuration — they are reached by service name from inside `docker_global`.

cloudflared runs as a binary on the host, so it reaches the gateway through the
published loopback port. In `/etc/cloudflared/config.yml`:

```yaml
tunnel: work-tools
credentials-file: /root/.cloudflared/<tunnel-id>.json

ingress:
  - hostname: tools.example.com
    service: http://127.0.0.1:8090
    originRequest:
      connectTimeout: 30s
      # MCP responses stream, so chunked encoding has to stay on.
      disableChunkedEncoding: false
  - service: http_status:404
```

```bash
cloudflared tunnel create work-tools
cloudflared tunnel route dns work-tools tools.example.com
systemctl restart cloudflared
```

That loopback port is the only reason the gateway has a `ports:` entry at all. A
cloudflared container on `docker_global` would target `http://mcp-gateway:8000`
instead, and the entry could go.

Cloudflare returns **error 524** when an origin has not started responding within
100 seconds, on every plan below Enterprise, and it cannot be raised. The diagram
builder's tools are deterministic and answer in milliseconds; the only realistic
candidate is `markitdown_convert_to_markdown` on a large PDF or an audio file.
Once the server starts streaming the limit no longer applies — it bounds time to
first byte, not total duration.

Access is optional here: the gateway already requires a bearer token, and the VPS
has no other way in. If you do add it, it uses its own `CF-Access-Client-Id` and
`CF-Access-Client-Secret` headers and does not collide with `Authorization` —
provided you do **not** enable Access's single-header mode, which would consume
`Authorization` itself. An Access policy protecting an MCP endpoint must use the
**Service Auth** action; any other action redirects to an identity-provider login
that an MCP client cannot complete. Avoid **Bypass**, which switches off logging
entirely.

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

Confirm the backends are not published on the host:

```bash
ss -ltnp | grep -E '3030|3001' || echo 'backends bind nothing on the host'
```

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
- **`MCP_GATEWAY_BACKENDS references ${DIAGRAMS_MCP_TOKEN}, which is not set`** —
  the variable reached compose but not the gateway container; check the
  `environment:` block.
- **Gateway healthy, tools missing** — a backend failed its handshake. The
  gateway logs one `mounted <name> -> <url>` line per backend at startup.
- **401 from the gateway** — wrong bearer. An HTML login page instead means
  Cloudflare Access is in front and its policy is not *Service Auth*.
- **`network docker_global declared as external, but could not be found`** — the
  shared network does not exist yet: `docker network create docker_global`.
- **`denied` on `docker compose pull`** — the GHCR packages are public, so this
  means the tag is wrong rather than that you need credentials.
