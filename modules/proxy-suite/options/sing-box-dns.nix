{ lib, ... }:

let
  inherit (lib) mkOption;
  t = import ./types.nix { inherit lib; };
in
{
  options.services.proxy-suite.singBox.dns = {
    local = mkOption {
      type = t.dnsUpstreamType;
      default = {
        type = "udp";
        address = "1.1.1.1";
        port = 53;
      };
      description = ''
        DNS upstream used for the built-in "local" resolver role.
        This resolver is also used as sing-box route.default_domain_resolver.

        The module keeps detour policy automatic: in mixed/TProxy mode and
        per-app-routing TUN mode, "local" stays on the direct path (without an
        explicit detour); in global TUN mode, it is forced through the proxy to avoid
        auto_redirect conflicts.
      '';
      example = {
        type = "tcp";
        address = "9.9.9.9";
        port = 53;
      };
    };

    remote = mkOption {
      type = t.dnsUpstreamType;
      default = {
        type = "udp";
        address = "1.1.1.1";
        port = 53;
      };
      description = ''
        DNS upstream used for the built-in "remote" resolver role.

        This resolver always detours through the proxy and becomes the
        generated dns.final target when singBox.proxyByDefault = true.
      '';
      example = {
        type = "tls";
        address = "1.1.1.1";
        port = 853;
      };
    };
  };
}
