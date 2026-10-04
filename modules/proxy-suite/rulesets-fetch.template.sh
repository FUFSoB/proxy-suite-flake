set -uo pipefail
proxy=(--proxy socks5h://@proxyHost@:@proxyPort@)
# The listener's login as curl config on a pipe (-K): argv is readable by every local user.
proxy_login() {
  [ "$1" = proxy ] || return 0
  @proxyLogin@
}
failed=0

# A download replaces the file only once sing-box has read it back, so a bad one never
# reaches the backend; a failed one keeps what was there. Its domain rules go to the copy
# DNS rules read.
fetch() {
  local name=$1 url=$2 path=$3 dns=$4 format=$5 detour=$6 tmp dnsTmp
  local args=(--fail --silent --show-error --location --max-time 120 --max-filesize 64M)
  [ "$detour" = proxy ] && args+=("${proxy[@]}")
  tmp=$(@coreutils@/bin/mktemp "$path.XXXXXX") || { failed=1; return; }
  dnsTmp=$(@coreutils@/bin/mktemp "$dns.XXXXXX") || { rm -f "$tmp"; failed=1; return; }
  if @curl@ "${args[@]}" -K <(proxy_login "$detour") --output "$tmp" "$url" && valid "$tmp" "$format" &&
    domains "$tmp" "$format" > "$dnsTmp" && valid "$dnsTmp" source; then
    chmod 0644 "$tmp" "$dnsTmp"
    mv -f "$dnsTmp" "$dns"
    mv -f "$tmp" "$path"
    echo "rule set $name: updated"
  else
    rm -f "$tmp" "$dnsTmp"
    echo "rule set $name: not updated from $url; keeping the one it has" >&2
    failed=1
  fi
}
valid() {
  if [ "$2" = binary ]; then
    @singBox@ rule-set decompile --output /dev/null "$1" 2>/dev/null
  else
    @singBox@ rule-set compile --output /dev/null "$1" 2>/dev/null
  fi
}
domains() {
  if [ "$2" = binary ]; then
    @singBox@ rule-set decompile --output /dev/stdout "$1"
  else
    cat "$1"
  fi | @jq@/bin/jq '.rules = [(.rules // [])[]
    | select((.type // "default") == "default"
      and (has("domain") or has("domain_suffix") or has("domain_keyword") or has("domain_regex")))
    | del(.ip_cidr, .ip_is_private)]'
}

@fetchRuleSets@
exit "$failed"
