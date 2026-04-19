# All option declarations for services.proxy-suite, split by feature area.
{ ... }:
{
  imports = [
    ./other.nix
    ./sing-box.nix
    ./sing-box-outbounds.nix
    ./sing-box-dns.nix
    ./sing-box-tun.nix
    ./sing-box-tproxy.nix
    ./sing-box-routing.nix
    ./per-app-routing.nix
    ./zapret.nix
  ];
}
