# proxy-suite-net: fix the network from the console when the installed settings do
# not work. The fix lives in /run until the next reboot; persist it in host.nix.

usage() {
  cat <<USAGE
Usage: proxy-suite-net [--show | --reset]

  (no argument)  ask for new network settings and apply them until the next reboot
  --show         show interfaces, routes and the temporary settings, if any
  --reset        drop the temporary settings and go back to the configured ones
USAGE
}

if [[ $(id -u) != 0 ]]; then
  echo "proxy-suite-net: run it as root (sudo proxy-suite-net)" >&2
  exit 1
fi

case ${1-} in
  -h | --help)
    usage
    ;;
  --show)
    list_ifaces
    if [[ -e $NET_RUNTIME_FILE ]]; then
      bold "Temporary settings ($NET_RUNTIME_FILE):"
      cat "$NET_RUNTIME_FILE"
    fi
    ;;
  --reset)
    rm -f "$NET_RUNTIME_FILE"
    networkctl reload
    mapfile -t ifaces < <(physical_ifaces)
    networkctl reconfigure "${ifaces[@]}"
    say "Temporary settings dropped."
    ;;
  "")
    setup_network
    bold "Network works. These settings last until the next reboot."
    say "To keep them, replace the network block in /etc/nixos/host.nix with:"
    say ""
    print_network_nix "    "
    say ""
    say "then run: sudo nixos-rebuild switch --flake /etc/nixos && sudo proxy-suite-net --reset"
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
