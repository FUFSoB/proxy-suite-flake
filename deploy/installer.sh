# proxy-suite-install: turn a VPS booted from the installer ISO into a proxy-suite
# server. Everything asked here ends up in /etc/nixos/host.nix on the target.
#
# Baked in by deploy/installer.nix: PSI_FLAKE_URL (github ref at the ISO's commit, or
# empty), PSI_FLAKE_SRC (this flake's source in the store), PSI_STATE_VERSION.
# Unattended: PSI_UNATTENDED=1 plus PSI_<NAME> for every answer (see ask in net-lib.sh).

: "${PSI_FLAKE_URL?}" "${PSI_FLAKE_SRC:?}" "${PSI_STATE_VERSION:?}"

MNT=/mnt
SECRETS_DIR=/var/lib/proxy-suite-server

if [[ $(id -u) != 0 ]]; then
  echo "proxy-suite-install: run it as root (sudo -i)" >&2
  exit 1
fi

confirm() {
  local reply
  if [[ -n ${PSI_UNATTENDED-} ]]; then
    return 0
  fi
  read -r -p "$1 Type yes to continue: " reply || true
  [[ $reply == yes ]]
}

step() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }

# nvme0n1 -> nvme0n1p1, vda -> vda1
partition() {
  if [[ $1 =~ [0-9]$ ]]; then
    printf '%sp%s' "$1" "$2"
  else
    printf '%s%s' "$1" "$2"
  fi
}

# A stable name for GRUB, where the disk has one.
stable_disk_path() {
  local link
  for link in /dev/disk/by-id/*; do
    [[ $link == *-part* || $link == */nvme-eui.* ]] && continue
    if [[ $(readlink -f "$link") == "$1" ]]; then
      printf '%s' "$link"
      return 0
    fi
  done
  printf '%s' "$1"
}

clear
bold "proxy-suite server installer"
say "Installs NixOS with VLESS REALITY, TLS and WS inbounds for one user, and SSH."
say "Every question has a default in [brackets]: press Enter to take it."
say "Ctrl+C aborts; run sudo proxy-suite-install to start over."

# --- Network --------------------------------------------------------------------
step "Network"
setup_network || exit 1

