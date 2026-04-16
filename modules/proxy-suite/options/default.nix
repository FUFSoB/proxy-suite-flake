# All option declarations for services.proxy-suite, split by feature area.
{ ... }:
{
  imports = [
    ./other.nix
    ./sing-box.nix
    ./app-routing.nix
    ./zapret.nix
  ];
}
