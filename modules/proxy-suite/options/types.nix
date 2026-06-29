# Type submodule definitions shared across options sub-files.
{ lib }:

let
  inherit (lib) mkOption types;

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
        Each name becomes a backend geosite rule-set reference.
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
        Each name becomes a backend geoip rule-set reference.
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
        type = types.strMatching "^[A-Za-z0-9][A-Za-z0-9._-]*$";
        description = ''
          Unique identifier for this subscription.
          Used as a prefix for all outbound tags generated from its proxy list,
          e.g. "my-sub" -> tags like "my-sub-Server-DE".

          This value is also used as the subscription cache filename stem under
          /var/lib/proxy-suite/subscriptions/<backend>/, so it must be a safe
          identifier.
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
          tag and can be selected directly. With selection = "first", proxy-suite
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

      backend = mkOption {
        type = types.enum [
          "auto"
          "sing-box"
          "xray"
        ];
        default = "auto";
        description = ''
          Backend preference for this outbound when both SingBox and XRay are
          enabled. "auto" uses SingBox when the URL or JSON can be represented
          there and falls back to XRay for XRay-only transports such as XHTTP
          or ECH. Ignored by single-backend configurations.
        '';
        example = "xray";
      };

      singBoxJson = mkOption {
        type = types.nullOr types.attrs;
        default = null;
        description = ''
          Raw sing-box outbound configuration as a Nix attribute set.
          Embedded directly into the config at build time. The tag field
          is overridden by the outbound's tag option.

          Set exactly one of urlFile, url, singBoxJson, xrayJson, or json for
          each outbound.
          Use this when the proxy definition is easier to generate as native Nix
          than as a single URL string. Only valid with the SingBox backend.
        '';
        example = {
          type = "vless";
          server = "example.com";
          server_port = 443;
          uuid = "...";
        };
      };

      xrayJson = mkOption {
        type = types.nullOr types.attrs;
        default = null;
        description = ''
          Raw XRay outbound configuration as a Nix attribute set.
          Embedded directly into the config at build time. The tag field is
          overridden by the outbound's tag option.

          Set exactly one of urlFile, url, singBoxJson, xrayJson, or json for
          each outbound. Only valid with the XRay backend.
        '';
        example = {
          protocol = "vless";
          settings = {
            address = "example.com";
            port = 443;
            id = "...";
            encryption = "none";
          };
        };
      };

      json = mkOption {
        type = types.nullOr types.attrs;
        default = null;
        visible = false;
        description = ''
          Deprecated alias for singBoxJson. Use singBoxJson instead.
        '';
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
          DNS transport type for this upstream resolver.
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

  zapretDefaultDomainType = types.enum [
    "youtube"
    "discord"
    "other"
    "instagram"
    "soundcloud"
    "twitter"
  ];

  zapretDefaultIpType = types.enum [
    "all"
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
          Can be combined with defaultDomains.
        '';
        example = [
          "example.com"
          "example.de"
        ];
      };

      defaultDomains = mkOption {
        type = types.listOf zapretDefaultDomainType;
        default = [ ];
        description = ''
          Built-in domain groups copied from zapret-discord-youtube hostlists.
          These are expanded and combined with domains.

          "youtube" uses the upstream Google/YouTube list. "discord" uses
          Discord-related domains from the upstream general list. "other" uses
          the non-Discord domains from the upstream general list.

          When preset is unset, use one defaultDomains entry per rule so the
          module can infer a single rule family. Split groups into separate
          rules when they need different strategies.
        '';
        example = [ "youtube" ];
      };

      ips = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          IPs or CIDRs written into the generated custom zapret ipset file.
          Can be combined with defaultIps.
        '';
        example = [
          "203.0.113.0/24"
          "2001:db8::/32"
        ];
      };

      defaultIps = mkOption {
        type = types.listOf zapretDefaultIpType;
        default = [ ];
        description = ''
          Built-in IP/CIDR groups copied from zapret-discord-youtube ipsets.

          "all" uses the upstream ipset-all.txt list. The upstream bundle does
          not split this list by service, so site-specific defaults remain in
          defaultDomains.
        '';
        example = [ "all" ];
      };

      preset = mkOption {
        type = types.nullOr zapretPresetType;
        default = null;
        description = ''
          Clone this built-in NFQWS rule family for this hostlist. When
          configName is set, the family is cloned from that zapret config;
          otherwise it is cloned from the active global zapret config.

          When unset and defaultDomains is non-empty, rule families are
          inferred from defaultDomains.
        '';
        example = "google";
      };

      configName = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          zapret config name to clone NFQWS rules from for this hostlist.
          Names use the same matching rules as services.proxy-suite.zapret.configName.

          This is a higher-level alternative to nfqwsArgs and cannot be used
          together with nfqwsArgs.
        '';
        example = "general(ALT9)";
      };

      nfqwsArgs = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Additional NFQWS argument fragments for this hostlist.
          The module injects --hostlist=... and trailing --new automatically.

          This cannot be used together with configName.
        '';
        example = [
          "--filter-tcp=443 --dpi-desync=fake,multisplit"
        ];
      };

      enableDirectSync = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether this custom hostlist should also be mirrored into proxy
          direct domain routing when zapret.syncDirectRouting = true.
        '';
      };
    };
  };

  perAppRoutingProfileType = types.submodule {
    options = {
      name = mkOption {
        type = types.strMatching "^[a-z0-9][a-z0-9-]*$";
        description = ''
          Profile name used by `proxy-ctl wrap <name> -- <command>`.
          Must be unique within perAppRouting.profiles.
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
          - "tun": launch the command in the dedicated per-app-routing TUN slice so
            only that app's traffic is policy-routed into the app TUN backend.
          - "tproxy": launch the command in the dedicated per-app-routing TProxy
            slice so only that app's traffic is transparently intercepted by
            the local proxy TProxy inbound.
          - "zapret": launch the command in the dedicated per-app-routing zapret
            slice so only that app's traffic is handled by the separate
            per-app-scoped zapret instance.

          Additional route backends may be added in the future.
        '';
        example = "proxychains";
      };
    };
  };

in
{
  inherit
    routingFields
    routingRuleType
    subscriptionType
    outboundType
    dnsUpstreamType
    zapretDefaultDomainType
    zapretDefaultIpType
    zapretPresetType
    zapretHostlistRuleType
    perAppRoutingProfileType
    ;
}
