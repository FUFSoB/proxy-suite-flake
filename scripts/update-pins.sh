#!/usr/bin/env bash
# Refresh every hand-pinned GitHub source under pkgs/ to its latest release tag,
# including the Go vendorHash where the package has one.
#
# Table columns: nix-file|owner|repo|version-key|flake-attr
#   version-key  the `<key> = "...";` line holding the tag. A leading "=" means
#                "do not query GitHub, reuse the value of that key" - for sources
#                that must stay in lockstep (AWG kernel module follows tools).
#   flake-attr   package built to recompute vendorHash; "-" when there is none.
#
# Prints one "updated <repo>: <old> -> <new>" line per change on stdout; progress
# and errors go to stderr. `--attrs` lists the flake attrs instead.
set -euo pipefail

PINS=(
  "pkgs/tg-ws-proxy.nix|Flowseal|tg-ws-proxy|rev|tg-ws-proxy"
  "pkgs/zapret2.nix|bol-van|zapret2|version|zapret2"
  "pkgs/xray.nix|XTLS|Xray-core|version|xray"
  "pkgs/amneziawg.nix|amnezia-vpn|amneziawg-tools|version|amneziawg-tools"
  "pkgs/amneziawg.nix|amnezia-vpn|amneziawg-go|userspaceVersion|amneziawg-go"
  "pkgs/amneziawg.nix|amnezia-vpn|amneziawg-linux-kernel-module|=version|-"
)

FAKE_HASH="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

if [[ "${1:-}" == "--attrs" ]]; then
  for pin in "${PINS[@]}"; do
    IFS='|' read -r _ _ _ _ attr <<<"$pin"
    [[ "$attr" == "-" ]] || printf '.#%s\n' "$attr"
  done | sort -u
  exit 0
fi

cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

for cmd in curl jq nix awk; do
  command -v "$cmd" >/dev/null || { echo "$cmd is required" >&2; exit 1; }
done

gh_api() {
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" "$1"
  else
    curl -fsSL "$1"
  fi
}

# The tags list, not releases/latest: some of these repos cut prereleases or no
# releases at all, and releases/latest skips both (it reported v26.3.27 while
# Xray-core was already on v26.9.9, and 404s for amneziawg-go).
latest_tag() {
  local owner=$1 repo=$2 tag
  tag=$(gh_api "https://api.github.com/repos/${owner}/${repo}/tags?per_page=100" |
    jq -r '.[].name' | grep -E '^v?[0-9]' | sort -V | tail -n1)
  [[ -n "$tag" ]] || { echo "unable to resolve latest tag for ${owner}/${repo}" >&2; return 1; }
  printf '%s\n' "$tag"
}

newest() { printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1; }

get_key() {
  sed -n -E "s/^[[:space:]]*$2 = \"([^\"]+)\";.*/\1/p" "$1" | head -n1
}

# Replace `<attr> = "...";` with val. When repo is non-empty the search is scoped
# to the fetchFromGitHub block of that repo, so sibling pins in the same file
# (amneziawg.nix holds three) never clobber each other. Returns 1 if not found.
set_attr() {
  local file=$1 repo=$2 attr=$3 val=$4 tmp
  tmp=$(mktemp)
  if awk -v repo="$repo" -v attr="$attr" -v val="$val" '
    BEGIN { region = (repo == "") }
    {
      if (repo != "" && $0 ~ ("repo = \"" repo "\";")) { region = 1 }
      else if (repo != "" && region && $0 ~ /repo = "/) { region = 0 }
      else if (region && !done && $0 ~ ("^[ \t]*" attr " = \"")) {
        sub(/"[^"]*"/, "\"" val "\""); done = 1
      }
      print
    }
    END { exit(done ? 0 : 1) }
  ' "$file" >"$tmp"; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
    return 1
  fi
}

# Go packages pin a vendorHash that a source bump invalidates: poison it and let
# the failing build report the real one.
refresh_vendor_hash() {
  local file=$1 repo=$2 attr=$3 log got
  [[ "$attr" != "-" ]] || return 0
  set_attr "$file" "$repo" vendorHash "$FAKE_HASH" || return 0
  echo "recomputing vendorHash for ${attr}" >&2
  if log=$(nix build --no-link ".#${attr}" 2>&1); then
    echo "build of ${attr} succeeded with a placeholder vendorHash" >&2
    return 1
  fi
  got=$(grep -oE 'sha256-[A-Za-z0-9+/]{43}=' <<<"$log" | grep -vxF "$FAKE_HASH" | tail -n1)
  if [[ -z "$got" ]]; then
    echo "could not extract vendorHash for ${attr}:" >&2
    tail -n 30 <<<"$log" >&2
    return 1
  fi
  set_attr "$file" "$repo" vendorHash "$got"
  echo "updated ${repo} vendorHash: ${got}"
}


