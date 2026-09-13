{ lib, ... }:

let
  inherit (lib) mkOption;
  t = import ./types.nix { inherit lib; };
  cloudflare = {
    type = "udp";
    address = "1.1.1.1";
    port = 53;
  };
in
{
  options.services.proxy-suite.proxy.dns = {
    local = mkOption {
      type = t.dnsUpstreamType;
      default = cloudflare;
      description = "Resolver for direct traffic and the default domain resolver. Goes through the proxy in global TUN mode.";
      example = {
        type = "tcp";
        address = "9.9.9.9";
      };
    };

    remote = mkOption {
      type = t.dnsUpstreamType;
      default = cloudflare;
      description = "Resolver used through the proxy; the DNS default when proxy.routing.default is proxy.";
      example = {
        type = "tls";
        address = "1.1.1.1";
        port = 853;
      };
    };
  };
}
