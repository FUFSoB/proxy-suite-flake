#!/usr/bin/env bash
# Refresh every hand-pinned GitHub source under pkgs/ to its latest release tag,
# including the Go vendorHash where the package has one.
#
# Table columns: nix-file|owner|repo|version-key|flake-attr
#   version-key  the `<key> = "...";` line holding the tag. A leading "=" means
#                "do not query GitHub, reuse the value of that key" - for sources
#                that must stay in lockstep.
#   flake-attr   package built to recompute vendorHash; "-" when there is none.
#
# LOCKED_PINS are sources whose rev comes from a flake.lock input, so `nix flake update`
# moves them: their hash and vendorHash are refreshed when the source no longer matches.
# Table columns: nix-file|flake-input|flake-attr.
#
# Prints one "updated <repo>: <old> -> <new>" line per change on stdout; progress
# and errors go to stderr. A pin whose update fails (no tarball, no vendorHash to read
# from the build) is put back as it was and printed as a "skipped <name>: <reason>"
# line instead; the others still go through. `--attrs` lists the flake attrs instead.
set -euo pipefail

PINS=(
  "pkgs/tg-ws-proxy.nix|Flowseal|tg-ws-proxy|rev|tg-ws-proxy"
  "pkgs/zapret2.nix|bol-van|zapret2|version|zapret2"
  "pkgs/xray.nix|XTLS|Xray-core|version|xray"
  "pkgs/whitelist-bypass.nix|kulikov0|whitelist-bypass|version|whitelist-bypass"
  "pkgs/wireproxy-awg.nix|artem-russkikh|wireproxy-awg|version|wireproxy-awg"
)

LOCKED_PINS=(
  "pkgs/z2k-detect.nix|z2k|z2k-detect"
)

FAKE_HASH="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

if [[ "${1:-}" == "--attrs" ]]; then
  {
    for pin in "${PINS[@]}"; do
      IFS='|' read -r _ _ _ _ attr <<<"$pin"
      [[ "$attr" == "-" ]] || printf '.#%s\n' "$attr"
    done
    for pin in "${LOCKED_PINS[@]}"; do
      IFS='|' read -r _ _ attr <<<"$pin"
      printf '.#%s\n' "$attr"
    done
  } | sort -u
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
  # The tag is spliced into a Nix string and an awk replacement: git allows `"`,
  # `$`, `{` and `&` in ref names, so only plain version-shaped tags pass.
  local tags
  tags=$(gh_api "https://api.github.com/repos/${owner}/${repo}/tags?per_page=100" |
    jq -r '.[].name' | grep -E '^v?[0-9][0-9A-Za-z._+-]*$') || true
  # sort -V puts v1.0.0-rc1 after v1.0.0: plain numbered tags win where a repo has any.
  tag=$(grep -E '^v?[0-9]+(\.[0-9]+)*$' <<< "$tags" | sort -V | tail -n1 || true)
  [[ -n "$tag" ]] || tag=$(sort -V <<< "$tags" | tail -n1)
  [[ -n "$tag" ]] || { echo "unable to resolve latest tag for ${owner}/${repo}" >&2; return 1; }
  printf '%s\n' "$tag"
}

newest() { printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1; }

get_key() {
  sed -n -E "s/^[[:space:]]*$2 = \"([^\"]+)\";.*/\1/p" "$1" | head -n1
}

# Replace `<attr> = "...";` with val. When repo is non-empty the search is scoped
# to the fetchFromGitHub block of that repo, so sibling pins in the same file
# never clobber each other. Returns 1 if not found.
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
  echo "updated ${repo:-$attr} vendorHash: ${got}"
}


# `--self-test`: the one thing that must not break is set_attr's block scoping -
# a file may hold several fetchFromGitHub blocks and a vendorHash that belongs
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

