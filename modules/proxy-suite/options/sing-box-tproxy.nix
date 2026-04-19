{ lib, ... }:

let
  inherit (lib) mkOption mkEnableOption types;
in
{
  options.services.proxy-suite.singBox.tproxy = {
    enable = mkEnableOption "global sing-box TProxy mode service";

    autostart = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to start proxy-suite-tproxy automatically during boot by
        attaching it to multi-user.target.
        Cannot be enabled together with singBox.tun.autostart.
      '';
      example = true;
    };

    port = mkOption {
      type = types.port;
      default = 1081;
      description = ''
        Local listen port for sing-box's TProxy inbound.
        nftables redirection created by proxy-suite-tproxy sends intercepted
        TCP/UDP traffic to this port.
      '';
      example = 1081;
    };

    fwmark = mkOption {
      type = types.int;
      default = 1;
      description = ''
        Mark applied to intercepted packets in global TProxy mode.
        A matching `ip rule` routes this mark to
        singBox.tproxy.routeTable, which points traffic to
        loopback for local proxy processing.
      '';
      example = 1;
    };

    proxyMark = mkOption {
      type = types.int;
      default = 2;
      description = ''
        Mark applied to sing-box egress packets in global TProxy mode so
        they bypass re-interception and do not loop back into the
        transparent proxy path.
      '';
      example = 2;
    };

    routeTable = mkOption {
      type = types.int;
      default = 100;
      description = ''
        Policy-routing table number used for global TProxy interception flow.
        The module installs a local default route in this table and binds it
        to singBox.tproxy.fwmark.
      '';
      example = 100;
    };

    localSubnets = mkOption {
      type = types.listOf types.str;
      default = [ "192.168.0.0/16" ];
      description = ''
        Subnets whose traffic bypasses global TProxy interception, except
        DNS (port 53).

        Typically this should include your LAN subnet(s). VM bridge networks
        should usually go here too, or use zapret.cidrExemption for
        subnet-specific NFQUEUE exemption on the zapret side.
      '';
      example = [
        "192.168.0.0/16"
        "10.0.0.0/8"
      ];
    };

    perApp = {
      enable = mkEnableOption "per-app-scoped sing-box TProxy backend for perAppRouting profiles";

      fwmark = mkOption {
        type = types.int;
        default = 17;
        description = ''
          Packet mark used to steer wrapped app traffic into the per-app-scoped
          TProxy policy-routing table.
        '';
        example = 17;
      };

      routeTable = mkOption {
        type = types.int;
        default = 102;
        description = ''
          Policy-routing table used by the per-app-scoped TProxy backend.
        '';
        example = 102;
      };

      localSubnets = mkOption {
        type = types.listOf types.str;
        default = [ "192.168.0.0/16" ];
        description = ''
          Subnets whose traffic bypasses per-app-scoped TProxy interception,
          except DNS (port 53).
        '';
        example = [
          "192.168.0.0/16"
          "10.0.0.0/8"
        ];
      };
    };
  };
}
