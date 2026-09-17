# Network prompts shared by proxy-suite-install and proxy-suite-net. The answers are
# applied through a systemd-networkd file in /run, the same way the installed system
# applies them from /etc, so settings that work here work after the reboot.
#
# Sets NET_IFACE NET_MAC NET_DHCP NET_V4 NET_V4_GW NET_V6 NET_V6_GW NET_DNS. Unattended
# runs (PSI_UNATTENDED=1) take every answer from PSI_<NAME> and fail instead of re-asking.

NET_RUNTIME_FILE=/run/systemd/network/05-proxy-suite-net.network

say() { printf '%s\n' "$*"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$*" >&2; }
bold() { printf '\033[1m%s\033[0m\n' "$*"; }

# ask VAR "Question" [default]. PSI_<VAR> in the environment answers it unattended.
ask() {
  local __preset="PSI_$1" __reply
  if [[ -n ${!__preset+x} ]]; then
    __reply=${!__preset}
  elif [[ -n ${3-} ]]; then
    read -r -p "$2 [$3]: " __reply || true
  else
    read -r -p "$2: " __reply || true
  fi
  [[ -n $__reply ]] || __reply=${3-}
  printf -v "$1" '%s' "$__reply"
}

# ask_yes VAR "Question" y|n; sets VAR to true or false.
ask_yes() {
  local __yn
  ask "$1" "$2 (y/n)" "$3"
  __yn=${!1}
  case ${__yn,,} in
    y | yes | true) printf -v "$1" '%s' true ;;
    *) printf -v "$1" '%s' false ;;
  esac
}

# Drop a rejected answer so the next ask prompts; unattended, give up instead.
reject() {
  warn "$1"
  shift
  if [[ -n ${PSI_UNATTENDED-} ]]; then
    exit 1
  fi
  local name
  for name in "$@"; do unset "PSI_$name"; done
}

is_ipv4() {
  local IFS=. octet
  [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  for octet in $1; do ((octet <= 255)) || return 1; done
}

is_ipv6() { [[ $1 == *:* && $1 =~ ^[0-9A-Fa-f:.]+$ ]]; }

mask_to_prefix() {
  local mask=$1 IFS=. octet bits=0
  if [[ $mask =~ ^[0-9]+$ ]]; then
    ((mask <= 32)) && printf '%s' "$mask" && return 0
    return 1
  fi
  is_ipv4 "$mask" || return 1
  for octet in $mask; do
    case $octet in
      255) bits=$((bits + 8)) ;;
      254) bits=$((bits + 7)) ;;
      252) bits=$((bits + 6)) ;;
      248) bits=$((bits + 5)) ;;
      240) bits=$((bits + 4)) ;;
      224) bits=$((bits + 3)) ;;
      192) bits=$((bits + 2)) ;;
      128) bits=$((bits + 1)) ;;
      0) ;;
      *) return 1 ;;
    esac
  done
  printf '%s' "$bits"
}

ipv4_to_int() {
  local IFS=. a b c d
  read -r a b c d <<<"$1"
  printf '%s' $(((a << 24) | (b << 16) | (c << 8) | d))
}

# ipv4_in_subnet ADDR/PREFIX GATEWAY
ipv4_in_subnet() {
  local addr=${1%/*} prefix=${1#*/} mask
  mask=$(((0xffffffff << (32 - prefix)) & 0xffffffff))
  [[ $(($(ipv4_to_int "$addr") & mask)) == $(($(ipv4_to_int "$2") & mask)) ]]
}

# Private, CGNAT or otherwise unroutable: clients cannot reach it, and no CA will
# issue a certificate for it.
ipv4_is_private() {
  local n
  n=$(ipv4_to_int "$1")
  (((n >> 24) == 10)) ||
    (((n >> 24) == 127)) ||
    (((n >> 20) == (172 << 4 | 1))) ||
    (((n >> 16) == (192 << 8 | 168))) ||
    (((n >> 22) == (100 << 2 | 1))) ||
    (((n >> 16) == (169 << 8 | 254)))
}

