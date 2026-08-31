# Deploying the stack

Three containers. Only the gateway is meant to be reached from outside, and it is
the only thing a client ever configures.

```
cloudflared ──▶ mcp-gateway ──┬──▶ azure-diagram-builder:3030   (docker_global)
                              └──▶ markitdown-mcp:3001        (private)
```

| Service | Networks | Authentication |
| --- | --- | --- |
| [mcp-gateway](../tools/mcp-gateway/README.md) | `docker_global` + private | `Authorization: Bearer $MCP_GATEWAY_TOKEN` |
| [azure-diagram-builder](../tools/azure-diagram-builder/README.md) | `docker_global` | `Bearer $DIAGRAMS_MCP_TOKEN` |
| [markitdown-mcp](../tools/markitdown-mcp/README.md) | private only | none — see below |

`docker_global` is the pre-existing shared network and is declared `external`, so
this stack expects it to be there rather than creating it.

**`markitdown-mcp` is deliberately not on it.** It has no authentication of any
kind, and its one tool fetches whatever `http(s)://` URL it is handed and returns
the body. On a network shared with everything else, that turns it into an open
request proxy for any container that can resolve its name — including toward
services that have no authentication of their own. Its own bearer-less-ness is
fine only because the sole thing that can reach it is the gateway, which does
authenticate.

The other two carry bearer tokens, so being on the shared network costs nothing:
an unauthenticated caller there gets a `401`.

No backend publishes a port.

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

## Four things in the compose file that look wrong and are not

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

**`markitdown-mcp` on its own network while everything else is on
`docker_global`.** Reachability is the only access control that service has, so
the gateway is the only thing given it. See the table at the top.

## Exposing it

The gateway sits on `docker_global`, so a reverse proxy or cloudflared already on
that network reaches it at `http://mcp-gateway:8000` with nothing bound on the
host. The `ports:` entry publishing `127.0.0.1:8090` is only there for a
cloudflared that runs on the host instead; drop it if yours is containerised.

```yaml
ingress:
  - hostname: tools.example.com
    service: http://mcp-gateway:8000
    originRequest:
      connectTimeout: 30s
      # MCP responses stream, so chunked encoding has to stay on.
      disableChunkedEncoding: false
  - service: http_status:404
```

Cloudflare returns **error 524** when an origin has not started responding within
100 seconds, on every plan below Enterprise, and it cannot be raised. The diagram
builder's tools are deterministic and answer in milliseconds; the only realistic
candidate is `markitdown_convert_to_markdown` on a large PDF or an audio file.
Once the server starts streaming the limit no longer applies — it bounds time to
first byte, not total duration.

Cloudflare Access adds a second, independent layer. It uses its own
`CF-Access-Client-Id` and `CF-Access-Client-Secret` headers, so it does not
collide with the gateway's `Authorization` header — provided you do **not**
enable Access's single-header mode, which would consume `Authorization` itself.
An Access policy protecting an MCP endpoint must use the **Service Auth** action;
any other action redirects to an identity-provider login that an MCP client
cannot complete. Avoid **Bypass**, which switches off logging entirely.

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

Confirm the unauthenticated backend is not reachable from the shared network:

```bash
docker run --rm --network docker_global alpine \
  sh -c 'apk add -q curl && curl -sS -o /dev/null -w "%{http_code}\n" --max-time 5 \
         http://markitdown-mcp:3001/mcp/'   # expect a failure to connect, not a 200
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
- **`config references ${DIAGRAMS_MCP_TOKEN}, which is not set`** — the variable
  reached compose but not the gateway container; check the `environment:` block.
- **Gateway healthy, tools missing** — a backend failed its handshake. The
  gateway logs one `mounted <name> -> <url>` line per backend at startup.
- **401 from the gateway** — wrong bearer. An HTML login page instead means
  Cloudflare Access is in front and its policy is not *Service Auth*.
- **`denied` on `docker compose pull`** — the GHCR packages are private; log in
  with a PAT that has `read:packages`.
