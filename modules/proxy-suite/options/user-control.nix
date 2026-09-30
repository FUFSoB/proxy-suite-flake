{ lib, ... }:

let
  inherit (lib) mkOption types;

  scopeType = types.enum (import ./user-control-scopes.nix);
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
      type = types.listOf scopeType;
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
        - "inbounds": add, remove and bind runtime inbound users and listeners
          (`inbounds.runtime`), and read the secrets they are given.
        - "whitelistBypass": everything under `proxy-ctl wl`.
        - "amneziaWg": add and remove global AmneziaWG profiles (`proxy-ctl awg add`, `awg rm`).
          A global profile takes over the host's routes and DNS. Starting and stopping one is
          "services"; an AmneziaWG outbound is "outbounds".
      '';
      example = [
        "services"
        "routing"
      ];
    };

    groups = mkOption {
      type = types.attrsOf (
        types.submodule {
          options.scopes = mkOption {
            type = types.listOf scopeType;
            default = [ ];
            description = "What this group may do, as in `userControl.scopes`. Empty allows everything.";
          };
        }
      );
      default = { };
      description = ''
        More groups, each with scopes of its own, alongside `userControl.group`. A member gets
        what all of their groups allow. `group` stays the one that owns proxy-suite's files;
        these are given access to them through POSIX ACLs, so the file systems of
        `/var/lib/proxy-suite` and `/run` must support them (the defaults do).
      '';
      example = lib.literalExpression ''
        {
          proxy-admins.scopes = [ ];
          proxy-users.scopes = [ "perApp" "routing" ];
        }
      '';
    };
  };
}
