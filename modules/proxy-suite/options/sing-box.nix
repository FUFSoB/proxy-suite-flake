# sing-box proxy client options.
{ lib, ... }:

let
  inherit (lib) mkOption mkEnableOption types;
  t = import ./types.nix { inherit lib; };

  mkTunCommonFields =
    {
      interfaceDefault,
      interfaceDescription,
      addressDefault,
      addressDescription,
      mtuDefault,
      mtuDescription,
    }:
    {
      interface = mkOption {
        type = types.str;
        default = interfaceDefault;
        description = interfaceDescription;
        example = interfaceDefault;
      };

      address = mkOption {
        type = types.str;
        default = addressDefault;
        description = addressDescription;
        example = addressDefault;
      };

      mtu = mkOption {
        type = types.int;
        default = mtuDefault;
        description = mtuDescription;
        example = mtuDefault;
      };
    };
in
{
  options.services.proxy-suite.singBox = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to configure and run sing-box services for proxy-suite.
        When disabled, sing-box services and generated sing-box configs are
        skipped even if proxy-suite itself is enabled.
      '';
    };

    outbounds = mkOption {
      type = types.listOf t.outboundType;
      default = [ ];
      description = ''
        List of static proxy outbounds.
        Set exactly one of urlFile, url, or json per entry.

        At least one outbound or one subscription is required when
        singBox.enable = true.
      '';
      example = [
        {
          tag = "de-vps";
          urlFile = "/run/secrets/proxy-de-url";
        }
        {
          tag = "nl-vps";
          url = "hy2://password@example.com:443?sni=example.com";
        }
      ];
    };

    subscriptions = mkOption {
      type = types.listOf t.subscriptionType;
      default = [ ];
      description = ''
        Subscription URLs that provide dynamic lists of proxy outbounds.
        Each URL must return a base64-encoded newline-separated list of proxy URIs
        (standard v2rayN / Clash subscription format) or plain text of the same.

        On first service start, each subscription is fetched live and cached
        under /var/lib/proxy-suite/subscriptions/<tag>.json. Later restarts
        reuse the cache, so ordinary service restarts do not need network access.

        A systemd timer (proxy-suite-subscription-update) refreshes all caches on
        the interval set by subscriptionUpdateInterval and restarts the running
        sing-box services after a successful refresh.
      '';
      example = [
        {
          tag = "community";
          url = "https://example.com/sub/token";
        }
        {
          tag = "private";
          urlFile = "/run/secrets/private-sub-url";
        }
      ];
    };

    subscriptionUpdateInterval = mkOption {
      type = types.str;
      default = "1d";
      description = ''
        How often the proxy-suite-subscription-update timer fires and refreshes
        all subscription caches. Accepts any systemd time span string
        (e.g. "1h", "6h", "1d", "12h").

        Only used when singBox.subscriptions is non-empty. The timer also runs
        once shortly after boot.
      '';
      example = "6h";
    };

    selection = mkOption {
      type = types.enum [
        "first"
        "selector"
        "urltest"
      ];
      default = "first";
      description = ''
        How to pick between multiple proxy outbounds:

        - "first": route through a single active outbound tagged "proxy".
          The first static outbound is used, or the first subscription
          outbound if only subscriptions are configured.
        - "selector": create a Clash-compatible selector outbound tagged
          "proxy" and keep all configured outbounds available for manual
          switching via the Clash API.
        - "urltest": create an automatic latency-testing outbound tagged
          "proxy" and keep all configured outbounds available so sing-box
          can periodically probe and switch to a faster one.

        clashApiPort is only used with "selector" or "urltest".
        urlTest.* options are only used with "urltest".
        Per-outbound tags are only individually meaningful with "selector"
        or "urltest".
      '';
      example = "urltest";
    };

    urlTest = {
      url = mkOption {
        type = types.str;
        default = "https://www.gstatic.com/generate_204";
        description = ''
          URL that sing-box fetches through each proxy to measure latency.
          Only used when selection = "urltest".

          Set this to a URL that is actually blocked in your region (e.g.
          "https://telegram.org") so that only proxies that bypass the
          blocking get selected. If left at the default, any responding proxy
          wins – including ones that might not unblock your target site.
        '';
        example = "https://telegram.org";
      };

      interval = mkOption {
        type = types.str;
        default = "3m";
        description = ''
          How often sing-box re-tests all outbounds. Accepts a Go duration
          string (e.g. "1m", "3m", "10m").
          Only used when selection = "urltest".
        '';
        example = "1m";
      };

      tolerance = mkOption {
        type = types.int;
        default = 50;
        description = ''
          Latency tolerance in milliseconds. The current proxy is only replaced
          when a competing one is faster by more than this value.

          Only used when selection = "urltest".
        '';
        example = 100;
      };
    };

    clashApiPort = mkOption {
      type = types.port;
      default = 9090;
      description = ''
        Port for the Clash-compatible REST API exposed by sing-box.
        Only used when selection is "selector" or "urltest". Ignored in
        "first" mode because there is no selector-style outbound to control.
      '';
      example = 9090;
    };

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = ''
        Address for the SOCKS5/HTTP mixed inbound to bind to.
        This affects the always-on proxy-suite-socks service.

        Use "0.0.0.0" only if you intentionally want to expose the proxy to
        other machines on your network.
      '';
      example = "127.0.0.1";
    };

    port = mkOption {
      type = types.port;
      default = 1080;
      description = ''
        Listen port for the always-on SOCKS5/HTTP mixed inbound provided by
        proxy-suite-socks.
      '';
      example = 1080;
    };

    proxyByDefault = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether traffic that does not match any explicit routing rule should
        go through the proxy or go direct.

        This affects sing-box route.final and dns.final in the generated
        config.
      '';
      example = true;
    };

    dns = {
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

    tun = {
      enable = mkEnableOption "global sing-box TUN mode service";

      autostart = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to start proxy-suite-tun automatically during boot by
          attaching it to multi-user.target.
          Cannot be enabled together with singBox.tproxy.autostart.
        '';
        example = true;
      };

      perApp = {
        enable = mkEnableOption "per-app-scoped sing-box TUN backend for perAppRouting profiles";

        fwmark = mkOption {
          type = types.int;
          default = 16;
          description = ''
            Packet mark used to steer wrapped app traffic into the per-app-scoped
            TUN policy-routing table.
          '';
          example = 16;
        };

        routeTable = mkOption {
          type = types.int;
          default = 101;
          description = ''
            Policy-routing table used by the per-app-scoped TUN backend.
          '';
          example = 101;
        };

        localSubnets = mkOption {
          type = types.listOf types.str;
          default = [ "192.168.0.0/16" ];
          description = ''
            Destination subnets that should bypass the per-app-scoped TUN mark,
            so wrapped apps can still reach local LAN resources directly.
          '';
          example = [
            "192.168.0.0/16"
            "10.0.0.0/8"
          ];
        };
      }
      // mkTunCommonFields {
        interfaceDefault = "psperapptun0";
        interfaceDescription = ''
          Name of the dedicated per-app-routing TUN interface used by
          proxy-suite-per-app-tun.
        '';
        addressDefault = "172.20.0.1/30";
        addressDescription = ''
          Address assigned to the dedicated per-app-routing TUN interface in CIDR
          notation.
        '';
        mtuDefault = 1400;
        mtuDescription = "MTU for the dedicated per-app-routing TUN interface.";
      };
    }
    // mkTunCommonFields {
      interfaceDefault = "singtun0";
      interfaceDescription = "Name of the TUN interface created by proxy-suite-tun.";
      addressDefault = "172.19.0.1/30";
      addressDescription = "Address assigned to the global TUN interface in CIDR notation.";
      mtuDefault = 1400;
      mtuDescription = "MTU for the global TUN interface created by proxy-suite-tun.";
    };

    tproxy = {
      enable = mkEnableOption "global sing-box TProxy mode service";

      autostart = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to start proxy-suite-tproxy automatically during boot by
          attaching it to multi-user.target.
          Cannot be enabled together with singBox.tun.autostart.
        '';
        example = true;
      };

      port = mkOption {
        type = types.port;
        default = 1081;
        description = ''
          Local listen port for sing-box's TProxy inbound.
          nftables redirection created by proxy-suite-tproxy sends intercepted
          TCP/UDP traffic to this port.
        '';
        example = 1081;
      };

      fwmark = mkOption {
        type = types.int;
        default = 1;
        description = ''
          Mark applied to intercepted packets in global TProxy mode.
          A matching `ip rule` routes this mark to
          singBox.tproxy.routeTable, which points traffic to
          loopback for local proxy processing.
        '';
        example = 1;
      };

      proxyMark = mkOption {
        type = types.int;
        default = 2;
        description = ''
          Mark applied to sing-box egress packets in global TProxy mode so
          they bypass re-interception and do not loop back into the
          transparent proxy path.
        '';
        example = 2;
      };

      routeTable = mkOption {
        type = types.int;
        default = 100;
        description = ''
          Policy-routing table number used for global TProxy interception flow.
          The module installs a local default route in this table and binds it
          to singBox.tproxy.fwmark.
        '';
        example = 100;
      };

      localSubnets = mkOption {
        type = types.listOf types.str;
        default = [ "192.168.0.0/16" ];
        description = ''
          Subnets whose traffic bypasses global TProxy interception, except
          DNS (port 53).

          Typically this should include your LAN subnet(s). VM bridge networks
          should usually go here too, or use zapret.cidrExemption for
          subnet-specific NFQUEUE exemption on the zapret side.
        '';
        example = [
          "192.168.0.0/16"
          "10.0.0.0/8"
        ];
      };

      perApp = {
        enable = mkEnableOption "per-app-scoped sing-box TProxy backend for perAppRouting profiles";

        fwmark = mkOption {
          type = types.int;
          default = 17;
          description = ''
            Packet mark used to steer wrapped app traffic into the per-app-scoped
            TProxy policy-routing table.
          '';
          example = 17;
        };

        routeTable = mkOption {
          type = types.int;
          default = 102;
          description = ''
            Policy-routing table used by the per-app-scoped TProxy backend.
          '';
          example = 102;
        };

        localSubnets = mkOption {
          type = types.listOf types.str;
          default = [ "192.168.0.0/16" ];
          description = ''
            Subnets whose traffic bypasses per-app-scoped TProxy interception,
            except DNS (port 53).
          '';
          example = [
            "192.168.0.0/16"
            "10.0.0.0/8"
          ];
        };
      };
    };

    routing = {
      enableRuDirect = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Automatically append "category-ru" to routing.direct.geosites and
          "ru" to routing.direct.geoips.

          This is additive: user-defined routing.direct.* entries still apply.
        '';
        example = true;
      };

      proxy = t.routingFields;

      direct = {
        domains = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = ''
            Domain suffixes to send direct (bypass proxy).
            Merged with zapret-synced direct domains when zapret direct sync
            options are enabled.
          '';
          example = [ "internal.example" ];
        };
        ips = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = ''
            IP CIDRs to send direct.
            Merged with zapret-synced direct IPs when the corresponding zapret
            sync options are enabled.
          '';
          example = [ "10.10.0.0/16" ];
        };
        geosites = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = ''
            sing-geosite names to send direct.
            "category-ru" is added automatically when enableRuDirect = true.
          '';
          example = [ "category-ru" ];
        };
        geoips = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = ''
            sing-geoip names to send direct.
            "ru" is added automatically when enableRuDirect = true.
          '';
          example = [ "ru" ];
        };
      };

      block = {
        domains = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Domain suffixes to block entirely.";
          example = [ "ads.example.com" ];
        };
        ips = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "IP CIDRs to block.";
          example = [ "203.0.113.0/24" ];
        };
        geosites = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "sing-geosite names to block.";
          example = [ "category-ads-all" ];
        };
        geoips = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "sing-geoip names to block.";
          example = [ "cn" ];
        };
      };

      # Per-outbound routing rules evaluated before global proxy/direct/block lists.
      # Equivalent to setting outbound.routing.* directly on each outbound definition.
      rules = mkOption {
        type = types.listOf t.routingRuleType;
        default = [ ];
        description = ''
          Explicit routing rules evaluated before global proxy/direct/block lists.
          Each rule routes matching traffic to a specific outbound tag.

          The outbound can be a configured outbound tag (useful with selector/urltest),
          or one of: "proxy" (active proxy), "direct", "block".

          Order is preserved. The first matching rule wins in sing-box.
          With selection = "first", non-built-in outbound tags are effectively
          routed to the single active "proxy" outbound.
        '';
        example = [
          {
            outbound = "vps-de";
            domains = [ "netflix.com" ];
            geosites = [ "netflix" ];
          }
          {
            outbound = "direct";
            domains = [ "internal.corp" ];
          }
          {
            outbound = "block";
            domains = [ "ads.example.com" ];
          }
        ];
      };
    };
  };
}