# `--self-test`: the one thing that must not break is set_attr's block scoping -
# amneziawg.nix holds three fetchFromGitHub blocks and a vendorHash that belongs
# to exactly one of them.
self_test() {
  local d f
  d=$(mktemp -d)
  trap 'rm -rf "$d"' RETURN
  f="$d/fixture.nix"
  cat >"$f" <<'FIXTURE'
  version = "1.0";
  other = pkgs.a.overrideAttrs (_: {
    src = pkgs.fetchFromGitHub {
      repo = "alpha";
      hash = "sha256-ALPHA";
    };
  });
  more = pkgs.b.overrideAttrs (_: {
    src = pkgs.fetchFromGitHub {
      repo = "beta";
      hash = "sha256-BETA";
    };
    vendorHash = "sha256-VENDOR";
  });
FIXTURE
  set_attr "$f" "" version 2.0
  set_attr "$f" alpha hash sha256-NEW
  set_attr "$f" alpha vendorHash sha256-WRONG && { echo "self-test: vendorHash leaked out of the alpha block" >&2; return 1; }
  set_attr "$f" beta vendorHash sha256-OK
  [[ "$(get_key "$f" version)" == "2.0" ]] || { echo "self-test: version not written" >&2; return 1; }
  grep -q 'hash = "sha256-NEW";' "$f" || { echo "self-test: alpha hash not written" >&2; return 1; }
  grep -q 'hash = "sha256-BETA";' "$f" || { echo "self-test: beta hash was clobbered" >&2; return 1; }
  grep -q 'vendorHash = "sha256-OK";' "$f" || { echo "self-test: beta vendorHash not written" >&2; return 1; }
  echo "self-test ok"
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit 0
fi

declare -A BUMPED=()

for pin in "${PINS[@]}"; do
  IFS='|' read -r file owner repo key attr <<<"$pin"
  [[ -f "$file" ]] || { echo "missing ${file}" >&2; exit 1; }

  if [[ "$key" == =* ]]; then
    # Lockstep source: refetch only when the key it follows actually moved.
    key=${key#=}
    [[ -n "${BUMPED[$key]:-}" ]] || { echo "${repo}: follows ${key}, unchanged" >&2; continue; }
    new=$(get_key "$file" "$key")
    current=$new
  else
    current=$(get_key "$file" "$key")
    [[ -n "$current" ]] || { echo "could not read ${key} from ${file}" >&2; exit 1; }
    tag=$(latest_tag "$owner" "$repo")
    # Keep whatever "v" convention the file already uses.
    if [[ "$current" == v* ]]; then new=$tag; else new=${tag#v}; fi
    if [[ "$current" == "$new" ]]; then
      echo "${repo}: already at ${current}" >&2
      continue
    fi
    # These pins exist because they are ahead of nixpkgs; never walk one back.
    if [[ "$(newest "$current" "$new")" != "$new" ]]; then
      echo "${repo}: pinned ${current} is newer than upstream ${new}, keeping it" >&2
      continue
    fi
  fi

  tag_ref=$new
  [[ "$tag_ref" == v* ]] || tag_ref="v${tag_ref}"
  hash=$(nix store prefetch-file --json --unpack \
    "https://github.com/${owner}/${repo}/archive/refs/tags/${tag_ref}.tar.gz" | jq -r '.hash')
  [[ -n "$hash" && "$hash" != "null" ]] || { echo "could not hash ${repo} ${tag_ref}" >&2; exit 1; }

  if [[ "$current" != "$new" ]]; then
    set_attr "$file" "" "$key" "$new" || { echo "could not write ${key} in ${file}" >&2; exit 1; }
    BUMPED[$key]=1
    echo "updated ${repo}: ${current} -> ${new}"
  fi
  set_attr "$file" "$repo" hash "$hash" || { echo "could not write hash for ${repo}" >&2; exit 1; }
  refresh_vendor_hash "$file" "$repo" "$attr"
done
