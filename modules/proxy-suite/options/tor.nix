{ lib, pkgs, ... }:

let
  inherit (lib)
    literalExpression
    mkEnableOption
    mkOption
    types
    ;
  package =
    name: description:
    mkOption {
      type = types.package;
      default = pkgs.${name};
      defaultText = literalExpression "pkgs.${name}";
      inherit description;
    };
in
{
  options.services.proxy-suite.tor = {
    enable = mkEnableOption "Tor" // {
      description = "Run Tor. Also turn on `asOutbound`, `onionService.enable`, or both.";
    };

    package = package "tor" "Tor package.";

    lyrebirdPackage = package "lyrebird" "Bridge transport for obfs4, webtunnel and meek_lite.";

    snowflakePackage = package "snowflake" "Bridge transport for snowflake.";

    asOutbound = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Add Tor as an outbound tagged "tor". Selection and autoProxy skip it unless it is the only
        outbound; send traffic to it with `proxy.routing.rules` or use it as a `detour`.
        Needs `proxy.enable`.
      '';
    };

    routeOnion = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Send .onion names to the "tor" outbound in every route mode, and never resolve them with
        DNS. Inbound clients' .onion names go there too. Needs `asOutbound`.
      '';
    };

    clientOnly = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Keep Tor a client, never a relay, even if `extraConfig` sets an ORPort. The onion service
        works either way. Turn off only to run a relay through `extraConfig`.
      '';
    };

    upstream = mkOption {
      type = types.enum [
        "direct"
        "proxy"
      ];
      default = "direct";
      description = ''
        How Tor reaches the network.
        - "direct": straight from the uplink, bypassing TUN and TProxy.
        - "proxy": through the local proxy, for networks that block Tor. Works with obfs4,
          webtunnel and meek_lite bridges, but not snowflake.
      '';
    };

    socksPort = mkOption {
      type = types.port;
      default = 18530;
      description = "Loopback SOCKS port of Tor.";
    };

    bridges = {
      lines = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Bridge lines from https://bridges.torproject.org, without the leading "Bridge". Setting
          any turns bridges on.
        '';
        example = [
          "obfs4 192.0.2.1:443 0123456789ABCDEF0123456789ABCDEF01234567 cert=... iat-mode=0"
        ];
      };

      file = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "File with more bridge lines, one per line. Blank lines and # comments are skipped.";
        example = "/run/secrets/tor-bridges";
      };
    };

    onionService = {
      enable = mkEnableOption "an onion service for the server inbounds";

      listeners = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        description = ''
          Listeners reachable through the onion address. `null`: every TCP listener (not
          amneziawg, h3-only xhttp or raw JSON).

          Get their links with `proxy-ctl inbounds link TAG --onion`; subscriptions include them.
          Onion clients do not show up in `proxy-ctl inbounds online`.
        '';
        example = [ "vless-reality" ];
      };

      secretKeyFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          File with an hs_ed25519_secret_key, to keep a fixed onion address. `null`: Tor creates one.
        '';
        example = "/run/secrets/tor-hs_ed25519_secret_key";
      };
    };

    extraConfig = mkOption {
      type = types.lines;
      default = "";
      description = "Extra torrc lines.";
      example = ''
        ExitNodes {de},{nl}
        StrictNodes 1
      '';
    };
  };
}
