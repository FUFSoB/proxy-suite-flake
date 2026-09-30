# Polkit rule body granting userControl group members passwordless control over the
# units of their scopes.
#
# Only units this module declares, by their full names: systemd asks the same
# manage-units question with the same unit name for a transient unit
# (`systemd-run --unit=proxy-suite-x ...`), so a prefix match would run any command as
# root. A declared unit has a fragment, and systemd refuses a transient one of its name.
{
  lib,
  pkgs,
  # {group: [scopes]}, every scope spelled out (derived.nix).
  userControlGroupScopes,
  # Declared system units, "name.service" or "name.timer"; templates as "name@".
  unitNames,
}:

let
  # Units a narrower scope starts; every other proxy-suite unit is "services".
  scopeByUnitPrefix = {
    "proxy-suite-per-app-" = "perApp";
    "proxy-suite-outbound-pin@" = "routing";
    "proxy-suite-outbound-unpin." = "routing";
    "proxy-suite-route-mode@" = "routing";
    "proxy-suite-outbound-reload." = "outbounds";
    "proxy-suite-subscription-update." = "outbounds";
    # Tunnels of the AmneziaWG outbounds added at runtime; a global profile's own unit
    # (proxy-suite-awg@) is "services", like the declared ones.
    "proxy-suite-awg-tunnel@" = "outbounds";
    "proxy-suite-awg-runtime-sync." = "outbounds";
    "proxy-suite-autoproxy-learn." = "autoProxy";
    "proxy-suite-zapret2-cutoff." = "zapret";
    "proxy-suite-inbound-stats." = "stats";
    "proxy-suite-inbounds-reload." = "inbounds";
    "proxy-suite-wb-" = "whitelistBypass";
  };
  templates = lib.filter (lib.hasSuffix "@") unitNames;
  units = lib.filter (name: !lib.hasSuffix "@" name) unitNames;
  # What proxy-ctl asks for; not kill, clean, set-property, freeze or thaw.
  verbs = [
    "start"
    "stop"
    "restart"
    "try-restart"
    "reload"
    "reload-or-restart"
    "reload-or-try-restart"
    "reset-failed"
  ];
in
{
  userControlPolkitRules = ''
    var verb = action.lookup("verb");
    if (typeof unit !== "string" || ${builtins.toJSON verbs}.indexOf(verb) === -1) {
      return null;
    }
    var known = ${builtins.toJSON units}.indexOf(unit) !== -1;
    var templates = ${builtins.toJSON templates};
    for (var i = 0; !known && i < templates.length; i++) {
      var template = templates[i];
      if (unit.indexOf(template) !== 0) {
        continue;
      }
      var instance = unit.slice(template.length).replace(/\.service$/, "");
      if (!/^[A-Za-z0-9:_.\\-]+$/.test(instance) || unit !== template + instance + ".service") {
        continue;
      }
      // Per-app marking follows one user's apps: only that user's own instance.
      if (/-user@$/.test(template)) {
        try {
          var uid = polkit.spawn(["${pkgs.coreutils}/bin/id", "-u", "--", subject.user]).trim();
        } catch (error) {
          return null;
        }
        if (instance !== uid) {
          return null;
        }
      }
      known = true;
    }
    if (!known) {
      return null;
    }

    var scopeByUnitPrefix = ${builtins.toJSON scopeByUnitPrefix};
    var scope = "services";
    for (var prefix in scopeByUnitPrefix) {
      if (unit.indexOf(prefix) === 0) {
        scope = scopeByUnitPrefix[prefix];
        break;
      }
    }
    // Any of the subject's groups that holds the scope.
    var groupScopes = ${builtins.toJSON userControlGroupScopes};
    for (var group in groupScopes) {
      if (groupScopes[group].indexOf(scope) !== -1 && subject.isInGroup(group)) {
        return polkit.Result.YES;
      }
    }
  '';
  # Whether the subject is in any userControl group at all: the rule's first test.
  userControlPolkitMember = lib.concatMapStringsSep " || " (
    group: "subject.isInGroup(${builtins.toJSON group})"
  ) (builtins.attrNames userControlGroupScopes);
}
