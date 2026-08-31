"""Aggregate the work-tools MCP backends behind one authenticated endpoint.

Clients add this server once; every backend's tools arrive namespaced as
``<backend>_<tool>``, so adding a tool to the stack never touches client config.

The backend map arrives as JSON in MCP_GATEWAY_BACKENDS rather than as a file, so
deploying is a compose file and an .env and nothing else.
"""

from __future__ import annotations

import json
import os
import re
import sys
from typing import Any

from fastmcp import FastMCP
from fastmcp.server import create_proxy
from fastmcp.server.auth.providers.jwt import StaticTokenVerifier

PLACEHOLDER = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")


def expand(value: Any) -> Any:
    """Resolve ${VAR} references so backend credentials stay out of the backend map."""

    def substitute(match: re.Match[str]) -> str:
        name = match.group(1)
        resolved = os.environ.get(name)
        if not resolved:
            raise SystemExit(f"MCP_GATEWAY_BACKENDS references ${{{name}}}, which is not set")
        return resolved

    if isinstance(value, str):
        return PLACEHOLDER.sub(substitute, value)
    if isinstance(value, dict):
        return {key: expand(item) for key, item in value.items()}
    if isinstance(value, list):
        return [expand(item) for item in value]
    return value


def load_backends() -> dict[str, Any]:
    raw = os.environ.get("MCP_GATEWAY_BACKENDS", "").strip()
    if not raw:
        raise SystemExit("MCP_GATEWAY_BACKENDS is required")

    try:
        backends = json.loads(raw)
    except json.JSONDecodeError as error:
        raise SystemExit(f"MCP_GATEWAY_BACKENDS is not valid JSON: {error}") from error

    if not isinstance(backends, dict) or not backends:
        raise SystemExit(
            'MCP_GATEWAY_BACKENDS must be a non-empty JSON object keyed by namespace, '
            'e.g. {"markitdown": {"url": "http://markitdown-mcp:3001/mcp/", "transport": "http"}}'
        )

    return expand(backends)


def main() -> None:
    token = os.environ.get("MCP_GATEWAY_TOKEN", "").strip()
    if not token:
        # Refusing to start beats quietly publishing every backend unauthenticated.
        raise SystemExit("MCP_GATEWAY_TOKEN is required")

    backends = load_backends()

    gateway = FastMCP(
        name=os.environ.get("MCP_GATEWAY_NAME", "work-tools"),
        auth=StaticTokenVerifier(
            tokens={token: {"client_id": "work-tools", "scopes": ["mcp"]}},
        ),
    )

    for name, backend in backends.items():
        # One proxy per backend keeps each backend's own credentials with it, and the
        # namespace is what lets two backends offer a tool of the same name.
        gateway.mount(create_proxy({"mcpServers": {"default": backend}}), namespace=name)
        print(f"mounted {name} -> {backend.get('url') or backend.get('command')}", file=sys.stderr)

    gateway.run(
        transport="http",
        host=os.environ.get("MCP_GATEWAY_HOST", "0.0.0.0"),
        port=int(os.environ.get("MCP_GATEWAY_PORT", "8000")),
        path=os.environ.get("MCP_GATEWAY_PATH", "/mcp"),
    )


if __name__ == "__main__":
    main()
