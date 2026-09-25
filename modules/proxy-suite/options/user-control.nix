{ lib, ... }:

let
  inherit (lib) mkOption types;
in
{
  options.services.proxy-suite.userControl = {
    enable = lib.mkEnableOption "passwordless `proxy-ctl` control for the members of userControl.group";

    group = mkOption {
      type = types.strMatching "^[a-z_][a-z0-9_-]*$";
      default = "proxy-suite";
      description = "Group whose members may run privileged `proxy-ctl` commands without a password.";
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
        What userControl.group may do; empty allows every scope.
        - "services": turn the proxy-suite units on and off (proxy, tun, tproxy, zapret, ssh, warp, tor, tg, awg, inbounds), `restart`, and `tor status|newnym` on Tor's control socket.
        - "perApp": the per-app backend units used by `proxy-ctl apps run`.
        - "routing": `proxy pin`, `proxy unpin` and `proxy mode`.
        - "outbounds": add and remove runtime outbounds and subscriptions, disable and enable outbounds, and update subscriptions.
        - "secrets": read share links, subscription URLs and the running configs.
        - "autoProxy": read what autoProxy learned, and `proxy auto learn|forget|relearn|clear`.
        - "zapret": edit zapret2's learned hosts, and `zapret cutoff probe`.
        - "stats": `inbounds stats`.
        - "whitelistBypass": the whitelist-bypass creators and joiners: `wl on|off|toggle|restart`, their calls (`wl link`), and their logins and links (`wl auth|join|new`).
      '';
      example = [
        "services"
        "routing"
      ];
    };
  };
}