# One tag pin, in this shell so BUMPED sticks. Lines for stdout collect in PIN_OUT and
# are printed only once the whole pin went through; a failure sets SKIP_REASON and
# returns 1, and the caller puts the file back.
update_pin() {
  local file=$1 owner=$2 repo=$3 key=$4 attr=$5 current new tag tag_ref hash commit vendor
  PIN_OUT="" SKIP_REASON=""

  if [[ "$key" == =* ]]; then
    # Lockstep source: refetch only when the key it follows actually moved.
    key=${key#=}
    [[ -n "${BUMPED[$key]:-}" ]] || { echo "${repo}: follows ${key}, unchanged" >&2; return 0; }
    new=$(get_key "$file" "$key")
    current=$new
  else
    current=$(get_key "$file" "$key")
    [[ -n "$current" ]] || { echo "could not read ${key} from ${file}" >&2; exit 1; }
    tag=$(latest_tag "$owner" "$repo") || { SKIP_REASON="could not list its tags"; return 1; }
    # Keep whatever "v" convention the file already uses.
    if [[ "$current" == v* ]]; then new=$tag; else new=${tag#v}; fi
    if [[ "$current" == "$new" ]]; then
      echo "${repo}: already at ${current}" >&2
      return 0
    fi
    # These pins exist because they are ahead of nixpkgs; never walk one back.
    if [[ "$(newest "$current" "$new")" != "$new" ]]; then
      echo "${repo}: pinned ${current} is newer than upstream ${new}, keeping it" >&2
      return 0
    fi
  fi

  tag_ref=$new
  [[ "$tag_ref" == v* ]] || tag_ref="v${tag_ref}"
  hash=$(nix store prefetch-file --json --unpack \
    "https://github.com/${owner}/${repo}/archive/refs/tags/${tag_ref}.tar.gz" | jq -r '.hash') || hash=""
  [[ -n "$hash" && "$hash" != "null" ]] || { SKIP_REASON="could not fetch ${tag_ref}, kept ${current}"; return 1; }

  if [[ "$current" != "$new" ]]; then
    set_attr "$file" "" "$key" "$new" || { echo "could not write ${key} in ${file}" >&2; exit 1; }
    # The commit the tag names now, for the review: a moved tag shows up as a commit that
    # is not on the project's history.
    commit=$(gh_api "https://api.github.com/repos/${owner}/${repo}/commits/${tag_ref}" | jq -r '.sha // empty') || true
    PIN_OUT+="updated ${repo}: ${current} -> ${new} (commit ${commit:-unknown})"$'\n'
  fi
  set_attr "$file" "$repo" hash "$hash" || { echo "could not write hash for ${repo}" >&2; exit 1; }
  vendor=$(refresh_vendor_hash "$file" "$repo" "$attr") ||
    { SKIP_REASON="${new} does not build far enough to give its vendorHash, kept ${current}"; return 1; }
  [[ -z "$vendor" ]] || PIN_OUT+="${vendor}"$'\n'
  [[ "$current" == "$new" ]] || BUMPED[$key]=1
}

# Locked sources: the fetch is named after the rev, so a moved input always refetches
# and a stale hash shows up as a mismatch here instead of reusing the old checkout.
update_locked_pin() {
  local file=$1 input=$2 attr=$3 rev log got vendor
  PIN_OUT="" SKIP_REASON=""
  rev=$(jq -r --arg input "$input" '.nodes[$input].locked.rev // empty' flake.lock)
  [[ -n "$rev" ]] || { echo "no locked rev for ${input} in flake.lock" >&2; exit 1; }
  if log=$(nix build --no-link ".#${attr}.src" 2>&1); then
    echo "${attr}: source matches ${input} ${rev:0:7}" >&2
    return 0
  fi
  got=$(grep -oE 'got: +sha256-[A-Za-z0-9+/]{43}=' <<<"$log" | grep -oE 'sha256-.*' | tail -n1)
  if [[ -z "$got" ]]; then
    echo "could not fetch the source of ${attr}:" >&2
    tail -n 30 <<<"$log" >&2
    SKIP_REASON="could not fetch ${input} ${rev:0:7}"
    return 1
  fi
  set_attr "$file" "" hash "$got" || { echo "could not write hash in ${file}" >&2; exit 1; }
  PIN_OUT+="updated ${attr}: source to ${input} ${rev:0:7}"$'\n'
  vendor=$(refresh_vendor_hash "$file" "" "$attr") ||
    { SKIP_REASON="${input} ${rev:0:7} does not build far enough to give its vendorHash"; return 1; }
  [[ -z "$vendor" ]] || PIN_OUT+="${vendor}"$'\n'
}

# Put a locked input back at the committed rev, so the source and its hashes stay a
# matching pair. Only a node with no inputs of its own (a `flake = false` source) can be
# swapped alone; any other is left moved, and its package build fails in the open.
restore_locked_input() {
  local input=$1 old tmp
  old=$(git show HEAD:flake.lock 2>/dev/null | jq -c --arg input "$input" '.nodes[$input] // empty') || old=""
  if [[ -z "$old" ]] || jq -e --arg input "$input" '.nodes[$input].inputs' flake.lock >/dev/null; then
    return 1
  fi
  tmp=$(mktemp)
  jq --arg input "$input" --argjson old "$old" '.nodes[$input] = $old' flake.lock >"$tmp"
  mv "$tmp" flake.lock
}

snapshot=$(mktemp)
trap 'rm -f "$snapshot"' EXIT

for pin in "${PINS[@]}"; do
  IFS='|' read -r file owner repo key attr <<<"$pin"
  [[ -f "$file" ]] || { echo "missing ${file}" >&2; exit 1; }
  cp "$file" "$snapshot"
  if update_pin "$file" "$owner" "$repo" "$key" "$attr"; then
    printf '%s' "$PIN_OUT"
  else
    cp "$snapshot" "$file"
    echo "${repo}: ${SKIP_REASON}" >&2
    echo "skipped ${repo}: ${SKIP_REASON}"
  fi
done

for pin in "${LOCKED_PINS[@]}"; do
  IFS='|' read -r file input attr <<<"$pin"
  [[ -f "$file" ]] || { echo "missing ${file}" >&2; exit 1; }
  cp "$file" "$snapshot"
  if update_locked_pin "$file" "$input" "$attr"; then
    printf '%s' "$PIN_OUT"
  else
    cp "$snapshot" "$file"
    if restore_locked_input "$input"; then
      SKIP_REASON+=", kept ${input} at the committed rev"
    else
      SKIP_REASON+=", ${input} stays moved with stale hashes"
    fi
    echo "${attr}: ${SKIP_REASON}" >&2
    echo "skipped ${attr}: ${SKIP_REASON}"
  fi
done
