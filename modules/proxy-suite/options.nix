# All option declarations for services.proxy-suite
{ config, lib, ... }:

let
  inherit (lib) mkOption mkEnableOption types;

  # Shared routing-rule fields (reused in both outboundType.routing and routing.rules entries)
  routingFields = {
    domains = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Domain suffixes to match.";
      example = [
        "youtube.com"
        "discord.com"
      ];
    };
    ips = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "IP CIDRs to match.";
      example = [ "1.1.1.0/24" ];
    };
    geosites = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "sing-geosite rule-set names to match.";
      example = [
        "netflix"
        "google"
      ];
    };
    geoips = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "sing-geoip rule-set names to match.";
      example = [
        "us"
        "de"
      ];
    };
  };

  # An explicit routing rule — associates traffic patterns with a named outbound.
  routingRuleType = types.submodule {
    options = {
      outbound = mkOption {
        type = types.str;
        description = ''
          Target outbound tag. Can be a specific server tag (only useful with
          selection = "selector" or "urltest"), or one of the built-in tags:
          "proxy" (the active proxy outbound), "direct", "block".
        '';
        example = "vps-de";
      };
    }
    // routingFields;
  };

  outboundType = types.submodule {
    options = {
      tag = mkOption {
        type = types.str;
        description = "Outbound tag. Used in routing rules and multi-outbound selection.";
        example = "vps-de";
      };

      urlFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Runtime path to a file containing the proxy URL.
          Intended for use with secret managers (sops-nix, agenix, etc.).
          The file is read at service start time and never lands in the nix store.

          Example with sops-nix:
            urlFile = config.sops.secrets.my_proxy_url.path;
        '';
      };

      url = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Literal proxy URL. Convenient for non-secret configs, but the URL
          will end up in the nix store. Use urlFile for actual credentials.
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
        description = "Custom hostlist name. Used to generate list-<name>.txt.";
        example = "cloudflare";
      };

      domains = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Domains written into the generated custom zapret hostlist.";
        example = [
          "example.com"
          "example.de"
        ];
      };

      preset = mkOption {
        type = types.nullOr zapretPresetType;
        default = null;
        description = "Clone the active zapret config's built-in rule family for this hostlist.";
        example = "google";
      };

      nfqwsArgs = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Additional NFQWS argument fragments for this hostlist.
          The module injects --hostlist=... and trailing --new automatically.
        '';
        example = [
          "--filter-tcp=443 --dpi-desync=fake,multisplit"
        ];
      };

      enableDirectSync = mkOption {
        type = types.bool;
        default = true;
        description = "Whether this custom hostlist should also be mirrored into sing-box direct domain routing.";
      };
    };
  };

