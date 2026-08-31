# Azure diagram renderer (Graphviz)

Renders Azure diagrams from the Python [`diagrams`](https://diagrams.mingrammer.com)
DSL and hands the PNG back inline.

| | |
| --- | --- |
| Pipeline | [.github/workflows/tool-azure-diagram-graphviz.yml](../../.github/workflows/tool-azure-diagram-graphviz.yml) |
| Image | `ghcr.io/daknoblo/azure-diagram-graphviz` |
| Container port | `3002`, path `/mcp` |
| Namespace at the gateway | `graphviz` |

| Tool | Purpose |
| --- | --- |
| `generate_diagram` | Python `diagrams` code in, PNG out |
| `get_diagram_examples` | Example code per diagram type |
| `list_icons` | Available Azure icons and their import paths |

## Not the same thing as the diagram builder

`azure-diagram-builder` also has a `render_diagram`, and the two are easy to
confuse. They take opposite inputs:

| | this tool | `diagrams_render_diagram` |
| --- | --- | --- |
| Input | Python `diagrams` code | `{services, connections}` JSON |
| Output | PNG (Graphviz) | SVG or HTML |
| Good for | drawing something you describe in code | visualising an architecture the other tools produced |

## Why it lives here rather than under vendor/

It began as [dminkovski/azure-diagram-mcp](https://github.com/dminkovski/azure-diagram-mcp)
(MIT) at commit `3a2ce9b`, but that repository has not moved since 2025-09-29 and
has a single tag behind its own default branch. The copy here had already
diverged by roughly 290 lines before it arrived, and both changes below are ours
as well.

Mirroring it would mean a weekly check on a dormant repository plus a permanent
patch stack rebuilding what is already the better version. So it is maintained
here, with the origin recorded in `io.workflow.origin.*` on the image.

## The two changes that made it usable remotely

**Transport.** Upstream calls `mcp.run()` with no argument, which is stdio only.
`MCP_TRANSPORT=streamable-http` now selects the HTTP transport.

Host and port are passed to the `FastMCP` constructor rather than left to the
`FASTMCP_*` environment variables. Those are silently ignored here:
pydantic-settings cannot resolve this model's env source — it warns about an
unresolved forward reference on `lifespan` — and falls back to `127.0.0.1:8000`,
which inside a container means the server answers nobody. That was verified by
watching it bind the wrong port.

**The result.** `generate_diagram` used to return a filesystem path. A path
inside this container is meaningless to a caller on another machine, and mounting
a workspace does not help — the client still cannot open it. The tool now returns
the message plus an `image/png` content block, so the diagram travels with the
reply. The pipeline asserts that block is present on every build.

| Variable | Default | Purpose |
| --- | --- | --- |
| `MCP_TRANSPORT` | `stdio` | `streamable-http` for container use |
| `MCP_HTTP_HOST` | `127.0.0.1` | Bind address |
| `MCP_HTTP_PORT` | `3002` | Listen port |
| `MCP_HTTP_PATH` | `/mcp` | Endpoint path |
| `MCP_STATELESS_HTTP` | `true` | No session affinity, which suits sitting behind the gateway |

## Verifying a build by hand

```bash
docker run --rm -d --name gv -p 127.0.0.1:3002:3002 ghcr.io/daknoblo/azure-diagram-graphviz:latest

MCP_SMOKE_CALL='{"name":"generate_diagram","arguments":{"code":"with Diagram(\"t\"):\n    AppServices(\"web\") >> SQLDatabases(\"db\")"}}' \
  scripts/mcp-smoke.sh http://127.0.0.1:3002/mcp generate_diagram get_diagram_examples list_icons

docker rm -f gv
```

Graphviz is an apt package, not a Python one. Without it every render fails at
the point of drawing, which is why the smoke test draws something real rather
than settling for a tool listing.
