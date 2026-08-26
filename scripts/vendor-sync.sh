#!/usr/bin/env bash
# Mirror a third-party repository into vendor/ at the ref the tool asks for.
#
# Runs identically locally and in .github/workflows/sync-upstream.yml, so the
# vendored tree can be refreshed by hand without guessing what CI would do.
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
usage: scripts/vendor-sync.sh <tool> [ref]

Mirrors the upstream named in tools/<tool>/upstream.json into vendor/<repo>/ and
records the resolved commit in vendor/<repo>/UPSTREAM.json.

Without <ref>, the tool's "track" setting decides which ref to use:

  pinned          stay on "ref" until it is changed by hand
  latest-release  newest published GitHub release
  latest-tag      newest git tag by version sort

An "include" list limits the mirror to those paths; without one the whole
upstream tree is mirrored.
EOF
    exit 2
}

[[ $# -ge 1 && $# -le 2 ]] || usage
tool=$1
ref_input=${2-}

cd "$(git rev-parse --show-toplevel)"

config="tools/${tool}/upstream.json"
if [[ ! -f $config ]]; then
    echo "No such vendored tool: ${tool} (expected ${config})" >&2
    exit 1
fi

repository=$(jq -er '.repository' "$config")
pinned=$(jq -er '.ref' "$config")
track=$(jq -r '.track // "pinned"' "$config")
vendor="vendor/${repository##*/}"

if [[ -n $ref_input ]]; then
    ref=$ref_input
elif [[ $track == "latest-release" ]]; then
    ref=$(gh api "repos/${repository}/releases/latest" --jq '.tag_name' 2>/dev/null) || ref=""
    # A failing `gh api` still prints its error body, so reject anything that is not ref-shaped
    # rather than fetching a refspec built from an error message.
    if [[ -z $ref || $ref == *[[:space:]{}\"]* ]]; then
        echo "warning: cannot resolve the latest release of ${repository} - staying on ${pinned}" >&2
        ref=$pinned
    fi
elif [[ $track == "latest-tag" ]]; then
    # Some upstreams tag every build but publish releases rarely, so the newest release can
    # sit many versions behind the newest tag. ls-remote also needs no credentials.
    ref=$(git ls-remote --tags --refs "https://github.com/${repository}.git" |
        sed 's#.*refs/tags/##' | sort -V | tail -1)
    if [[ -z $ref ]]; then
        echo "warning: ${repository} has no tags - staying on ${pinned}" >&2
        ref=$pinned
    fi
else
    ref=$pinned
fi

work=$(mktemp -d)
staging=$(mktemp -d)
trap 'rm -rf "$work" "$staging"' EXIT

# Fetching the ref rather than cloning a branch keeps tags, branches and commit
# SHAs all working through the same path.
git init --quiet "$work"
git -C "$work" remote add origin "https://github.com/${repository}.git"
git -C "$work" fetch --quiet --depth 1 origin "$ref"
git -C "$work" checkout --quiet --detach FETCH_HEAD
commit=$(git -C "$work" rev-parse HEAD)

# Upstream trees can carry hundreds of megabytes that no build reads, and git never forgets
# a blob it has once stored. Staging first gives `--delete` something complete to compare
# against, so a path dropped from the include list also disappears from the mirror.
include=$(jq -r '(.include // [])[]' "$config")
if [[ -z $include ]]; then
    cp -a "${work}/." "${staging}/"
else
    while IFS= read -r path; do
        [[ -n $path ]] || continue
        if [[ ! -e ${work}/${path} ]]; then
            echo "error: ${repository}@${ref} has no ${path} - update the include list." >&2
            exit 1
        fi
        mkdir -p "${staging}/$(dirname "$path")"
        cp -a "${work}/${path}" "${staging}/${path}"
    done <<<"$include"
fi
rm -rf "${staging}/.git"

mkdir -p "$vendor"
rsync -a --delete "${staging}/" "${vendor}/"

# Only content-derived fields belong here. A timestamp would make every run
# produce a diff and open a pull request that changes nothing.
jq -n \
    --arg repository "$repository" \
    --arg ref "$ref" \
    --arg commit "$commit" \
    '{repository: $repository, ref: $ref, commit: $commit}' \
    >"${vendor}/UPSTREAM.json"

# Keep the tool's pinned ref honest about what is actually vendored.
jq --arg ref "$ref" '.ref = $ref' "$config" >"${config}.tmp"
mv "${config}.tmp" "$config"

shopt -s nullglob
patches=("tools/${tool}/patches"/*.patch)
# bash 3.2 (macOS) treats "${patches[@]}" on an empty array as unset under `set -u`.
for patch in ${patches[@]+"${patches[@]}"}; do
    if git apply --check --directory="$vendor" "$patch"; then
        echo "patch ok: ${patch}"
    else
        echo "error: ${patch} no longer applies to ${ref}. Rebase or drop it." >&2
        exit 1
    fi
done

echo "Mirrored ${repository}@${ref} (${commit}) into ${vendor}"
