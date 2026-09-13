{ lib, ... }:

let
  inherit (lib) mkOption types;
in
{
  options.services.proxy-suite.userControl = {
    group = mkOption {
      type = types.strMatching "^[a-z_][a-z0-9_-]*$";
      default = "proxy-suite";
      description = "Group whose members may run privileged `proxy-ctl` commands without a password.";
    };

    allow = mkOption {
      type = types.listOf (
        types.enum [
          "global"
          "perApp"
        ]
      );
      default = [
        "global"
        "perApp"
      ];
      description = ''
        What userControl.group may control without a password:
        - "global": the global units (proxy, tun, tproxy, zapret, restart, subs update).
        - "perApp": the per-app backend units used by `proxy-ctl apps run`.
        Empty grants no passwordless control.
      '';
      example = [ "global" ];
    };
  };
}
