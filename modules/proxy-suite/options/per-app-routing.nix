# Per-app routing options (backends and profiles).
{ lib, ... }:

let
  inherit (lib) mkOption mkEnableOption types;
  t = import ./types.nix { inherit lib; };
in
{
  options.services.proxy-suite.perAppRouting = {
    enable = mkEnableOption "per-app routing helpers via proxy-ctl wrap";

    createDefaultProfiles = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to automatically add curated perAppRouting profiles.

        This is opt-in. Generated defaults are appended only when no
        user-defined profile with the same name already exists.

        Current curated defaults:
        - `proxychains`: route = "proxychains"
        - `tun`: route = "tun" when singBox.tun.perApp.enable = true
        - `tproxy`: route = "tproxy" when singBox.tproxy.perApp.enable = true
        - `zapret`: route = "zapret" when zapret.perApp.enable = true and
          zapret.enable = true

        This makes `proxy-ctl wrap proxychains -- <command>` available
        without defining the profile manually, and similarly exposes
        `proxy-ctl wrap tun -- <command>` or
        `proxy-ctl wrap tproxy -- <command>` or
        `proxy-ctl wrap zapret -- <command>` when the corresponding backend
        is enabled.
      '';
      example = true;
    };

    profiles = mkOption {
      type = types.listOf t.perAppRoutingProfileType;
      default = [ ];
      description = ''
        Named per-app route profiles consumed by `proxy-ctl wrap`.

        This initial implementation supports:
        - "direct" for running a command unchanged
        - "proxychains" for TCP apps that can use an LD_PRELOAD wrapper
          instead of global TUN or TProxy interception
        - "tun" for per-app-scoped policy routing into the dedicated app TUN
          backend
        - "tproxy" for per-app-scoped transparent interception through the
          dedicated app TProxy backend
        - "zapret" for per-app-scoped zapret handling through a separate
          zapret instance without changing the app's network path or exit IP

        proxychains-based wrapping depends on singBox.enable = true and the
        local proxy-suite mixed proxy listener provided by sing-box. The
        "tun" route depends on singBox.tun.perApp.enable = true. The "tproxy"
        route depends on singBox.tproxy.perApp.enable = true. The "zapret"
        route depends on zapret.perApp.enable = true and zapret.enable = true.

        When createDefaultProfiles = true, curated defaults are added on top
        of this list unless a user-defined profile already uses the same
        name.
      '';
      example = [
        {
          name = "steam-browser";
          route = "proxychains";
        }
        {
          name = "native-direct";
          route = "direct";
        }
      ];
    };

    proxychains = {
      enable = mkEnableOption "proxychains-backed perAppRouting profiles";

      quiet = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether generated proxychains wrappers should suppress their normal
          startup chatter. This maps to proxychains-ng quiet_mode.
        '';
        example = true;
      };

      proxyDns = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether generated proxychains wrappers should resolve DNS through
          the proxy instead of the local resolver. This maps to proxychains-ng
          proxy_dns.
        '';
        example = true;
      };
    };
  };
}
