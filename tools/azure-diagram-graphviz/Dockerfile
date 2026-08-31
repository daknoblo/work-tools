# Renders diagrams with the Python `diagrams` DSL, which shells out to Graphviz - hence
# the apt package. Without it every generate_diagram call fails at render time.
#
#   docker build -f tools/azure-diagram-graphviz/Dockerfile tools/azure-diagram-graphviz

FROM python:3.13-slim

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends graphviz \
    && rm -rf /var/lib/apt/lists/*

COPY pyproject.toml LICENSE ./
COPY azure_diagram_mcp_server ./azure_diagram_mcp_server

RUN pip --no-cache-dir install . \
    && python -c "import diagrams, azure_diagram_mcp_server.server"

COPY LICENSE /licenses/

ENV MCP_TRANSPORT=streamable-http \
    MCP_HTTP_HOST=0.0.0.0 \
    MCP_HTTP_PORT=3002 \
    MCP_HTTP_PATH=/mcp

# Diagrams are written here before being read back as inline image content, and the
# runtime filesystem is read-only.
WORKDIR /tmp

USER nobody:nogroup

EXPOSE 3002

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import socket; socket.create_connection(('127.0.0.1', 3002), 3).close()"

CMD ["azure-diagram-mcp-server"]