step "Public address"
if [[ $NET_DHCP == false ]]; then
  local_ip=${NET_V4%/*}
else
  local_ip=$(ip -4 route get 1.1.1.1 | awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }')
fi
seen_ip=$(curl -4 -s --max-time 10 https://api.ipify.org || true)
default_ip=$local_ip
if [[ -n $seen_ip && $seen_ip != "$local_ip" ]] && is_ipv4 "$seen_ip"; then
  say "This server's address is $local_ip, but the internet sees it as $seen_ip (NAT)."
  default_ip=$seen_ip
fi
while true; do
  ask PUBLIC_IP "Public IPv4 clients connect to" "$default_ip"
  is_ipv4 "$PUBLIC_IP" && break
  reject "Not an IPv4 address." PUBLIC_IP
done
if ipv4_is_private "$PUBLIC_IP"; then
  warn "$PUBLIC_IP is a private address: clients outside cannot reach it, and no certificate"
  warn "can be issued for it. Use a domain, and forward the ports to this server."
fi

# --- Server ---------------------------------------------------------------------
step "Server"
while true; do
  ask HOST_NAME "Hostname" "proxy-$(openssl rand -hex 2)"
  [[ $HOST_NAME =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] && break
  reject "Lowercase letters, digits and dashes only." HOST_NAME
done
while true; do
  ask ADMIN_USER "Admin user name (SSH login, sudo)" "admin"
  [[ $ADMIN_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ && $ADMIN_USER != root ]] && break
  reject "Lowercase letters, digits, - and _; not root." ADMIN_USER
done
while true; do
  ask SSH_PORT "SSH port" "22"
  if [[ $SSH_PORT =~ ^[0-9]+$ ]] && ((SSH_PORT >= 1 && SSH_PORT <= 65535)) &&
    [[ ! " 80 443 2053 8443 18533 18534 18535 " == *" $SSH_PORT "* ]]; then
    break
  fi
  reject "A free port from 1 to 65535 (80, 443, 2053 and 8443 are taken)." SSH_PORT
done

# --- Proxy ----------------------------------------------------------------------
step "Proxy"
while true; do
  ask PROXY_USER "Proxy user name (label of the share links)" "user"
  [[ $PROXY_USER =~ ^[A-Za-z0-9_.-]{1,32}$ ]] && break
  reject "Letters, digits, dot, dash and underscore." PROXY_USER
done

say ""
say "The TLS and WS inbounds need a certificate from Let's Encrypt. With a domain"
say "(its A record pointing at $PUBLIC_IP) it is issued for the domain; without one,"
say "for the IP itself (a six-day certificate, renewed automatically). Port 80 must be open."
while true; do
  ask DOMAIN "Domain (empty: certificate for the IP)" ""
  if [[ -z $DOMAIN ]]; then
    break
  fi
  DOMAIN=${DOMAIN,,}
  if [[ ! $DOMAIN =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]; then
    reject "Not a domain name." DOMAIN
    continue
  fi
  if getent ahostsv4 "$DOMAIN" | awk '{ print $1 }' | grep -qx "$PUBLIC_IP"; then
    break
  fi
  warn "$DOMAIN does not resolve to $PUBLIC_IP (yet). The certificate order retries until it does."
  ask_yes KEEP_DOMAIN "Keep $DOMAIN anyway" "y"
  [[ $KEEP_DOMAIN == true ]] && break
  unset PSI_DOMAIN PSI_KEEP_DOMAIN
done

while true; do
  ask ACME_EMAIL "Email for Let's Encrypt (optional)" ""
  [[ -z $ACME_EMAIL || $ACME_EMAIL =~ ^[^[:space:]\"@]+@[^[:space:]\"@]+$ ]] && break
  reject "Not an email address." ACME_EMAIL
done

say ""
say "REALITY impersonates another site's TLS. Pick a big HTTPS site, ideally hosted"
say "near this server and not blocked where your clients are."
while true; do
  ask REALITY_SNI "REALITY site" "www.microsoft.com"
  if [[ ! $REALITY_SNI =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]; then
    reject "Not a domain name." REALITY_SNI
    continue
  fi
  if curl -s -o /dev/null --max-time 10 --tlsv1.3 --http2 "https://$REALITY_SNI/"; then
    break
  fi
  warn "$REALITY_SNI did not answer over TLS 1.3 from here; REALITY needs TLS 1.3 and HTTP/2."
  ask_yes KEEP_SNI "Keep $REALITY_SNI anyway" "n"
  [[ $KEEP_SNI == true ]] && break
  unset PSI_REALITY_SNI PSI_KEEP_SNI
done

# --- Disk -----------------------------------------------------------------------
step "Disk"
mapfile -t disks < <(lsblk -dnpo NAME,TYPE,RO | awk '$2 == "disk" && $3 == 0 && $1 !~ /\/(zram|loop|sr|fd)[0-9]/ { print $1 }')
if ((${#disks[@]} == 0)); then
  warn "No writable disk found."
  exit 1
fi
lsblk -dpo NAME,SIZE,MODEL "${disks[@]}"
while true; do
  ask DISK "Disk to install on (ERASED)" "$(if ((${#disks[@]} == 1)); then printf '%s' "${disks[0]}"; fi)"
  [[ -b $DISK && " ${disks[*]} " == *" $DISK "* ]] && break
  reject "Not one of the disks above." DISK
done

# --- Summary --------------------------------------------------------------------
step "Summary"
if [[ $NET_DHCP == true ]]; then
  net_summary="DHCP on $NET_IFACE ($NET_MAC)"
else
  net_summary="$NET_V4 via $NET_V4_GW${NET_V6:+, $NET_V6 via $NET_V6_GW} on $NET_IFACE ($NET_MAC)"
fi
cat <<SUMMARY
  Disk          $DISK  (everything on it is erased)
  Network       $net_summary
  DNS           $NET_DNS
  Public IP     $PUBLIC_IP
  Hostname      $HOST_NAME
  SSH           $ADMIN_USER@$PUBLIC_IP port $SSH_PORT (password shown at the end)
  Proxy user    $PROXY_USER
  Certificate   ${DOMAIN:-$PUBLIC_IP (IP certificate)}${ACME_EMAIL:+, $ACME_EMAIL}
  REALITY       443 as $REALITY_SNI
  TLS / WS      8443 / 2053
SUMMARY
confirm "Install now?" || {
  say "Aborted; nothing was written."
  exit 1
}

# --- Partition ------------------------------------------------------------------
step "Partitioning $DISK"
swapoff -a || true
umount -R "$MNT" 2>/dev/null || true
wipefs -af "$DISK"
sgdisk --zap-all "$DISK"
sgdisk \
  -n 1:0:+1M -t 1:EF02 -c 1:bios \
  -n 2:0:+512M -t 2:EF00 -c 2:ESP \
  -n 3:0:0 -t 3:8300 -c 3:nixos \
  "$DISK"
# sgdisk has the kernel reread the table; wait for udev to finish recreating the
# partition nodes, or mkfs can write to a node that is about to be replaced.
udevadm settle
esp=$(partition "$DISK" 2)
root=$(partition "$DISK" 3)
for _ in {1..20}; do
  [[ -b $esp && -b $root ]] && break
  sleep 0.5
done
wipefs -aq "$esp" "$root"
mkfs.vfat -F 32 -n ESP "$esp"
mkfs.ext4 -qF -L nixos "$root"
sync
udevadm settle
mount -t ext4 "$root" "$MNT"
mkdir -p "$MNT/boot"
mount -t vfat -o umask=077 "$esp" "$MNT/boot"

nixos-generate-config --root "$MNT"
rm -f "$MNT/etc/nixos/configuration.nix"

# Evaluating NixOS takes more memory than the smallest VPS plans have. Added after
# nixos-generate-config, which would list it in swapDevices.
fallocate -l 2G "$MNT/.install-swap"
chmod 600 "$MNT/.install-swap"
mkswap "$MNT/.install-swap" >/dev/null
swapon "$MNT/.install-swap"

# --- Secrets --------------------------------------------------------------------
step "Generating keys"
install -d -m 0700 "$MNT$SECRETS_DIR"
keys=$(xray x25519)
# XRay prints "Private key:/Public key:", or from 25.x "PrivateKey:/Password (PublicKey):".
private_key=$(sed -n 's/^Private *[Kk]ey: *//p' <<<"$keys")
public_key=$(sed -n 's/^\(Public key\|Password (PublicKey)\|Password\): *//p' <<<"$keys" | head -n 1)
if [[ -z $private_key || -z $public_key ]]; then
  warn "Could not read the output of xray x25519:"
  printf '%s\n' "$keys" >&2
  exit 1
fi
(
  umask 077
  xray uuid >"$MNT$SECRETS_DIR/uuid"
  printf '%s\n' "$private_key" >"$MNT$SECRETS_DIR/reality-key"
)
short_id=$(openssl rand -hex 8)
ws_path="/$(openssl rand -hex 6)"

# --- Configuration --------------------------------------------------------------
step "Writing /etc/nixos"
etc_nixos="$MNT/etc/nixos"

cat >"$etc_nixos/host.nix" <<HOST
# Written by proxy-suite-install on $(date -u +%Y-%m-%d). Edit it, then apply with:
#   sudo nixos-rebuild switch --flake /etc/nixos
# Options: deploy/server-module.nix in the proxy-suite-flake repository.
{
  networking.hostName = $(nix_str "$HOST_NAME");
  time.timeZone = "UTC";
  system.stateVersion = $(nix_str "$PSI_STATE_VERSION");

  services.proxy-suite-server = {
    enable = true;
    bootDisk = $(nix_str "$(stable_disk_path "$DISK")");
    adminUser = $(nix_str "$ADMIN_USER");
    sshPort = $SSH_PORT;
$(print_network_nix "    ")
    publicAddress = $(nix_str "$PUBLIC_IP");
    domain = $(if [[ -n $DOMAIN ]]; then nix_str "$DOMAIN"; else printf null; fi);
    acmeEmail = $(if [[ -n $ACME_EMAIL ]]; then nix_str "$ACME_EMAIL"; else printf null; fi);
    user = $(nix_str "$PROXY_USER");
    reality = {
      sni = $(nix_str "$REALITY_SNI");
      publicKey = $(nix_str "$public_key");
      shortId = $(nix_str "$short_id");
    };
    wsPath = $(nix_str "$ws_path");
  };
}
HOST

write_flake() {
  cat >"$etc_nixos/flake.nix" <<FLAKE
{
  inputs = {
    proxy-suite.url = $(nix_str "$1");
    nixpkgs.follows = "proxy-suite/nixpkgs";
  };

  outputs =
    { nixpkgs, proxy-suite, ... }:
    {
      nixosConfigurations.$(nix_str "$HOST_NAME") = nixpkgs.lib.nixosSystem {
        modules = [
          proxy-suite.nixosModules.server
          ./hardware-configuration.nix
          ./host.nix
        ];
      };
    };
}
FLAKE
}

# The ISO's own commit on GitHub, so `nix flake update` follows upstream later. An ISO
# built from an unpushed tree has none: its source is copied next to the flake instead.
locked=false
if [[ -n $PSI_FLAKE_URL ]]; then
  write_flake "$PSI_FLAKE_URL"
  if nix flake lock "$etc_nixos"; then
    locked=true
  else
    warn "Could not lock $PSI_FLAKE_URL; using the copy of proxy-suite on this ISO instead."
  fi
fi
if [[ $locked == false ]]; then
  rm -f "$etc_nixos/flake.lock"
  cp -r --no-preserve=mode "$PSI_FLAKE_SRC" "$etc_nixos/proxy-suite"
  write_flake "path:./proxy-suite"
  nix flake lock "$etc_nixos"
fi

# --- Install --------------------------------------------------------------------
step "Installing (takes a few minutes)"
mkdir -p "$MNT/tmp"
TMPDIR="$MNT/tmp" nixos-install \
  --root "$MNT" \
  --flake "$etc_nixos#$HOST_NAME" \
  --no-root-passwd \
  --no-channel-copy
rm -rf "$MNT/tmp"

step "Setting the admin password"
password="$(xkcdpass -n 3 --min 4 --max 6 -d -)-$((RANDOM % 90 + 10))"
password=${password,,}
hash=$(mkpasswd -m yescrypt --stdin <<<"$password")
nixos-enter --root "$MNT" -- usermod -p "$hash" "$ADMIN_USER"

swapoff "$MNT/.install-swap"
rm -f "$MNT/.install-swap"

# --- Done -----------------------------------------------------------------------
clear
bold "Installed."
cat <<DONE

  SSH:       ssh -p $SSH_PORT $ADMIN_USER@$PUBLIC_IP
  User:      $ADMIN_USER
DONE
printf '  Password:  \033[1;32m%s\033[0m\n\n' "$password"
cat <<DONE
  Write the password down now: it is not stored anywhere readable.
  Change it after logging in with: passwd

  Share links, after the reboot (as $ADMIN_USER):
    proxy-ctl inbounds link vless-reality --qr
    proxy-ctl inbounds link vless-tls --qr
    proxy-ctl inbounds link vless-ws --qr
  The TLS and WS links work once the certificate is issued (a minute or two;
  check with: systemctl status acme-order-renew-${DOMAIN:-$PUBLIC_IP}).

  Configuration: /etc/nixos/host.nix, applied with
    sudo nixos-rebuild switch --flake /etc/nixos
  Network broken after the reboot? Log in here and run: sudo proxy-suite-net

  Detach the ISO in the VPS panel so the server boots from its disk.
DONE

if [[ -z ${PSI_UNATTENDED-} ]]; then
  read -r -p "Press Enter to reboot (Ctrl+C to stay in the installer)... " _ || true
  umount -R "$MNT"
  reboot
fi
