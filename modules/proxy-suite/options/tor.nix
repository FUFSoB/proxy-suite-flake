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
    enable = mkEnableOption "the Tor daemon (proxy-suite-tor)";

    package = package "tor" "Tor package.";

    lyrebirdPackage = package "lyrebird" "Pluggable transport for obfs4, webtunnel and meek_lite bridges.";

    snowflakePackage = package "snowflake" "Pluggable transport for snowflake bridges.";

    asOutbound = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Add Tor as an outbound tagged "tor": a SOCKS hop to proxy-suite-tor on 127.0.0.1:socksPort,
        which receives names unresolved. proxy.selection and autoProxy leave it alone unless it is the
        only outbound; route to it with proxy.routing.rules or name it as a detour. Requires proxy.enable.
      '';
    };

    routeOnion = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Send .onion names to the "tor" outbound in every route mode, and keep them away from DNS:
        in TUN and TProxy modes sing-box answers them with a fake address it maps back to the name,
        and XRay drops the lookup. Inbound clients' .onion names go the same way, through the local
        proxy, whatever their listener's via (except "block"). Applies with asOutbound.
      '';
    };

    clientOnly = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Keep Tor a client (ClientOnly 1): never a relay, exit, bridge or directory server, even when
        extraConfig sets an ORPort. The onion service works either way. Turn off only to run a relay
        through extraConfig.
      '';
    };

    upstream = mkOption {
      type = types.enum [
        "direct"
        "proxy"
      ];
      default = "direct";
      description = ''
        How Tor reaches its relays or bridges.
        - "direct": from the uplink, past TUN and TProxy (it runs as proxy-suite-daemon).
        - "proxy": through the local proxy listener (proxy.listener, with its auth), for a network
          that blocks Tor. obfs4, webtunnel and meek_lite bridges follow it; snowflake cannot.
      '';
    };

    socksPort = mkOption {
      type = types.port;
      default = 18530;
      description = "Loopback SOCKS port of proxy-suite-tor, which the tor outbound dials.";
    };

    bridges = {
      lines = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Bridge lines, as https://bridges.torproject.org hands them out, without the leading
          "Bridge". Any given turns on UseBridges; obfs4, webtunnel, meek_lite and snowflake
          transports are run as needed.
        '';
        example = [
          "obfs4 192.0.2.1:443 0123456789ABCDEF0123456789ABCDEF01234567 cert=... iat-mode=0"
        ];
      };

      file = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Runtime path to more bridge lines, one per line; blank lines and # comments are skipped.";
        example = "/run/secrets/tor-bridges";
      };
    };

    onionService = {
      enable = mkEnableOption "an onion service in front of inbounds.listeners";

      listeners = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        description = ''
          inbounds.listeners served at the onion address, each on its share port. Null takes every
          listener a TCP-only onion can carry: not amneziawg, h3-only xhttp or raw JSON.

          Share links for them (`proxy-ctl inbounds link TAG --onion`, and subscriptions) dial the
          .onion address and keep the listener's TLS and REALITY names. Clients reach XRay from
          127.0.0.1, so `proxy-ctl inbounds online` does not list them.
        '';
        example = [ "vless-reality" ];
      };

      secretKeyFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Runtime path to an hs_ed25519_secret_key, to keep an onion address. Null lets Tor create
          one in /var/lib/proxy-suite/tor/onion.
        '';
        example = "/run/secrets/tor-hs_ed25519_secret_key";
      };
    };

    extraConfig = mkOption {
      type = types.lines;
      default = "";
      description = "Lines appended to the generated torrc.";
      example = ''
        ExitNodes {de},{nl}
        StrictNodes 1
      '';
    };
  };
}
