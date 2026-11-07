#!/usr/bin/env nix-shell
#!nix-shell -i bash -p curl jq gawk cacert
# Bump brave-origin/sources.json to the newest brave-origin in Brave's stable apt repo.
# The repo's Packages index lists every .deb with its SHA256, so nothing is downloaded here;
# the build step in CI then fetches the .deb and checks it against that hash.
set -euo pipefail
cd "$(dirname "$0")"

repo=https://brave-browser-apt-release.s3.brave.com

# Print "version sha256" for every brave-origin entry in one arch's Packages index.
entries() {
  curl -fsSL "$repo/dists/stable/main/binary-$1/Packages" |
    awk '/^Package: /{p = ($2 == "brave-origin")}
         p && /^Version: /{v = $2}
         p && /^SHA256: /{print v, $2}'
}

declare -A arch=([x86_64-linux]=amd64 [aarch64-linux]=arm64)
declare -A index
for system in "${!arch[@]}"; do
  index[$system]=$(entries "${arch[$system]}")
done

# Newest version published for both architectures.
version=$(comm -12 \
  <(awk '{print $1}' <<<"${index[x86_64-linux]}" | sort -u) \
  <(awk '{print $1}' <<<"${index[aarch64-linux]}" | sort -u) |
  sort -V | tail -1)
[[ -n $version ]] || { echo "no brave-origin release found" >&2; exit 1; }

current=$(jq -r .version sources.json)
missing=$(jq '[.hashes[] | select(. == "")] | length' sources.json)
if [[ $version == "$current" && $missing == 0 ]]; then
  echo "brave-origin already at $version"
  exit 0
fi

hashes='{}'
for system in "${!arch[@]}"; do
  hex=$(awk -v v="$version" '$1 == v {print $2; exit}' <<<"${index[$system]}")
  sri=$(nix hash convert --hash-algo sha256 --to sri "$hex")
  hashes=$(jq --arg s "$system" --arg h "$sri" '. + {($s): $h}' <<<"$hashes")
done

jq -n --arg version "$version" --argjson hashes "$hashes" \
  '{version: $version, hashes: ($hashes | to_entries | sort_by(.key) | reverse | from_entries)}' \
  >sources.json.tmp
mv sources.json.tmp sources.json
echo "brave-origin: $current -> $version"