in
{
  options.services.proxy-suite = {
    enable = mkEnableOption "proxy suite (sing-box + zapret + tg-ws-proxy)";

    singBox = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to configure and run sing-box.";
      };

      outbounds = mkOption {
        type = types.listOf outboundType;
        default = [ ];
        description = ''
          List of proxy outbounds. Set exactly one of urlFile, url, or json per entry.
          At least one outbound is required when singBox.enable = true.
        '';
      };

      selection = mkOption {
        type = types.enum [
          "first"
          "selector"
          "urltest"
        ];
        default = "first";
        description = ''
          How to pick between multiple outbounds:
          - "first": use the first outbound only (no overhead, simplest)
          - "selector": expose a Clash-compatible API for manual switching
          - "urltest": measure latency every 3 minutes and auto-switch to the fastest
        '';
      };

      clashApiPort = mkOption {
        type = types.port;
        default = 9090;
        description = "Port for the Clash-compatible REST API. Only used when selection is selector or urltest.";
      };

      listenAddress = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = ''
          Address for the SOCKS5/HTTP mixed inbound to bind to.
          Use "0.0.0.0" only if you intentionally want to expose the proxy.
        '';
      };

      port = mkOption {
        type = types.port;
        default = 1080;
        description = "SOCKS5/HTTP mixed inbound listen port.";
      };

      tproxyPort = mkOption {
        type = types.port;
        default = 1081;
        description = "Transparent proxy (TProxy) inbound listen port.";
      };

      fwmark = mkOption {
        type = types.int;
        default = 1;
        description = "Netfilter mark set on packets intercepted by TProxy for policy routing.";
      };

      proxyMark = mkOption {
        type = types.int;
        default = 2;
        description = "Netfilter mark set on sing-box's own outbound packets so they bypass TProxy re-interception.";
      };

      routeTable = mkOption {
        type = types.int;
        default = 100;
        description = "Policy routing table used to redirect TProxy-marked packets to the loopback interface.";
      };

      proxyByDefault = mkOption {
        type = types.bool;
        default = true;
        description = "If true, traffic not matching any routing rule goes through the proxy. If false, it goes direct.";
      };

      tun = {
        enable = mkEnableOption "TUN mode service (opt-in, mutually exclusive with proxy-suite-tproxy)";

        interface = mkOption {
          type = types.str;
          default = "singtun0";
          description = "TUN interface name.";
        };

        address = mkOption {
          type = types.str;
          default = "172.19.0.1/30";
          description = "TUN interface address (CIDR).";
        };

        mtu = mkOption {
          type = types.int;
          default = 1400;
          description = "TUN interface MTU.";
        };
      };

      tproxy = {
        enable = mkEnableOption "TProxy mode service (opt-in, transparent proxy via nftables)";

        localSubnets = mkOption {
          type = types.listOf types.str;
          default = [ "192.168.0.0/16" ];
          description = ''
            Subnets whose traffic bypasses TProxy interception, except DNS (port 53).
            Typically your LAN subnet(s). VM bridge networks should go here too,
            or use zapret.cidrExemption for subnet-specific NFQUEUE exemption.
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
          description = "Automatically send sing-geosite category-ru and sing-geoip ru traffic direct.";
        };

        proxy = routingFields;

        direct = {
          domains = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "Domain suffixes to send direct (bypass proxy).";
          };
          ips = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "IP CIDRs to send direct.";
          };
          geosites = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "sing-geosite names to send direct.";
          };
          geoips = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "sing-geoip names to send direct.";
          };
        };

        block = {
          domains = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "Domain suffixes to block entirely.";
          };
          ips = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "IP CIDRs to block.";
          };
          geosites = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "sing-geosite names to block.";
          };
          geoips = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "sing-geoip names to block.";
          };
        };

        # Per-outbound and per-action routing rules.
        # These are evaluated before the global proxy/direct/block lists above.
        # Use this for fine-grained control: route specific services to specific
        # servers, or override the default for particular domains/IPs/geos.
        #
        # Alternatively, attach routing directly to an outbound via outbound.routing.*
        # which is equivalent to adding an entry here with outbound = <that tag>.
        #
        # Order within this list is preserved (first matching rule wins in sing-box).
        rules = mkOption {
          type = types.listOf routingRuleType;
          default = [ ];
          description = ''
            Explicit routing rules evaluated before global proxy/direct/block lists.
            Each rule routes matching traffic to a specific outbound tag.

            The outbound can be a configured outbound tag (useful with selector/urltest),
            or one of: "proxy" (active proxy), "direct", "block".
          '';
          example = [
            {
              outbound = "vps-de";
              geosites = [ "netflix" ];
              geoips = [ "us" ];
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

    zapret = {
      enable = mkEnableOption "zapret DPI bypass";

      syncDirectRouting = mkOption {
        type = types.bool;
        default = true;
        description = "When zapret is enabled, mirror its upstream domain hostlists into sing-box direct routing.";
      };

      syncDirectRoutingUpstreamIps = mkOption {
        type = types.bool;
        default = false;
        description = "When zapret is enabled, mirror its upstream ipset ranges into sing-box direct routing.";
      };

      syncDirectRoutingUserIps = mkOption {
        type = types.bool;
        default = true;
        description = "When zapret is enabled, mirror user-defined ipsetAll/ipsetExclude entries into sing-box direct routing.";
      };

      configName = mkOption {
        type = types.str;
        default = "general(ALT)";
        description = "zapret strategy preset name.";
      };

      gameFilter = mkOption {
        type = types.str;
        default = "null";
        description = ''zapret game traffic filter mode: "all", "tcp", "udp", or "null" to disable.'';
      };

      listGeneral = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Extra domains to include in zapret's interception list.";
      };

      listExclude = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Domains to exclude from zapret interception.";
      };

      ipsetAll = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Extra IPs/CIDRs to add to zapret's ipset.";
      };

      ipsetExclude = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "IPs/CIDRs to exclude from zapret's ipset.";
      };

      includeExtraUpstreamLists = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Automatically activate upstream list-instagram.txt, list-soundcloud.txt,
          and list-twitter.txt in the generated zapret config when the selected
          upstream preset does not already reference them.
        '';
      };

      hostlistRules = mkOption {
        type = types.listOf zapretHostlistRuleType;
        default = [ ];
        description = ''
          Additional named zapret hostlists with per-list DPI mitigation rules.
          Each entry generates hostlists/list-<name>.txt and can clone a built-in
          zapret family, add custom NFQWS rule fragments, or both.
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
            domains = [ "example.com" "example.de" ];
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
        description = "Status polling interval in seconds.";
      };

      autostart = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to autostart the tray application for all graphical users via XDG desktop autostart.";
      };
    };

    tgWsProxy = {
      enable = mkEnableOption "Telegram MTProto WebSocket proxy";

      port = mkOption {
        type = types.port;
        default = 1076;
        description = "Port to listen on.";
      };

      host = mkOption {
        type = types.str;
        default = "0.0.0.0";
        description = "Address to bind to.";
      };

      secret = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          MTProto proxy secret (hex string). Legacy inline form; this value ends up
          in the nix store. Prefer secretFile for real deployments.
          Generate one with: openssl rand -hex 16
        '';
        example = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
      };

      secretFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Runtime path to a file containing the MTProto proxy secret.
          Intended for use with secret managers so the secret stays out of the nix store.
        '';
        example = "/run/secrets/tg-ws-proxy-secret";
      };

      dcIps = mkOption {
        type = types.attrsOf types.str;
        default = {
          "2" = "149.154.167.220";
          "4" = "149.154.167.220";
        };
        description = "Map of Telegram DC ID to IP address for relay.";
        example = {
          "1" = "149.154.175.50";
          "2" = "149.154.167.51";
          "3" = "149.154.175.100";
          "4" = "149.154.167.91";
          "5" = "91.108.56.130";
        };
      };
    };
  };
}
