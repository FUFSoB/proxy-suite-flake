# All option declarations for services.proxy-suite
{ config, lib, ... }:

let
  inherit (lib) mkOption mkEnableOption types;

  # Shared routing-rule fields (reused in both outboundType.routing and routing.rules entries)
  routingFields = {
    domains = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Domain suffixes to match in this routing rule.
        Leave empty to skip domain-based matching for this rule entry.
      '';
      example = [
        "youtube.com"
        "discord.com"
      ];
    };
    ips = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        IP CIDRs to match in this routing rule.
        Leave empty to skip IP-based matching for this rule entry.
      '';
      example = [ "1.1.1.0/24" ];
    };
    geosites = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        sing-geosite rule-set names to match in this routing rule.
        Each name becomes a sing-box geosite rule-set reference.
      '';
      example = [
        "netflix"
        "google"
      ];
    };
    geoips = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        sing-geoip rule-set names to match in this routing rule.
        Each name becomes a sing-box geoip rule-set reference.
      '';
      example = [
        "us"
        "de"
      ];
    };
  };

  # An explicit routing rule – associates traffic patterns with a named outbound.
  routingRuleType = types.submodule {
    options = {
      outbound = mkOption {
        type = types.str;
        description = ''
          Target outbound tag. Can be a specific server tag (only useful with
          selection = "selector" or "urltest"), or one of the built-in tags:
          "proxy" (the active proxy outbound), "direct", "block".

          With selection = "first", named proxy outbounds are collapsed into the
          single active "proxy" outbound at runtime, so per-tag routing no longer
          distinguishes between individual proxy servers.
        '';
        example = "vps-de";
      };
    }
    // routingFields;
  };

  subscriptionType = types.submodule {
    options = {
      tag = mkOption {
        type = types.str;
        description = ''
          Unique identifier for this subscription.
          Used as a prefix for all outbound tags generated from its proxy list,
          e.g. "my-sub" -> tags like "my-sub-Server-DE".
        '';
        example = "community-list";
      };

      url = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Literal subscription URL. The response must be a base64-encoded
          newline-separated list of proxy URIs (standard v2rayN format) or
          a plain-text list of the same.

          This value is embedded in the Nix store. Prefer urlFile for private
          subscription links or tokens.
        '';
        example = "https://example.com/sub/token123";
      };

      urlFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Runtime path to a file containing the subscription URL.
          Intended for use with secret managers (sops-nix, agenix, etc.).
          The file is read at service start time and never lands in the Nix store.

          Set exactly one of urlFile or url for each subscription entry.
        '';
        example = "/run/secrets/proxy-subscription-url";
      };
    };
  };

  outboundType = types.submodule {
    options = {
      tag = mkOption {
        type = types.str;
        description = ''
          Outbound tag used in routing rules and multi-outbound selection.

          With selection = "selector" or "urltest", each outbound keeps its own
          tag and can be selected directly. With selection = "first", sing-box
          routes through a single active outbound tagged "proxy", so individual
          proxy tags are mainly useful for documentation and config structure.
        '';
        example = "vps-de";
      };

      urlFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Runtime path to a file containing the proxy URL.
          Intended for use with secret managers (sops-nix, agenix, etc.).
          The file is read at service start time and never lands in the Nix store.

          Set exactly one of urlFile, url, or json for each outbound.
        '';
        example = "/run/secrets/my-proxy-url";
      };

      url = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Literal proxy URL. Convenient for non-secret configs, but the URL
          will end up in the Nix store.

          Set exactly one of urlFile, url, or json for each outbound.
          Prefer urlFile for real credentials.
        '';
        example = "hy2://password@example.com:443?sni=example.com";
      };

      json = mkOption {
        type = types.nullOr types.attrs;
        default = null;
        description = ''
          Raw sing-box outbound configuration as a Nix attribute set.
          Embedded directly into the config at build time. The tag field
          is overridden by the outbound's tag option.

          Set exactly one of urlFile, url, or json for each outbound.
          Use this when the proxy definition is easier to generate as native Nix
          than as a single URL string.
        '';
        example = {
          type = "vless";
          server = "example.com";
          server_port = 443;
          uuid = "...";
        };
      };

      # Shorthand for attaching routing rules directly to an outbound definition.
      # Traffic matching these patterns is sent to this specific outbound.
      # Only meaningful when selection = "selector" or "urltest" (with "first",
      # all proxy traffic goes to the single "proxy" outbound anyway).
      routing = routingFields;
    };
  };

  dnsUpstreamType = types.submodule {
    options = {
      type = mkOption {
        type = types.enum [
          "udp"
          "tcp"
          "tls"
        ];
        default = "udp";
        description = ''
          sing-box DNS transport type for this upstream resolver.
        '';
        example = "tls";
      };

      address = mkOption {
        type = types.strMatching ".+";
        description = ''
          Resolver address or hostname used for this DNS upstream.
        '';
        example = "1.1.1.1";
      };

      port = mkOption {
        type = types.port;
        default = 53;
        description = ''
          Destination port for this DNS upstream.
        '';
        example = 853;
      };
    };
  };

  zapretPresetType = types.enum [
    "general"
    "google"
    "instagram"
    "soundcloud"
    "twitter"
  ];

  zapretHostlistRuleType = types.submodule {
    options = {
      name = mkOption {
        type = types.strMatching "^[a-z0-9][a-z0-9-]*$";
        description = ''
          Custom hostlist name. Used to generate hostlists/list-<name>.txt
          inside the derived zapret config directory.
        '';
        example = "cloudflare";
      };

      domains = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Domains written into the generated custom zapret hostlist file.
          Must be non-empty for every hostlistRules entry.
        '';
        example = [
          "example.com"
          "example.de"
        ];
      };

      preset = mkOption {
        type = types.nullOr zapretPresetType;
        default = null;
        description = ''
          Clone the active zapret config's built-in NFQWS rule family for this
          hostlist. Can be combined with nfqwsArgs for additional custom rules.
        '';
        example = "google";
      };

      nfqwsArgs = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Additional NFQWS argument fragments for this hostlist.
          The module injects --hostlist=... and trailing --new automatically.

          Each hostlistRules entry must define preset, nfqwsArgs, or both.
        '';
        example = [
          "--filter-tcp=443 --dpi-desync=fake,multisplit"
        ];
      };

      enableDirectSync = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether this custom hostlist should also be mirrored into sing-box
          direct domain routing when zapret.syncDirectRouting = true.
        '';
      };
    };
  };

  appRoutingProfileType = types.submodule {
    options = {
      name = mkOption {
        type = types.strMatching "^[a-z0-9][a-z0-9-]*$";
        description = ''
          Profile name used by `proxy-ctl wrap <name> -- <command>`.
          Must be unique within appRouting.profiles.
        '';
        example = "steam-browser";
      };

      route = mkOption {
        type = types.enum [
          "direct"
          "proxychains"
          "tun"
          "tproxy"
          "zapret"
        ];
        default = "proxychains";
        description = ''
          Per-app route backend used by proxy-ctl wrap.

          - "direct": run the command unchanged.
          - "proxychains": run the command through proxychains-ng using the
            local proxy-suite mixed SOCKS endpoint.
          - "tun": launch the command in the dedicated app-routing TUN slice so
            only that app's traffic is policy-routed into the app TUN backend.
          - "tproxy": launch the command in the dedicated app-routing TProxy
            slice so only that app's traffic is transparently intercepted by
            the local sing-box TProxy inbound.
          - "zapret": launch the command in the dedicated app-routing zapret
            slice so only that app's traffic is handled by the separate
            app-scoped zapret instance.

          Additional route backends may be added in the future.
        '';
        example = "proxychains";
      };
    };
  };

