# Per-app routing options (backends and profiles).
{ lib, ... }:

let
  inherit (lib) mkOption mkEnableOption types;
  t = import ./types.nix { inherit lib; };
in
{
  options.services.proxy-suite.appRouting = {
    enable = mkEnableOption "per-app routing helpers via proxy-ctl wrap";

    createDefaultProfiles = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to automatically add curated appRouting profiles.

        This is opt-in. Generated defaults are appended only when no
        user-defined profile with the same name already exists.

        Current curated defaults:
        - `proxychains`: route = "proxychains"
        - `tun`: route = "tun" when appRouting.backends.tun.enable = true
        - `tproxy`: route = "tproxy" when appRouting.backends.tproxy.enable = true
        - `zapret`: route = "zapret" when appRouting.backends.zapret.enable = true
          and zapret.enable = true

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
      type = types.listOf t.appRoutingProfileType;
      default = [ ];
      description = ''
        Named per-app route profiles consumed by `proxy-ctl wrap`.

        This initial implementation supports:
        - "direct" for running a command unchanged
        - "proxychains" for TCP apps that can use an LD_PRELOAD wrapper
          instead of global TUN or TProxy interception
        - "tun" for app-scoped policy routing into the dedicated app TUN
          backend
        - "tproxy" for app-scoped transparent interception through the
          dedicated app TProxy backend
        - "zapret" for app-scoped zapret handling through a separate
          zapret instance without changing the app's network path or exit IP

        proxychains-based wrapping depends on the local proxy-suite mixed
        proxy listener provided by sing-box. The "tun" route depends on
        appRouting.backends.tun.enable = true. The "tproxy" route depends on
        appRouting.backends.tproxy.enable = true. The "zapret" route depends
        on appRouting.backends.zapret.enable = true and zapret.enable = true.

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
      enable = mkEnableOption "proxychains-backed appRouting profiles";

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

    backends = {
      tun = {
        enable = mkEnableOption "app-scoped TUN backend for appRouting profiles";

        interface = mkOption {
          type = types.str;
          default = "psapptun0";
          description = ''
            Name of the dedicated app-routing TUN interface used by
            proxy-suite-app-tun.
          '';
          example = "psapptun0";
        };

        address = mkOption {
          type = types.str;
          default = "172.20.0.1/30";
          description = ''
            Address assigned to the app-routing TUN interface in CIDR
            notation.
          '';
          example = "172.20.0.1/30";
        };

        mtu = mkOption {
          type = types.int;
          default = 1400;
          description = ''
            MTU for the app-routing TUN interface.
          '';
          example = 1400;
        };

        fwmark = mkOption {
          type = types.int;
          default = 16;
          description = ''
            Packet mark used to steer wrapped app traffic into the app-routing
            TUN policy-routing table.
          '';
          example = 16;
        };

        routeTable = mkOption {
          type = types.int;
          default = 101;
          description = ''
            Policy-routing table used by the app-routing TUN backend.
          '';
          example = 101;
        };

        localSubnets = mkOption {
          type = types.listOf types.str;
          default = [ "192.168.0.0/16" ];
          description = ''
            Destination subnets that should bypass the app-routing TUN mark,
            so wrapped apps can still reach local LAN resources directly.
          '';
          example = [
            "192.168.0.0/16"
            "10.0.0.0/8"
          ];
        };
      };

      tproxy = {
        enable = mkEnableOption "app-scoped TProxy backend for appRouting profiles";

        fwmark = mkOption {
          type = types.int;
          default = 17;
          description = ''
            Packet mark used to steer wrapped app traffic into the app-routing
            TProxy policy-routing table.
          '';
          example = 17;
        };

        routeTable = mkOption {
          type = types.int;
          default = 102;
          description = ''
            Policy-routing table used by the app-routing TProxy backend.
          '';
          example = 102;
        };

        localSubnets = mkOption {
          type = types.listOf types.str;
          default = [ "192.168.0.0/16" ];
          description = ''
            Destination subnets that should bypass app-routing TProxy
            interception, except DNS traffic on port 53.
          '';
          example = [
            "192.168.0.0/16"
            "10.0.0.0/8"
          ];
        };
      };

      zapret = {
        enable = mkEnableOption "app-scoped zapret backend for appRouting profiles";

        filterMark = mkOption {
          type = types.int;
          default = 268435456;
          description = ''
            Packet mark bit used to mark wrapped app traffic for the
            dedicated app-scoped zapret instance.
          '';
          example = 268435456;
        };

        qnum = mkOption {
          type = types.int;
          default = 201;
          description = ''
            NFQUEUE number used by the dedicated app-scoped zapret instance.
            This backend runs as a second zapret daemon and should use a
            queue distinct from the global zapret instance.
          '';
          example = 201;
        };
      };
    };

  };
}
