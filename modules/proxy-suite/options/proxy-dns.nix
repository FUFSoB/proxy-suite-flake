{ lib, ... }:

let
  inherit (lib) mkOption types;
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
      description = ''
        Resolver used through the proxy; the DNS default when proxy.routing.default is proxy. On
        sing-box, names the routing sends through the proxy are always looked up here, so the ISP
        never sees them, and direct ones locally.
      '';
      example = {
        type = "tls";
        address = "1.1.1.1";
        port = 853;
      };
    };

    strategy = mkOption {
      type = types.nullOr (
        types.enum [
          "prefer_ipv4"
          "prefer_ipv6"
          "ipv4_only"
          "ipv6_only"
        ]
      );
      default = null;
      description = "Which addresses sing-box asks for. `ipv4_only` for an uplink without IPv6. sing-box and hybrid backends.";
      example = "ipv4_only";
    };

    clientSubnet = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        EDNS client subnet sent with every query, so a resolver reached through the proxy still
        answers with CDN nodes near this network. sing-box and hybrid backends.
      '';
      example = "203.0.113.0/24";
    };

    fakeIp = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          In TUN mode (global and per-app), answer A queries from the TUN with a fake address and
          AAAA ones with nothing; sing-box maps the address back to the name when the connection
          comes. Saves a lookup per new site and no real lookup leaves for proxied names. Names that
          proxy.dns.singBox.rules or the direct routing lists send elsewhere keep real answers. The
          addresses handed out are kept in /var/lib/proxy-suite/fakeip, so they survive a restart.
          sing-box and hybrid backends; XRay's TUN already uses its own fake DNS.
        '';
      };

      inet4Range = mkOption {
        type = types.str;
        default = "198.18.0.0/15";
        description = "Range the fake addresses come from.";
      };
    };

    singBox = {
      servers = mkOption {
        type = types.listOf types.attrs;
        default = [ ];
        description = ''
          Extra sing-box DNS servers, as sing-box JSON, for proxy.dns.singBox.rules to name. The
          built-in ones are `local`, `remote`, and `fakeip` when fakeIp is on.
        '';
        example = [
          {
            tag = "corp";
            type = "udp";
            server = "10.0.0.53";
          }
        ];
      };

      rules = mkOption {
        type = types.listOf types.attrs;
        default = [ ];
        description = ''
          sing-box DNS rules, as sing-box JSON, checked before the generated ones. Kept when the
          route mode is all-proxy or all-bypass, which drop the generated ones.
        '';
        example = [
          {
            domain_suffix = [ "corp.example" ];
            server = "corp";
          }
        ];
      };
    };
  };
}
