{ config, lib, ... }:

let
  inherit (lib)
    literalExpression
    mkEnableOption
    mkOption
    types
    ;
  inherit (import ./lib.nix { inherit lib; }) endpoint;
in
{
  options.services.proxy-suite.warp = {
    enable = mkEnableOption "Cloudflare WARP" // {
      description = "Run Cloudflare WARP. Also set `asOutbound` or `asAmneziaWg`.";
    };

    configFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        File with a WARP WireGuard profile, from `wgcf register && wgcf generate`. AmneziaWG
        fields in it only take effect in the AmneziaWG modes.

        `null`: register a new device with wgcf on first start (accepting Cloudflare's terms),
        through the local proxy if enabled. WARP does not work until that succeeds.
      '';
      example = "/run/secrets/wgcf-profile.conf";
    };

    generatorUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        URL of a WARP profile generator, used if wgcf registration fails (for example, when the
        Cloudflare API is blocked). It must return a WireGuard profile, or JSON with the base64
        profile in `.content`.

        Its operator sees your private key.
      '';
      example = "https://valokda-amnezia.vercel.app/api/warp?mode=awg2";
    };

    endpoint = endpoint ''
      host:port (IPv6 in brackets) to use instead of the profile's endpoint, if the default one
      is blocked: another Cloudflare address, another WARP port (500, 1701, 4500, …), or a relay.
    '';

    asOutbound = mkOption {
      type = types.nullOr (
        types.enum [
          "singBox"
          "userspace"
          "interface"
        ]
      );
      default = null;
      description = ''
        Add WARP as an outbound tagged "warp".
        - "singBox": plain WireGuard in sing-box, ignoring AmneziaWG fields. Restarts itself when
          WARP stops answering.
        - "userspace": an AmneziaWG profile, without root. Needs `amneziaWg.enable`.
        - "interface": an AmneziaWG profile with its own interface. Needs `amneziaWg.enable`.
      '';
    };

    domainStrategy = mkOption {
      type = types.nullOr (
        types.enum [
          "prefer_ipv4"
          "prefer_ipv6"
          "ipv4_only"
          "ipv6_only"
        ]
      );
      default = if config.services.proxy-suite.host.enableIPv6 then "prefer_ipv6" else "prefer_ipv4";
      defaultText = literalExpression ''if config.networking.enableIPv6 then "prefer_ipv6" else "prefer_ipv4"'';
      description = ''
        Which address family the "warp" outbound dials a name over first. Ignored with
        `asOutbound = "userspace"`. Also applies to names resolved by the inbounds'
        `routing.blockPrivate` check, unless `proxy.dns.strategy` is set.
      '';
      example = "prefer_ipv4";
    };

    asAmneziaWg = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Add a global AmneziaWG profile named "warp" (`proxy-ctl awg on warp`). Needs
        `amneziaWg.enable`. Cannot be used with `asOutbound`.
      '';
    };

    autostart = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Bring the "warp" AmneziaWG profile up at boot, as `autostart` of an `amneziaWg` profile
        does. Needs `asAmneziaWg`. Only one global mode can autostart.
      '';
    };
  };
}
