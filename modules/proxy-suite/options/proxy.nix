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
        Proxy engine. "hybrid" runs sing-box and hands XRay-only outbounds (XHTTP, ECH) to XRay.
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
        Transparent mode to start at boot, or `null` for none. That mode must also be enabled
        (`proxy.tun.enable` or `proxy.tproxy.enable`).
      '';
      example = "tun";
    };

    ipv6 = mkOption {
      type = types.bool;
      default = config.services.proxy-suite.host.enableIPv6;
      defaultText = literalExpression "config.networking.enableIPv6";
      description = ''
        Route IPv6 through TUN and TProxy too. When off, TProxy ignores IPv6 and the TUNs block
        it, so apps fall back to IPv4. If the uplink has no IPv6, also set
        `proxy.dns.strategy = "ipv4_only"`, or direct IPv6 connections hang instead of falling back.
      '';
    };

    listener = {
      address = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = ''Address of the local SOCKS5/HTTP proxy. Use "0.0.0.0" only to expose it to the network.'';
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
          description = "Username for the local proxy. Needs `password` or `passwordFile`.";
          example = "proxy-user";
        };

        password = mkOption {
          type = types.nullOr (types.strMatching "[^[:space:]]+");
          default = null;
          description = "Password for the local proxy. Ends up in the Nix store; prefer `passwordFile`.";
          example = "change-me";
        };

        passwordFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            File with the local proxy password. With `perAppRouting.proxychains` it must be a single
            word, and `userControl.group` can read it through the proxychains config.
          '';
          example = "/run/secrets/proxy-suite-local-proxy-password";
        };
      };
    };

    autoProxy = {
      enable = mkEnableOption "autoProxy" // {
        description = ''
          Find out which destinations are blocked and route each one through the first exit that
          reaches it. Blocks that zapret can fix stay direct. Needs the sing-box backend. This host
          fetches every new destination itself to test it; `proxy-ctl proxy auto probe` shows the result.
        '';
      };

      interval = mkOption {
        type = types.str;
        default = "10m";
        description = "Time between probe runs. `proxy-ctl proxy auto learn` probes right away.";
        example = "30m";
      };

      probesPerRun = mkOption {
        type = types.ints.positive;
        default = 200;
        description = "Maximum destinations probed per run. The rest wait for the next run, most-used first.";
      };

      maxExits = mkOption {
        type = types.ints.positive;
        default = 12;
        description = ''
          Maximum exits tried per destination, direct included. One exit per network is tried
          first, then the rest.
        '';
      };

      ttlDays = mkOption {
        type = types.ints.positive;
        default = 30;
        description = ''
          Days before a result is probed again. Everything is probed again when this host's public
          address changes.
        '';
      };

      slowBelowKiBps = mkOption {
        type = types.ints.unsigned;
        default = 150;
        description = ''
          Also route destinations that work directly but stay slower than this, in KiB/s. 0 disables.
          Needs `selection` other than "first".
        '';
        example = 0;
      };

      exclude = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Domains (with subdomains) never probed or routed by autoProxy.";
        example = [ "internal.example" ];
      };

      probeBasePort = mkOption {
        type = types.port;
        default = 18540;
        description = ''
          First of `maxExits` loopback ports used for probing, one per exit. They have no
          authentication, even with `proxy.listener.auth` set.
        '';
      };
    };

    singBox = {
      package = mkOption {
        type = types.package;
        default = proxySuiteUpstream.sing-box;
        defaultText = literalMD "`sing-box` from proxy-suite's own `nixpkgs` input";
        example = literalExpression "pkgs.sing-box";
        description = ''sing-box package, for the "sing-box" and "hybrid" backends.'';
      };

      clashApiPort = mkOption {
        type = types.port;
        default = 9090;
        description = "Loopback port of the sing-box Clash API, used to switch and test outbounds.";
      };
    };

    xray = {
      package = mkOption {
        type = types.package;
        default = proxySuiteUpstream.xray;
        defaultText = literalMD "proxy-suite's `xray` (`pkgs/xray.nix`)";
        example = literalExpression "pkgs.xray";
        description = ''XRay package, for the "xray" and "hybrid" backends.'';
      };
    };
  };
}