# Physical interfaces only: no lo, bridges or veths.
physical_ifaces() {
  local path
  for path in /sys/class/net/*; do
    if [[ -e $path/device ]]; then
      printf '%s\n' "${path##*/}"
    fi
  done
}

list_ifaces() {
  local name
  bold "Network interfaces:"
  while IFS= read -r name; do
    printf '  %-12s mac %s  state %s\n' "$name" "$(cat "/sys/class/net/$name/address")" \
      "$(cat "/sys/class/net/$name/operstate")"
    ip -o addr show dev "$name" | awk '{ printf "               %s %s%s\n", $3, $4, (/dynamic/ ? " (dhcp)" : "") }'
  done < <(physical_ifaces)
  ip route show default | sed 's/^/  route: /'
  ip -6 route show default | sed 's/^/  route: /'
}

ask_network() {
  local ifaces default_iface has_lease NET_ADDR NET_MASK prefix NET_V6_IN
  mapfile -t ifaces < <(physical_ifaces)
  if ((${#ifaces[@]} == 0)); then
    warn "No network interface found."
    return 1
  fi
  default_iface=$(ip route show default | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
  [[ -n $default_iface ]] || default_iface=${ifaces[0]}

  list_ifaces
  while true; do
    ask NET_IFACE "Interface" "$default_iface"
    [[ -e /sys/class/net/$NET_IFACE/address ]] && break
    reject "No interface named '$NET_IFACE'." NET_IFACE
  done
  NET_MAC=$(cat "/sys/class/net/$NET_IFACE/address")

  has_lease=n
  ip -4 -o addr show dev "$NET_IFACE" | grep -q dynamic && has_lease=y
  say ""
  say "Most VPS panels list a static IP, netmask (or prefix) and gateway: use those."
  say "Answer y only if the provider says the server gets its address over DHCP."
  ask_yes NET_DHCP "Use DHCP" "$has_lease"

  NET_V4="" NET_V4_GW="" NET_V6="" NET_V6_GW=""
  if [[ $NET_DHCP == false ]]; then
    while true; do
      ask NET_ADDR "IPv4 address (203.0.113.10/24, or without /prefix)"
      if [[ $NET_ADDR == */* ]]; then
        prefix=${NET_ADDR#*/} NET_ADDR=${NET_ADDR%/*}
      else
        ask NET_MASK "Netmask or prefix length (255.255.255.0 or 24)" "24"
        prefix=$(mask_to_prefix "$NET_MASK") || prefix=""
      fi
      if is_ipv4 "$NET_ADDR" && [[ $prefix =~ ^[0-9]+$ ]] && ((prefix >= 1 && prefix <= 32)); then
        NET_V4="$NET_ADDR/$prefix"
        break
      fi
      reject "Not an IPv4 address with a valid netmask." NET_ADDR NET_MASK
    done
    while true; do
      ask NET_V4_GW "IPv4 gateway"
      is_ipv4 "$NET_V4_GW" && break
      reject "Not an IPv4 address." NET_V4_GW
    done
    if ! ipv4_in_subnet "$NET_V4" "$NET_V4_GW"; then
      say "Gateway $NET_V4_GW is outside $NET_V4: it is routed on-link, as providers with /32 addresses expect."
    fi

    ask NET_V6_IN "IPv6 address with prefix (empty to skip)" ""
    if [[ -n $NET_V6_IN ]]; then
      [[ $NET_V6_IN == */* ]] || NET_V6_IN="$NET_V6_IN/64"
      if is_ipv6 "${NET_V6_IN%/*}"; then
        NET_V6=$NET_V6_IN
        ask NET_V6_GW "IPv6 gateway" "fe80::1"
      else
        warn "Not an IPv6 address; skipping IPv6."
      fi
    fi
  fi

  ask NET_DNS "DNS servers (space-separated)" "1.1.1.1 8.8.8.8"
}

# Mirrors the systemd.network config of deploy/server-module.nix.
write_networkd() {
  local file=$1 dns gw
  {
    printf '[Match]\nMACAddress=%s\nType=ether\n\n' "$NET_MAC"
    printf '[Link]\nRequiredForOnline=routable\n\n'
    printf '[Network]\n'
    if [[ $NET_DHCP == true ]]; then
      printf 'DHCP=yes\n'
    else
      printf 'DHCP=no\n'
      if [[ -n $NET_V6 ]]; then
        printf 'IPv6AcceptRA=no\nAddress=%s\n' "$NET_V6"
      fi
      printf 'Address=%s\n' "$NET_V4"
    fi
    for dns in $NET_DNS; do printf 'DNS=%s\n' "$dns"; done
    if [[ $NET_DHCP == false ]]; then
      for gw in "$NET_V4_GW" "$NET_V6_GW"; do
        if [[ -n $gw ]]; then
          printf '\n[Route]\nGateway=%s\nGatewayOnLink=yes\n' "$gw"
        fi
      done
    fi
  } >"$file"
}

apply_network() {
  mkdir -p "$(dirname "$NET_RUNTIME_FILE")"
  write_networkd "$NET_RUNTIME_FILE"
  networkctl reload
  networkctl reconfigure "$NET_IFACE"
  for _ in {1..30}; do
    ip -4 route show default dev "$NET_IFACE" | grep -q . && return 0
    sleep 1
  done
  warn "No IPv4 default route on $NET_IFACE after 30 seconds."
  return 1
}

# Each step names what failed, so a wrong gateway is told apart from a wrong DNS.
test_network() {
  local gw
  gw=$(ip -4 route show default dev "$NET_IFACE" | awk '{ print $3; exit }')
  say "Testing the network..."
  if [[ -n $gw ]] && ! ping -c 2 -W 2 "$gw" >/dev/null 2>&1; then
    warn "  gateway $gw does not answer ping (some providers block it; continuing)"
  fi
  if ! ping -c 2 -W 3 1.1.1.1 >/dev/null 2>&1 && ! curl -s -o /dev/null --max-time 8 http://1.1.1.1; then
    warn "  cannot reach the internet (1.1.1.1): check the address, netmask and gateway"
    return 1
  fi
  if ! getent ahosts cache.nixos.org >/dev/null; then
    warn "  internet works but DNS does not: check the DNS servers"
    return 1
  fi
  if ! curl -s -o /dev/null --max-time 15 https://cache.nixos.org/nix-cache-info; then
    warn "  cannot fetch https://cache.nixos.org"
    return 1
  fi
  say "  network OK"
}

setup_network() {
  while true; do
    ask_network || return 1
    if apply_network && test_network; then
      return 0
    fi
    reject "Network settings did not work; enter them again." \
      NET_IFACE NET_DHCP NET_ADDR NET_MASK NET_V4_GW NET_V6_IN NET_V6_GW NET_DNS
  done
}

# nix_str VALUE: VALUE as a Nix string literal.
nix_str() {
  local s=${1//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//\$\{/\\\$\{}
  printf '"%s"' "$s"
}

# The services.proxy-suite-server.network block for host.nix, indented by $1.
print_network_nix() {
  local pad=$1 dns list=""
  for dns in $NET_DNS; do list+=" $(nix_str "$dns")"; done
  printf '%snetwork = {\n' "$pad"
  printf '%s  mac = %s;\n' "$pad" "$(nix_str "$NET_MAC")"
  printf '%s  dhcp = %s;\n' "$pad" "$NET_DHCP"
  if [[ $NET_DHCP == false && -n $NET_V4 ]]; then
    printf '%s  ipv4 = { address = %s; gateway = %s; };\n' "$pad" "$(nix_str "$NET_V4")" "$(nix_str "$NET_V4_GW")"
  fi
  if [[ $NET_DHCP == false && -n $NET_V6 ]]; then
    printf '%s  ipv6 = { address = %s; gateway = %s; };\n' "$pad" "$(nix_str "$NET_V6")" "$(nix_str "$NET_V6_GW")"
  fi
  printf '%s  dns = [%s ];\n' "$pad" "$list"
  printf '%s};\n' "$pad"
}
