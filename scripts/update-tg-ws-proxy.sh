#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

target_file="pkgs/tg-ws-proxy.nix"

if [[ ! -f "$target_file" ]]; then
  echo "Cannot find ${target_file}" >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl command is required" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq command is required" >&2
  exit 1
fi

if ! command -v nix >/dev/null 2>&1; then
  echo "nix command is required" >&2
  exit 1
fi

latest_tag="$(
  curl -fsSL "https://api.github.com/repos/Flowseal/tg-ws-proxy/releases/latest" |
    jq -r '.tag_name // empty'
)"

if [[ -z "$latest_tag" ]]; then
  latest_tag="$(
    curl -fsSL "https://api.github.com/repos/Flowseal/tg-ws-proxy/tags?per_page=1" |
      jq -r '.[0].name // empty'
  )"
fi

if [[ -z "$latest_tag" ]]; then
  echo "Unable to resolve latest tg-ws-proxy tag" >&2
  exit 1
fi

archive_url="https://github.com/Flowseal/tg-ws-proxy/archive/refs/tags/${latest_tag}.tar.gz"
latest_hash="$(
  nix store prefetch-file --json --unpack "$archive_url" | jq -r '.hash'
)"

if [[ -z "$latest_hash" || "$latest_hash" == "null" ]]; then
  echo "Unable to compute tg-ws-proxy source hash for ${latest_tag}" >&2
  exit 1
fi

current_rev="$(sed -n -E 's/^[[:space:]]*rev = "([^"]+)";/\1/p' "$target_file" | head -n1)"
current_hash="$(sed -n -E 's/^[[:space:]]*hash = "([^"]+)";/\1/p' "$target_file" | head -n1)"

if [[ -z "$current_rev" || -z "$current_hash" ]]; then
  echo "Could not parse current rev/hash from ${target_file}" >&2
  exit 1
fi

if [[ "$current_rev" == "$latest_tag" && "$current_hash" == "$latest_hash" ]]; then
  echo "tg-ws-proxy is already up to date (${latest_tag})"
  exit 0
fi

sed -i -E "s|(^[[:space:]]*rev = \").*(\";)|\1${latest_tag}\2|" "$target_file"
sed -i -E "s|(^[[:space:]]*hash = \").*(\";)|\1${latest_hash}\2|" "$target_file"

echo "Updated tg-ws-proxy pin: ${current_rev} -> ${latest_tag}"
echo "Updated tg-ws-proxy hash: ${current_hash} -> ${latest_hash}"
