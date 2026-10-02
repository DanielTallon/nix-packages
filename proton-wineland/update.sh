#!/usr/bin/env nix-shell
#!nix-shell -i bash -p curl jq cacert
# Bump proton-wineland/sources.json to the newest wineland-* release of nanomatters/proton-cachyos.
# The repo also publishes non-Wineland releases, so only tags starting with "wineland-" count.
# Set GITHUB_TOKEN to avoid GitHub API rate limits (CI does this automatically).
set -euo pipefail
cd "$(dirname "$0")"

repo=nanomatters/proton-cachyos
auth=()
[[ -n "${GITHUB_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")

tag=$(curl -fsSL "${auth[@]}" "https://api.github.com/repos/$repo/releases?per_page=50" |
  jq -r '[.[] | select(.draft | not) | select(.prerelease | not)
          | select(.tag_name | startswith("wineland-"))]
         | sort_by(.published_at) | last | .tag_name // empty')
[[ -n $tag ]] || { echo "no wineland release found" >&2; exit 1; }

version=${tag#wineland-}
current=$(jq -r .version sources.json)
missing=$(jq '[.hashes[] | select(. == "")] | length' sources.json)
if [[ $version == "$current" && $missing == 0 ]]; then
  echo "proton-wineland already at $version"
  exit 0
fi

hashes='{}'
for variant in x86_64_v3 x86_64; do
  url="https://github.com/$repo/releases/download/$tag/proton-wineland-$version-$variant.tar.xz"
  echo "prefetching $variant ..." >&2
  b32=$(nix-prefetch-url --unpack --type sha256 "$url")
  sri=$(nix hash convert --hash-algo sha256 --to sri "$b32")
  hashes=$(jq --arg v "$variant" --arg h "$sri" '. + {($v): $h}' <<<"$hashes")
done

jq -n --arg version "$version" --argjson hashes "$hashes" \
  '{version: $version, hashes: $hashes}' >sources.json.tmp
mv sources.json.tmp sources.json
echo "proton-wineland: $current -> $version"
