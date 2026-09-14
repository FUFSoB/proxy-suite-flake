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
        Junk-packet lines (Jc, Jmin, Jmax) are honoured by the AmneziaWG profile only.

        When null, proxy-suite-warp registers a device with wgcf (accepting Cloudflare's terms)
        into /var/lib/proxy-suite/warp, through the local proxy when proxy.enable is set, and
        retries until it succeeds. Until then warp connections fail.
      '';
      example = "/run/secrets/wgcf-profile.conf";
    };

    asOutbound = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Add WARP as an outbound tagged "warp": a SOCKS hop to proxy-suite-warp-tunnel, which
        runs WARP as a sing-box WireGuard endpoint on 127.0.0.1:18538 and restarts it on a new
        source port when the handshake stops being answered.
      '';
    };

    asAmneziaWg = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Add an AmneziaWG profile named "warp" (`proxy-ctl awg on warp`). Requires amneziaWg.enable.
      '';
    };
  };
}
