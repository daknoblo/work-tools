#!/usr/bin/env bash
# Capture edits made inside a vendored upstream tree as a patch file.
#
# vendor/ stays a verbatim upstream mirror so sync pull requests show a clean
# upstream diff. Local changes live in tools/<tool>/patches/ instead and are
# applied at build time.
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
usage: scripts/vendor-patch.sh <tool> <patch-name>

Writes your uncommitted edits under the tool's vendored tree to
tools/<tool>/patches/<patch-name>.patch, with paths relative to the vendored
root so the workflows can apply it with `git apply --directory`.

Restore the mirror afterwards:  git restore vendor/<repo>
EOF
    exit 2
}

[[ $# -eq 2 ]] || usage
tool=$1
name=$2

cd "$(git rev-parse --show-toplevel)"

config="tools/${tool}/upstream.json"
if [[ ! -f $config ]]; then
    echo "No such vendored tool: ${tool} (expected ${config})" >&2
    exit 1
fi

repository=$(jq -er '.repository' "$config")
vendor="vendor/${repository##*/}"
if [[ ! -d $vendor ]]; then
    echo "${vendor} has not been synced yet - run the sync workflow first." >&2
    exit 1
fi

out="tools/${tool}/patches/${name}.patch"
mkdir -p "$(dirname "$out")"
git diff --relative="$vendor" -- "$vendor" >"$out"

if [[ ! -s $out ]]; then
    rm -f "$out"
    echo "No uncommitted changes under ${vendor} - nothing to capture." >&2
    exit 1
fi

# A correct patch reverses cleanly out of the tree it was taken from.
if ! git apply --check --reverse --directory="$vendor" "$out"; then
    rm -f "$out"
    echo "Generated patch does not round-trip - refusing to write it." >&2
    exit 1
fi

echo "Wrote ${out}"
echo "Now run: git restore ${vendor}"
