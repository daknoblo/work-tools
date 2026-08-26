# MarkItDown MCP server, built from the tree mirrored under vendor/markitdown.
#
# Upstream's own packages/markitdown-mcp/Dockerfile installs only the MCP wrapper and
# lets pip pull the markitdown core from PyPI, which would mean the vendored core is
# never what runs. Installing the local core first satisfies the wrapper's
# `markitdown[all]` dependency from this tree instead.
#
# Build context is the vendored repository root:
#   docker build -f tools/markitdown-mcp/Dockerfile vendor/markitdown

FROM python:3.13-slim-bullseye

ENV DEBIAN_FRONTEND=noninteractive \
    EXIFTOOL_PATH=/usr/bin/exiftool \
    FFMPEG_PATH=/usr/bin/ffmpeg \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# ffmpeg backs audio conversion, exiftool image metadata; both are needed for the
# [all] extra to actually work rather than fail at conversion time.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg exiftool \
    && rm -rf /var/lib/apt/lists/*

COPY packages/markitdown /src/markitdown
COPY packages/markitdown-mcp /src/markitdown-mcp

RUN pip --no-cache-dir install "/src/markitdown[all]" /src/markitdown-mcp \
    && python -c "import markitdown, markitdown_mcp; print(markitdown.__version__)"

# Plugins are third-party code executed in-process; nothing here installs any, and a
# server reachable from the gateway should not start loading them if one appears.
ENV MARKITDOWN_ENABLE_PLUGINS=False

# Conversions of remote URIs land here, and the runtime filesystem is read-only.
WORKDIR /tmp

USER nobody:nogroup

EXPOSE 3001

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import socket; socket.create_connection(('127.0.0.1', 3001), 3).close()"

# Binding to 0.0.0.0 is what upstream warns against, and rightly so: this server has no
# authentication and converts file:// URIs. It is only ever reachable on the internal
# compose network, with the gateway as the single authenticated entry point.
CMD ["markitdown-mcp", "--http", "--host", "0.0.0.0", "--port", "3001"]
