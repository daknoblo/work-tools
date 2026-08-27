# MarkItDown MCP server

Self-hosted build of the MCP server from
[microsoft/markitdown](https://github.com/microsoft/markitdown) (MIT). Upstream
ships a Dockerfile but publishes no image.

| | |
| --- | --- |
| Pipeline | [.github/workflows/tool-markitdown-mcp.yml](../../.github/workflows/tool-markitdown-mcp.yml) |
| Sync | [.github/workflows/sync-markitdown-mcp.yml](../../.github/workflows/sync-markitdown-mcp.yml) |
| Image | `ghcr.io/daknoblo/markitdown-mcp` |
| Vendored at | [vendor/markitdown](../../vendor/markitdown) |
| Container port | `3001`, path `/mcp/` |
| Tool | `convert_to_markdown(uri)` — one tool, reached as `markitdown_convert_to_markdown` |

Converts a document to Markdown from an `http://`, `https://`, `file://` or
`data:` URI. The `[all]` extra is installed, so PDF, DOCX, XLSX, PPTX, Outlook
messages, audio transcription and YouTube transcripts all work; `ffmpeg` and
`exiftool` are in the image because those extras are useless without them.

## Security

This is the part to read before exposing anything.

- **The server has no authentication.** Upstream is explicit: *"DO NOT bind the
  server to other interfaces unless you understand the security implications."*
  It is built to bind `0.0.0.0` here and is kept private by having no `ports:`
  entry — the compose network is the boundary, and the gateway's bearer token is
  the only check in front of it.
- **`file://` reads anything the process can read.** Inside the container that is
  a stock Python image and nothing else: no repository, no secrets, no host
  mounts. Do not add a bind mount to it without deciding that on purpose.
- **`http(s)://` fetches arbitrary URLs**, which is server-side request forgery
  by design — it is what the tool is for. It keeps egress so that converting a
  remote document works at all. Anyone who can reach the gateway can make the
  container fetch a URL, so the gateway token is what limits that to you.
- Plugins are disabled (`MARKITDOWN_ENABLE_PLUGINS=False`). Upstream's own image
  enables them; plugins are third-party code running in-process, and nothing here
  installs any.

## Why a first-party Dockerfile

Upstream's `packages/markitdown-mcp/Dockerfile` installs only the MCP wrapper and
lets pip resolve its `markitdown[all]` dependency from PyPI. The vendored core
would then never be what runs, which defeats mirroring the source at all.

[Dockerfile](Dockerfile) installs the vendored core first, so the wrapper's
dependency is already satisfied from this tree. The build pipeline asserts it:
the `markitdown` version reported by the image has to match
`vendor/markitdown/packages/markitdown/src/markitdown/__about__.py`, and the
build fails if pip fell back to PyPI.

Upstream's Dockerfile stays in `vendor/` as a reference.

## Versioning

The wrapper package still declares `0.0.1a5`, which says nothing about what
ships. Images are tagged with the **core library** version (`0.1.7`), which is
what upstream actually releases and tags.

The sync workflow follows upstream's published releases, which for this
repository track its tags one-to-one.

## Verifying a build by hand

```bash
docker run --rm -d --name md -p 127.0.0.1:3001:3001 ghcr.io/daknoblo/markitdown-mcp:latest

MCP_SMOKE_CALL='{"name":"convert_to_markdown","arguments":{"uri":"data:text/html;base64,PGgxPkhlbGxvPC9oMT4="}}' \
  scripts/mcp-smoke.sh http://127.0.0.1:3001/mcp/ convert_to_markdown

docker rm -f md
```

Mind the trailing slash. The MCP app is mounted at `/mcp/`, and `/mcp` answers
`307` — a redirect that neither curl nor the gateway's HTTP client follows, so
getting it wrong looks like a server that speaks no MCP at all.

Listing the tool only proves it registered; converting something proves the
`[all]` extra actually resolved.
