# The single MCP endpoint every client talks to. Unlike the other tools here this one
# is first-party, so there is nothing under vendor/ for it.
#
#   docker build -f tools/mcp-gateway/Dockerfile tools/mcp-gateway

FROM python:3.13-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

COPY requirements.txt /tmp/requirements.txt
RUN pip --no-cache-dir install -r /tmp/requirements.txt && rm /tmp/requirements.txt

# Turns an API change in a FastMCP bump into a build failure rather than a crash loop
# on the VPS.
RUN python -c "\
from fastmcp import FastMCP; \
from fastmcp.server import create_proxy; \
from fastmcp.server.auth.providers.jwt import StaticTokenVerifier"

COPY src/gateway.py /app/gateway.py

USER nobody:nogroup

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD python -c "import socket; socket.create_connection(('127.0.0.1', 8000), 3).close()"

CMD ["python", "/app/gateway.py"]
