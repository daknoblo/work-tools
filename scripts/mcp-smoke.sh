#!/usr/bin/env bash
# Assert that a Streamable HTTP MCP endpoint completes a handshake and offers the
# tools it is supposed to offer.
#
# Used by every tool's build pipeline and runnable by hand against the VPS.
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
usage: scripts/mcp-smoke.sh <url> <expected-tool> [expected-tool ...]

Runs initialize + tools/list against a Streamable HTTP MCP endpoint and fails
unless every expected tool is present.

Environment:
  MCP_BEARER      sent as an Authorization header
  MCP_SMOKE_CALL  tools/call params as JSON, e.g.
                  '{"name":"list_services","arguments":{}}'
                  Listing a tool only proves it was registered; calling one
                  proves the data it needs survived the build.
EOF
    exit 2
}

[[ $# -ge 2 ]] || usage
url=$1
shift
expected=("$@")

auth=()
if [[ -n ${MCP_BEARER:-} ]]; then
    auth=(-H "Authorization: Bearer ${MCP_BEARER}")
fi

headers=$(mktemp)
trap 'rm -f "$headers"' EXIT

# Streamable HTTP may answer a single request as one SSE event, so unwrap `data:` frames.
call() {
    local payload=$1
    shift
    local body
    body=$(curl -sS --max-time 30 -D "$headers" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' \
        "${auth[@]+"${auth[@]}"}" "$@" \
        -d "$payload" "$url") || true

    if grep -q '^data: ' <<<"$body"; then
        grep '^data: ' <<<"$body" | sed 's/^data: //' | tail -1
    else
        printf '%s' "$body"
    fi
}

init_payload='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"work-tools-smoke","version":"0"}}}'

init=$(call "$init_payload")
if ! server=$(printf '%s' "$init" | jq -er '.result.serverInfo.name' 2>/dev/null); then
    echo "initialize failed:" >&2
    printf '%s\n' "$init" >&2
    exit 1
fi
echo "initialize ok: ${server}"

# A stateful server hands out a session id here; a stateless one does not, and then
# tools/list has to stand on its own.
session=$(grep -i '^mcp-session-id:' "$headers" | tr -d '\r' | awk '{print $2}' || true)
session_header=()
if [[ -n $session ]]; then
    session_header=(-H "Mcp-Session-Id: ${session}")
    call '{"jsonrpc":"2.0","method":"notifications/initialized"}' "${session_header[@]}" >/dev/null
    echo "session: ${session}"
fi

listed=$(call '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' ${session_header[@]+"${session_header[@]}"})
if ! names=$(printf '%s' "$listed" | jq -er '.result.tools[].name' 2>/dev/null); then
    echo "tools/list failed:" >&2
    printf '%s\n' "$listed" >&2
    exit 1
fi

echo "tools offered:"
printf '%s\n' "$names" | sed 's/^/  /'

missing=()
for tool in "${expected[@]}"; do
    printf '%s\n' "$names" | grep -qx "$tool" || missing+=("$tool")
done

if [[ ${#missing[@]} -gt 0 ]]; then
    echo "missing expected tools: ${missing[*]}" >&2
    exit 1
fi

echo "all ${#expected[@]} expected tools present"

if [[ -n ${MCP_SMOKE_CALL:-} ]]; then
    called=$(printf '%s' "$MCP_SMOKE_CALL" | jq -er '.name')
    payload=$(jq -nc --argjson params "$MCP_SMOKE_CALL" \
        '{jsonrpc:"2.0", id:3, method:"tools/call", params:$params}')

    result=$(call "$payload" ${session_header[@]+"${session_header[@]}"})
    if ! printf '%s' "$result" | jq -e '.result.content | length > 0' >/dev/null 2>&1 ||
        printf '%s' "$result" | jq -e '.result.isError == true' >/dev/null 2>&1; then
        echo "tools/call ${called} did not return usable content:" >&2
        printf '%s\n' "$result" >&2
        exit 1
    fi
    echo "tools/call ${called} ok ($(printf '%s' "$result" | jq -r '.result.content[0].text // "" | length') chars)"
fi
