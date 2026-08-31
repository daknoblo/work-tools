# Copyright (c) Microsoft Corporation. All rights reserved.
"""azure-diagram-mcp-server implementation.

This server provides tools to generate diagrams using the Python diagrams package, focused on Microsoft Azure services and architecture only.
It accepts Python code as a string and generates PNG diagrams without displaying them.
"""

from azure_diagram_mcp_server.diagrams_tools import (
    generate_diagram,
    get_diagram_examples,
    list_diagram_icons,
)
from azure_diagram_mcp_server.models import DiagramType
from mcp.server.fastmcp import FastMCP, Image
from mcp.types import TextContent
from pydantic import Field
from typing import Optional
import os
import sys

# Create the MCP server
#
# Host and port are passed explicitly rather than left to the FASTMCP_* environment
# variables: pydantic-settings fails to resolve this model's env source (it warns about
# an unresolved forward reference on `lifespan`) and silently falls back to 127.0.0.1:8000,
# which in a container means the server answers nobody.
mcp = FastMCP(
    'azure-diagram-mcp-server',
    host=os.environ.get('MCP_HTTP_HOST', '127.0.0.1'),
    port=int(os.environ.get('MCP_HTTP_PORT', '3002')),
    streamable_http_path=os.environ.get('MCP_HTTP_PATH', '/mcp'),
    stateless_http=os.environ.get('MCP_STATELESS_HTTP', 'true').lower() == 'true',
    dependencies=[
        'pydantic',
        'diagrams',
    ],
    log_level='ERROR',
    instructions="""Use this server to generate professional diagrams using the Python diagrams package, focused on Microsoft Azure.

WORKFLOW:
1. list_icons:
   - Discover all available icons in the diagrams package
   - Browse providers, services and icons organized hierarchically
   - Find the exact import paths for the icons you want to use
   - Providers: azure, k8s, onprem, generic, programming
   - provider_filter and service_filter narrow the listing to one area; omit both to browse everything

2. get_diagram_examples:
   - Request example code for the diagram type you need (azure, sequence, flow, class, k8s, onprem, custom, or all)
   - Study the examples to understand the diagram package's syntax and Azure capabilities
   - Use these examples as templates for your own Azure diagrams
   - Each example demonstrates different Azure features and diagram structures

3. generate_diagram:
   - Write Python code using the diagrams package DSL based on the Azure examples
   - Submit your code to generate a PNG diagram
   - Optionally specify a filename
   - The diagram is generated with show=False to prevent automatic display
   - The PNG comes back inline with the reply, so there is no path for you to open:
     this server may be running on a different machine than you are
   - Every icon of the listed providers is already in scope, so an unimported name still resolves.
     Write the explicit imports anyway: the code is saved next to the PNG as diagram_code.py and
     should run on its own. Where a name exists in several providers, Azure wins.
   - The `with Diagram(...)` call may span multiple lines; filename and show=False are injected for you
   - On failure the message carries the failing line number and source line — fix that line instead of
     rewriting the diagram
"""
)

@mcp.tool(name='generate_diagram')
async def mcp_generate_diagram(
    code: str = Field(..., description='Python code using the diagrams package DSL'),
    filename: Optional[str] = Field(None, description='Output filename (without extension)'),
    timeout: int = Field(90, description='Timeout in seconds for diagram generation'),
):
    """Generate a diagram from Python code using the diagrams package.

    Azure, generic, k8s, onprem and programming icons are all in scope, so this draws
    anything from an Azure architecture to a plain flowchart.
    """
    result = await generate_diagram(code, filename, timeout)
    if result.status != 'success' or not result.path:
        return result

    # A path is useless to a caller on another machine, so the PNG travels with the reply.
    return [
        TextContent(type='text', text=result.message),
        Image(path=result.path).to_image_content(),
    ]

@mcp.tool(name='get_diagram_examples')
async def mcp_get_diagram_examples(
    diagram_type: str = Field('all', description='Type of diagram example to return'),
):
    """Get example code for different types of diagrams."""
    return get_diagram_examples(DiagramType(diagram_type))

@mcp.tool(name='list_icons')
async def mcp_list_diagram_icons(
    provider_filter: Optional[str] = Field(None, description='Filter icons by provider name'),
    service_filter: Optional[str] = Field(None, description='Filter icons by service name'),
):
    """List available icons from the diagrams package."""
    return list_diagram_icons(provider_filter, service_filter)

def main():
    """Main entry point for the MCP server."""
    transport = os.environ.get('MCP_TRANSPORT', 'stdio')
    # stdout carries the JSON-RPC stream, so status output must go to stderr
    print(f'Azure Diagram MCP server is running ({transport}).', file=sys.stderr)
    mcp.run(transport=transport)

if __name__ == "__main__":
    main()
