#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

if [[ ! -f flake.nix ]]; then
  echo "flake.nix not found at repository root" >&2
  exit 1
fi

if ! command -v nix >/dev/null 2>&1; then
  echo "nix command is required" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq command is required" >&2
  exit 1
fi

system="${NIXPKGS_WATCH_SYSTEM:-x86_64-linux}"
default_watch_attrs="sing-box,proxychains-ng,sing-geosite,sing-geoip,nftables,iproute2,iptables,ipset,python3,python3Packages.requests,python3Packages.websockets,python3Packages.cryptography,gtk3,libayatana-appindicator"
watch_attrs_csv="${NIXPKGS_WATCH_ATTRS:-$default_watch_attrs}"

IFS=',' read -r -a watch_attrs <<< "$watch_attrs_csv"
watch_attrs_json="$(
  printf '%s\n' "${watch_attrs[@]}" |
    sed '/^[[:space:]]*$/d' |
    jq -R . |
    jq -s .
)"

if [[ "$(jq 'length' <<< "$watch_attrs_json")" -eq 0 ]]; then
  echo "watch attribute list is empty" >&2
  exit 1
fi

eval_versions() {
  local ref="$1"

  REF="$ref" SYSTEM="$system" WATCH_ATTRS_JSON="$watch_attrs_json" nix eval --json --impure --expr '
let
  flake = builtins.getFlake (builtins.getEnv "REF");
  watched = builtins.fromJSON (builtins.getEnv "WATCH_ATTRS_JSON");
  system = builtins.getEnv "SYSTEM";
  pkgs = flake.legacyPackages.${system};
  lib = pkgs.lib;
  versionOf = attrPath:
    let value = lib.attrByPath (lib.splitString "." attrPath) null pkgs;
    in
      if value == null then null
      else if builtins.isAttrs value && value ? version then value.version
      else null;
in
lib.genAttrs watched versionOf
'
}

current_versions="$(eval_versions "path:${repo_root}")"
latest_versions="$(eval_versions "github:NixOS/nixpkgs/nixos-unstable")"

changes_json="$(
  jq -n \
    --argjson current "$current_versions" \
    --argjson latest "$latest_versions" \
    '
      [($latest | keys[]) as $k
       | select(($current[$k] // null) != ($latest[$k] // null))
       | {
           attr: $k,
           current: ($current[$k] // null),
           latest: ($latest[$k] // null)
         }]
    '
)"

if jq -e 'length > 0' <<< "$changes_json" >/dev/null; then
  changed_attrs="$(jq -r '[.[].attr] | join(",")' <<< "$changes_json")"
  echo "Detected nixpkgs updates for watched attrs: ${changed_attrs}" >&2
  echo "should_update_nixpkgs=true"
  echo "nixpkgs_changed_watch_attrs=${changed_attrs}"
else
  echo "No watched nixpkgs package version changes detected on nixos-unstable." >&2
  echo "should_update_nixpkgs=false"
  echo "nixpkgs_changed_watch_attrs="
fi