in
{
  options.services.proxy-suite = {
    enable = mkEnableOption "proxy suite (sing-box + zapret + tg-ws-proxy)";

    userControl = {
      group = mkOption {
        type = types.strMatching "^[a-z_][a-z0-9_-]*$";
        default = "proxy-suite";
        description = ''
          Local group allowed to use passwordless polkit-backed `proxy-ctl`
          commands when userControl.global.enable or userControl.perApp.enable
          is turned on.
        '';
        example = "proxy-suite";
      };

      global.enable =
        (mkEnableOption "passwordless proxy-ctl control over global proxy-suite units")
        // {
          default = true;
          description = ''
            Whether members of userControl.group may manage global
            proxy-suite units without password prompts via commands like
            `proxy-ctl tun on|off`, `proxy-ctl tproxy on|off`,
            `proxy-ctl restart`, or `proxy-ctl subscription update`.
          '';
        };

      perApp.enable =
        (mkEnableOption "passwordless proxy-ctl control over per-app routing helpers")
        // {
          default = true;
          description = ''
            Whether members of userControl.group may start and stop the
            app-scoped backend units used by `proxy-ctl wrap ...` for
            route = "tun", route = "tproxy", or route = "zapret" profiles
            without password prompts.
          '';
        };
    };

    singBox = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether to configure and run sing-box services for proxy-suite.
          When disabled, singBox.* options are ignored even if proxy-suite itself
          is enabled.
        '';
      };

      outbounds = mkOption {
        type = types.listOf outboundType;
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
        type = types.listOf subscriptionType;
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

        tproxyPort = mkOption {
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
            Mark applied to intercepted packets in TProxy mode.
            A matching `ip rule` routes this mark to singBox.routeTable, which
            points traffic to loopback for local proxy processing.
          '';
          example = 1;
        };

        proxyMark = mkOption {
          type = types.int;
          default = 2;
          description = ''
            Mark applied to sing-box egress packets in TProxy mode so they bypass
            re-interception and do not loop back into the transparent proxy path.
          '';
          example = 2;
        };

        routeTable = mkOption {
          type = types.int;
          default = 100;
          description = ''
            Policy-routing table number used for TProxy interception flow.
            The module installs a local default route in this table and binds it
            to singBox.fwmark.
          '';
          example = 100;
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
          type = dnsUpstreamType;
          default = {
            type = "udp";
            address = "1.1.1.1";
            port = 53;
          };
          description = ''
            DNS upstream used for the built-in "local" resolver role.
            This resolver is also used as sing-box route.default_domain_resolver.

            The module keeps detour policy automatic: in mixed/TProxy mode and
            app-routing TUN mode, "local" stays on the direct path (without an
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
          type = dnsUpstreamType;
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
        enable = mkEnableOption "TUN mode service (opt-in, mutually exclusive with proxy-suite-tproxy)";

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

        interface = mkOption {
          type = types.str;
          default = "singtun0";
          description = "Name of the TUN interface created by proxy-suite-tun.";
          example = "singtun0";
        };

        address = mkOption {
          type = types.str;
          default = "172.19.0.1/30";
          description = "Address assigned to the TUN interface in CIDR notation.";
          example = "172.19.0.1/30";
        };

        mtu = mkOption {
          type = types.int;
          default = 1400;
          description = "MTU for the TUN interface created by proxy-suite-tun.";
          example = 1400;
        };
      };

      tproxy = {
        enable = mkEnableOption "TProxy mode service (opt-in, transparent proxy via nftables)";

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

        localSubnets = mkOption {
          type = types.listOf types.str;
          default = [ "192.168.0.0/16" ];
          description = ''
            Subnets whose traffic bypasses TProxy interception, except DNS (port 53).

            Typically this should include your LAN subnet(s). VM bridge networks
            should usually go here too, or use zapret.cidrExemption for
            subnet-specific NFQUEUE exemption on the zapret side.
          '';
          example = [
            "192.168.0.0/16"
            "10.0.0.0/8"
          ];
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

        proxy = routingFields;

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
          type = types.listOf routingRuleType;
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

    appRouting = {
      enable = mkEnableOption "per-app routing helpers via proxy-ctl wrap";

      createDefaultProfiles = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to automatically add curated appRouting profiles.

          This is opt-in. Generated defaults are appended only when no
          user-defined profile with the same name already exists.

          Current curated defaults:
          - `proxychains`: route = "proxychains"
          - `tun`: route = "tun" when appRouting.backends.tun.enable = true
          - `tproxy`: route = "tproxy" when appRouting.backends.tproxy.enable = true
          - `zapret`: route = "zapret" when appRouting.backends.zapret.enable = true
            and zapret.enable = true

          This makes `proxy-ctl wrap proxychains -- <command>` available
          without defining the profile manually, and similarly exposes
          `proxy-ctl wrap tun -- <command>` or
          `proxy-ctl wrap tproxy -- <command>` or
          `proxy-ctl wrap zapret -- <command>` when the corresponding backend
          is enabled.
        '';
        example = true;
      };

      profiles = mkOption {
        type = types.listOf appRoutingProfileType;
        default = [ ];
        description = ''
          Named per-app route profiles consumed by `proxy-ctl wrap`.

          This initial implementation supports:
          - "direct" for running a command unchanged
          - "proxychains" for TCP apps that can use an LD_PRELOAD wrapper
            instead of global TUN or TProxy interception
          - "tun" for app-scoped policy routing into the dedicated app TUN
            backend
          - "tproxy" for app-scoped transparent interception through the
            dedicated app TProxy backend
          - "zapret" for app-scoped zapret handling through a separate
            zapret instance without changing the app's network path or exit IP

          proxychains-based wrapping depends on the local proxy-suite mixed
          proxy listener provided by sing-box. The "tun" route depends on
          appRouting.backends.tun.enable = true. The "tproxy" route depends on
          appRouting.backends.tproxy.enable = true. The "zapret" route depends
          on appRouting.backends.zapret.enable = true and zapret.enable = true.

          When createDefaultProfiles = true, curated defaults are added on top
          of this list unless a user-defined profile already uses the same
          name.
        '';
        example = [
          {
            name = "steam-browser";
            route = "proxychains";
          }
          {
            name = "native-direct";
            route = "direct";
          }
        ];
      };

      proxychains = {
        enable = mkEnableOption "proxychains-backed appRouting profiles";

        quiet = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Whether generated proxychains wrappers should suppress their normal
            startup chatter. This maps to proxychains-ng quiet_mode.
          '';
          example = true;
        };

        proxyDns = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Whether generated proxychains wrappers should resolve DNS through
            the proxy instead of the local resolver. This maps to proxychains-ng
            proxy_dns.
          '';
          example = true;
        };
      };

      backends = {
        tun = {
          enable = mkEnableOption "app-scoped TUN backend for appRouting profiles";

          interface = mkOption {
            type = types.str;
            default = "psapptun0";
            description = ''
              Name of the dedicated app-routing TUN interface used by
              proxy-suite-app-tun.
            '';
            example = "psapptun0";
          };

          address = mkOption {
            type = types.str;
            default = "172.20.0.1/30";
            description = ''
              Address assigned to the app-routing TUN interface in CIDR
              notation.
            '';
            example = "172.20.0.1/30";
          };

          mtu = mkOption {
            type = types.int;
            default = 1400;
            description = ''
              MTU for the app-routing TUN interface.
            '';
            example = 1400;
          };

          fwmark = mkOption {
            type = types.int;
            default = 16;
            description = ''
              Packet mark used to steer wrapped app traffic into the app-routing
              TUN policy-routing table.
            '';
            example = 16;
          };

          routeTable = mkOption {
            type = types.int;
            default = 101;
            description = ''
              Policy-routing table used by the app-routing TUN backend.
            '';
            example = 101;
          };

          localSubnets = mkOption {
            type = types.listOf types.str;
            default = [ "192.168.0.0/16" ];
            description = ''
              Destination subnets that should bypass the app-routing TUN mark,
              so wrapped apps can still reach local LAN resources directly.
            '';
            example = [
              "192.168.0.0/16"
              "10.0.0.0/8"
            ];
          };
        };

        tproxy = {
          enable = mkEnableOption "app-scoped TProxy backend for appRouting profiles";

          fwmark = mkOption {
            type = types.int;
            default = 17;
            description = ''
              Packet mark used to steer wrapped app traffic into the app-routing
              TProxy policy-routing table.
            '';
            example = 17;
          };

          routeTable = mkOption {
            type = types.int;
            default = 102;
            description = ''
              Policy-routing table used by the app-routing TProxy backend.
            '';
            example = 102;
          };

          localSubnets = mkOption {
            type = types.listOf types.str;
            default = [ "192.168.0.0/16" ];
            description = ''
              Destination subnets that should bypass app-routing TProxy
              interception, except DNS traffic on port 53.
            '';
            example = [
              "192.168.0.0/16"
              "10.0.0.0/8"
            ];
          };
        };

        zapret = {
          enable = mkEnableOption "app-scoped zapret backend for appRouting profiles";

          filterMark = mkOption {
            type = types.int;
            default = 268435456;
            description = ''
              Packet mark bit used to mark wrapped app traffic for the
              dedicated app-scoped zapret instance.
            '';
            example = 268435456;
          };

          qnum = mkOption {
            type = types.int;
            default = 201;
            description = ''
              NFQUEUE number used by the dedicated app-scoped zapret instance.
              This backend runs as a second zapret daemon and should use a
              queue distinct from the global zapret instance.
            '';
            example = 201;
          };
        };
      };

    };

    zapret = {
      enable = mkEnableOption "zapret DPI bypass";

      syncDirectRouting = mkOption {
        type = types.bool;
        default = true;
        description = ''
          When zapret.enable = true, mirror zapret's upstream domain hostlists
          into sing-box direct domain routing.

          This includes the default zapret domain lists and any custom
          hostlistRules entries with enableDirectSync = true.
        '';
        example = true;
      };

      syncDirectRoutingUpstreamIps = mkOption {
        type = types.bool;
        default = false;
        description = ''
          When zapret.enable = true, mirror zapret's upstream ipset ranges
          (such as ipset-all.txt minus exclusions) into sing-box direct IP routing.
        '';
        example = false;
      };

      syncDirectRoutingUserIps = mkOption {
        type = types.bool;
        default = true;
        description = ''
          When zapret.enable = true, mirror user-defined zapret.ipsetAll and
          zapret.ipsetExclude entries into sing-box direct IP routing.
        '';
        example = true;
      };

      configName = mkOption {
        type = types.str;
        default = "general(ALT)";
        description = "zapret strategy preset name passed through to the generated zapret configuration.";
        example = "general(ALT)";
      };

      gameFilter = mkOption {
        type = types.str;
        default = "null";
        description = ''zapret game traffic filter mode: "all", "tcp", "udp", or "null" to disable.'';
        example = "null";
      };

      listGeneral = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Extra domains to include in zapret's interception list.
          When syncDirectRouting = true, these domains are also mirrored into
          sing-box direct routing.
        '';
        example = [ "youtube.com" ];
      };

      listExclude = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Domains to exclude from zapret interception.
          When syncDirectRouting = true, these exclusions also remove matching
          domains from the zapret-derived sing-box direct-routing set.
        '';
        example = [ "music.youtube.com" ];
      };

      ipsetAll = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Extra IPs/CIDRs to add to zapret's ipset.
          Mirrored into sing-box direct IP routing when
          syncDirectRoutingUserIps = true.
        '';
        example = [ "203.0.113.0/24" ];
      };

      ipsetExclude = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          IPs/CIDRs to exclude from zapret's ipset.
          Also excluded from zapret-derived sing-box direct IP routing when
          syncDirectRoutingUserIps = true.
        '';
        example = [ "203.0.113.10/32" ];
      };

      includeExtraUpstreamLists = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Automatically activate upstream list-instagram.txt, list-soundcloud.txt,
          and list-twitter.txt in the generated zapret config when the selected
          upstream preset does not already reference them.

          When syncDirectRouting = true, domains from these extra lists are also
          mirrored into sing-box direct routing.
        '';
        example = false;
      };

      hostlistRules = mkOption {
        type = types.listOf zapretHostlistRuleType;
        default = [ ];
        description = ''
          Additional named zapret hostlists with per-list DPI mitigation rules.
          Each entry generates hostlists/list-<name>.txt and can clone a built-in
          zapret family, add custom NFQWS rule fragments, or both.

          Each entry must define at least one domain and at least one of preset
          or nfqwsArgs.
        '';
        example = [
          {
            name = "googlevideo";
            domains = [
              "googlevideo.com"
              "ggpht.com"
            ];
            preset = "google";
          }
          {
            name = "example";
            domains = [
              "example.com"
              "example.de"
            ];
            preset = "general";
            nfqwsArgs = [
              "--filter-tcp=443 --dpi-desync=fake,multisplit"
            ];
          }
        ];
      };

      cidrExemption = {
        enable = mkEnableOption "CIDR exemption from zapret NFQUEUE";

        cidrs = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [
            "192.168.123.0/24"
            "10.0.0.0/8"
          ];
          description = ''
            Subnets to exempt from zapret's NFQUEUE mangle rules.
            Useful when a VM (libvirt, etc.) is behind NAT and zapret
            would corrupt its traffic through the host's nftables.
          '';
        };
      };
    };

    tray = {
      enable = mkEnableOption "system tray indicator for proxy-suite";

      pollInterval = mkOption {
        type = types.int;
        default = 5;
        description = ''
          Tray status refresh interval in seconds.
          Lower values make UI state changes appear faster, while higher values
          reduce background polling overhead.
        '';
        example = 5;
      };

      autostart = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether to install an XDG autostart entry for the tray application
          for graphical users.
        '';
        example = true;
      };
    };

    tgWsProxy = {
      enable = mkEnableOption "Telegram MTProto WebSocket proxy";

      port = mkOption {
        type = types.port;
        default = 1076;
        description = ''
          TCP listen port for tg-ws-proxy.
          Telegram clients connect to this endpoint when using the local MTProto
          WebSocket proxy.
        '';
        example = 1076;
      };

      host = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = ''
          Bind address for tg-ws-proxy.
          Keep `127.0.0.1` for local-only usage; bind to `0.0.0.0` only when you
          intentionally expose the proxy to other hosts.
        '';
        example = "127.0.0.1";
      };

      secret = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          MTProto proxy secret (hex string). Legacy inline form; this value ends up
          in the Nix store. Prefer secretFile for real deployments.

          Set exactly one of secret or secretFile when tgWsProxy.enable = true.
          Generate one with: openssl rand -hex 16
        '';
        example = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
      };

      secretFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Runtime path to a file containing the MTProto proxy secret.
          Intended for use with secret managers so the secret stays out of the Nix store.

          Set exactly one of secretFile or secret when tgWsProxy.enable = true.
        '';
        example = "/run/secrets/tg-ws-proxy-secret";
      };

      dcIps = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = ''
          Mapping of Telegram DC IDs to relay IPs.
          Keys are DC IDs as strings and values are IPv4/IPv6 addresses used by
          tg-ws-proxy for MTProto relay selection.
        '';
        example = {
          "2" = "149.154.167.220";
          "4" = "149.154.167.220";
          "203" = "149.154.167.220";
        };
      };
    };
  };
}
