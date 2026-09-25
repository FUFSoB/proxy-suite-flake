{ lib, ... }:

let
  inherit (lib) mkOption types;
in
{
  options.services.proxy-suite.userControl = {
    enable = lib.mkEnableOption "`proxy-ctl` without root for members of `userControl.group`";

    group = mkOption {
      type = types.strMatching "^[a-z_][a-z0-9_-]*$";
      default = "proxy-suite";
      description = "Group whose members can run privileged `proxy-ctl` commands.";
    };

    scopes = mkOption {
      type = types.listOf (
        types.enum [
          "services"
          "perApp"
          "routing"
          "outbounds"
          "secrets"
          "autoProxy"
          "zapret"
          "stats"
          "whitelistBypass"
        ]
      );
      default = [ ];
      description = ''
        What the group may do. Empty allows everything.
        - "services": start, stop and restart services, and `tor newnym`.
        - "perApp": `proxy-ctl apps run`.
        - "routing": `proxy pin`, `proxy unpin` and `proxy mode`.
        - "outbounds": add, remove, enable and disable outbounds and subscriptions.
        - "secrets": read share links, subscription URLs and running configs.
        - "autoProxy": see and change what autoProxy learned.
        - "zapret": change zapret2's learned sites, and `zapret cutoff probe`.
        - "stats": `inbounds stats`.
        - "whitelistBypass": everything under `proxy-ctl wl`.
      '';
      example = [
        "services"
        "routing"
      ];
    };
  };
}
