{ lib, ... }:

let
  inherit (lib) mkEnableOption mkOption types;
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

    asAmneziaWg = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Add a global AmneziaWG profile named "warp" (`proxy-ctl awg on warp`). Needs
        `amneziaWg.enable`. Cannot be used with `asOutbound`.
      '';
    };
  };
}
