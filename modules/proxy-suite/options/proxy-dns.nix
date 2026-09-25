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
      # TCP: DPI boxes answer plain UDP queries to well-known resolvers themselves, with
      # NXDOMAIN or a stub address for blocked names, so direct traffic (zapret's
      # included) dials nothing. Not tls, which pure XRay lacks.
      default = cloudflare // {
        type = "tcp";
      };
      description = ''
        Resolver for direct traffic. In global TUN mode it goes through the proxy. TCP by default,
        because ISP DPI often fakes UDP answers from well-known resolvers, which breaks zapret.
      '';
      example = {
        type = "tls";
        address = "1.1.1.1";
        port = 853;
      };
    };

    remote = mkOption {
      type = t.dnsUpstreamType;
      default = cloudflare;
      description = ''
        Resolver reached through the proxy. On sing-box, proxied names are always resolved here,
        so the ISP never sees them. Also the default resolver when `proxy.routing.default` is "proxy".
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
      description = "Which IP versions to resolve. Use `ipv4_only` if the uplink has no IPv6. sing-box and hybrid only.";
      example = "ipv4_only";
    };

    clientSubnet = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        EDNS client subnet sent with every query, so CDNs pick servers near you even through the
        proxy. sing-box and hybrid only.
      '';
      example = "203.0.113.0/24";
    };

    fakeIp = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Answer DNS in TUN mode with fake addresses that sing-box maps back to names. Saves a
          lookup per new site, and proxied names are never resolved locally. Direct names and those
          matched by `proxy.dns.singBox.rules` still get real answers. sing-box and hybrid only;
          XRay's TUN has its own fake DNS.
        '';
      };

      inet4Range = mkOption {
        type = types.str;
        default = "198.18.0.0/15";
        description = "Address range for fake IPs.";
      };
    };

    singBox = {
      servers = mkOption {
        type = types.listOf types.attrs;
        default = [ ];
        description = ''
          Extra DNS servers in sing-box JSON, for use in `proxy.dns.singBox.rules`. Built-in
          servers: `local`, `remote`, and `fakeip` when fake IP is on.
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
          DNS rules in sing-box JSON, checked before the generated ones. Unlike those, they stay
          active in the all-proxy and all-bypass modes.
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
