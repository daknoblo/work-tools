"""Minimal MCP backend for the gateway smoke test.

Real backends are heavy images; proving that the gateway mounts, namespaces and
proxies a backend needs nothing more than one tool that answers.
"""

from fastmcp import FastMCP

stub = FastMCP(name="stub")


@stub.tool
def ping() -> str:
    """Return a fixed string the gateway smoke test can assert on."""
    return "pong"


if __name__ == "__main__":
    stub.run(transport="http", host="0.0.0.0", port=9000, path="/mcp")
