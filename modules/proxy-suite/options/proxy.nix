{
  config,
  lib,
  proxySuiteUpstream,
  ...
}:

let
  inherit (lib)
    literalExpression
    literalMD
    mkEnableOption
    mkOption
    types
    ;
in
{
  options.services.proxy-suite.proxy = {
    enable = mkEnableOption "the local proxy";

    backend = mkOption {
      type = types.enum [
        "sing-box"
        "xray"
        "hybrid"
      ];
      default = "sing-box";
      description = ''
        Proxy backend. "hybrid" runs sing-box in front and hands XRay-only outbounds
        (XHTTP, ECH) to XRay.
      '';
      example = "hybrid";
    };

    autostart = mkOption {
      type = types.nullOr (
        types.enum [
          "tun"
          "tproxy"
        ]
      );
      default = null;
      description = ''
        Transparent mode started at boot, or null for neither. The mode named here must
        also be enabled (proxy.tun.enable or proxy.tproxy.enable).
      '';
      example = "tun";
    };

    ipv6 = mkOption {
      type = types.bool;
      default = config.services.proxy-suite.host.enableIPv6;
      defaultText = literalExpression "config.networking.enableIPv6";
      description = ''
        Carry IPv6 in the transparent modes: TProxy through a second listener on ::1, the TUNs
        (global and per-app) through an IPv6 address of their own. Off, TProxy leaves IPv6
        alone and the TUNs block it, so apps fall back to IPv4. On an uplink without IPv6,
        set proxy.dns.strategy = "ipv4_only" too: a direct IPv6 destination would otherwise
        fail after the connection seems open, instead of falling back to IPv4.
      '';
    };

    listener = {
      address = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = ''Bind address of the local SOCKS5/HTTP proxy. Use "0.0.0.0" only to expose it to the network.'';
      };

      port = mkOption {
        type = types.port;
        default = 1080;
        description = "Port of the local SOCKS5/HTTP proxy.";
      };

      auth = {
        username = mkOption {
          type = types.nullOr (types.strMatching "[^[:space:]]+");
          default = null;
          description = "Username the local proxy requires. Set together with password or passwordFile.";
          example = "proxy-user";
        };

        password = mkOption {
          type = types.nullOr (types.strMatching "[^[:space:]]+");
          default = null;
          description = "Inline local proxy password. Ends up in the Nix store; prefer passwordFile.";
          example = "change-me";
        };

        passwordFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Runtime path to the local proxy password. With perAppRouting.proxychains it must be a
            single token, and it is readable by userControl.group through the proxychains config.
          '';
          example = "/run/secrets/proxy-suite-local-proxy-password";
        };
      };
    };

    autoProxy = {
      enable = mkEnableOption "autoProxy" // {
        description = ''
          Probe each exit for the destinations clients dial, and route each one through the first
          exit that reaches it for as long as it keeps working (`proxy-ctl proxy auto probe` shows a
          verdict). Censor-side failures stay direct for zapret. Needs the sing-box backend, and
          makes this host fetch every new destination itself.
        '';
      };

      interval = mkOption {
        type = types.str;
        default = "10m";
        description = "Time between probe runs. `proxy-ctl proxy auto learn` does not wait for it.";
        example = "30m";
      };

      probesPerRun = mkOption {
        type = types.ints.positive;
        default = 200;
        description = "Most destinations probed per run; the rest wait in a backlog, most-dialled first.";
      };

      maxExits = mkOption {
        type = types.ints.positive;
        default = 12;
        description = ''
          Most exits probed, direct included. The first round tries one exit per network (AS), a
          second round the rest.
        '';
      };

      ttlDays = mkOption {
        type = types.ints.positive;
        default = 30;
        description = ''
          Days a verdict stands, routed destinations included: a route is re-probed once this long
          has passed. Everything is relearned when this host's public address changes, and
          `proxy-ctl proxy auto learn <domain>` re-probes one destination right away.
        '';
      };

      slowBelowKiBps = mkOption {
        type = types.ints.unsigned;
        default = 150;
        description = ''
          Also route destinations that work directly but crawl: at least 300 KiB in a 10 s sample,
          never faster than this. 0 disables. Needs `selection` other than "first".
        '';
        example = 0;
      };

      exclude = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Domain suffixes never probed or auto-routed.";
        example = [ "internal.example" ];
      };

      probeBasePort = mkOption {
        type = types.port;
        default = 18540;
        description = ''
          First loopback port of the per-exit probe listeners (one per exit, maxExits in total).
          They are unauthenticated even when proxy.listener.auth is set.
        '';
      };
    };

    singBox = {
      package = mkOption {
        type = types.package;
        default = proxySuiteUpstream.sing-box;
        defaultText = literalMD "`sing-box` from proxy-suite's own `nixpkgs` input";
        example = literalExpression "pkgs.sing-box";
        description = ''sing-box package, used when backend is "sing-box" or "hybrid".'';
      };

      clashApiPort = mkOption {
        type = types.port;
        default = 9090;
        description = "Loopback port of sing-box's Clash API, which switches and tests outbounds.";
      };
    };

    xray = {
      package = mkOption {
        type = types.package;
        default = proxySuiteUpstream.xray;
        defaultText = literalMD "proxy-suite's `xray` (`pkgs/xray.nix`)";
        example = literalExpression "pkgs.xray";
        description = ''XRay package, used when backend is "xray" or "hybrid".'';
      };
    };
  };
}
