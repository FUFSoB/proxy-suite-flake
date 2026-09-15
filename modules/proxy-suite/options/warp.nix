{ lib, ... }:

let
  inherit (lib) mkEnableOption mkOption types;
in
{
  options.services.proxy-suite.warp = {
    enable = mkEnableOption "Cloudflare WARP";

    configFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Runtime path to a WireGuard profile for WARP, as written by `wgcf register && wgcf generate`.
        AmneziaWG lines (Jc, S1-S4, H1-H4, I1-I5, AWG 3 timing) are honoured by the AmneziaWG profile only.

        When null, proxy-suite-warp registers a device with wgcf (accepting Cloudflare's terms)
        into /var/lib/proxy-suite/warp, through the local proxy when proxy.enable is set, and
        retries until it succeeds. Until then warp connections fail.
      '';
      example = "/run/secrets/wgcf-profile.conf";
    };

    generatorUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        HTTPS URL of a WARP profile generator, fetched directly when wgcf registration fails
        (e.g. the Cloudflare API is blocked and there is no local proxy). It must return a
        WireGuard profile, or JSON with the base64 profile in `.content`.

        The generator registers the device, so its operator sees the private key.
      '';
      example = "https://valokda-amnezia.vercel.app/api/warp?mode=awg2";
    };

    asOutbound = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Add WARP as an outbound tagged "warp": a SOCKS hop to proxy-suite-warp-tunnel, which
        runs WARP as a sing-box WireGuard endpoint on 127.0.0.1:18538, as the proxy-suite-daemon user.
        The tunnel starts again on a new source port when WARP does not answer within 15 seconds
        of a start, or misses three probes later on, unless the uplink itself is down.
      '';
    };

    asAmneziaWg = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Add an AmneziaWG profile named "warp" (`proxy-ctl awg on warp`). Requires amneziaWg.enable,
        and excludes asOutbound: both would use the same WARP key.
      '';
    };
  };
}
