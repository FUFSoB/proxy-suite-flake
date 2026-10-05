# Polkit rule body granting userControl group members passwordless control over the
# units of their scopes; and the GUI's pkexec action for proxy-ctl.
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
  fillTemplate = import ../lib/fill-template.nix;
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
    # A global profile brought up for `apps run --via`, by proxy-ctl as the app starts.
    "proxy-suite-awg-app@" = "perApp";
    "proxy-suite-awg-if@" = "outbounds";
    # Their watchdogs, which pull them in (Wants=, BindsTo=): the same scope, or "services"
    # would start what it does not hold.
    "proxy-suite-awg-app-watchdog@" = "perApp";
    "proxy-suite-awg-if-watchdog@" = "outbounds";
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
  # perApp units every user's apps share: start only, as a stop or restart would send the
  # other users' apps out unmarked. They go once idle on their own.
  sharedVerbs = [
    "start"
    "reset-failed"
  ];
  proxyCtlActionId = "io.github.FUFSoB.ProxySuite.proxy-ctl";
in
{
  userControlPolkitRules = fillTemplate ./polkit-rules.template.js {
    verbs = builtins.toJSON verbs;
    sharedVerbs = builtins.toJSON sharedVerbs;
    units = builtins.toJSON units;
    templates = builtins.toJSON templates;
    coreutils = pkgs.coreutils;
    scopeByUnitPrefix = builtins.toJSON scopeByUnitPrefix;
    groupScopes = builtins.toJSON userControlGroupScopes;
  };
  # Whether the subject is in any userControl group at all: the rule's first test.
  userControlPolkitMember = lib.concatMapStringsSep " || " (
    group: "subject.isInGroup(${builtins.toJSON group})"
  ) (builtins.attrNames userControlGroupScopes);

  inherit proxyCtlActionId;
  # pkexec's action for proxy-ctl, by its path after realpath. The password every time: a
  # kept grant covers the whole session, and proxy-ctl as root runs commands (`apps run`).
  mkProxyCtlAction =
    program:
    pkgs.writeTextFile {
      name = "proxy-suite-polkit-action";
      # polkitd skips a file it cannot parse, and pkexec then falls back to its generic action.
      checkPhase = ''
        ${pkgs.libxml2.bin}/bin/xmllint --noout --nonet \
          --dtdvalid ${pkgs.polkit.out}/share/polkit-1/policyconfig-1.dtd "$target"
      '';
      text = ''
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE policyconfig PUBLIC "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN"
          "http://www.freedesktop.org/standards/PolicyKit/1/policyconfig.dtd">
        <policyconfig>
          <vendor>proxy-suite</vendor>
          <action id="${proxyCtlActionId}">
            <description>Run proxy-ctl as root</description>
            <message>Authentication is required to change proxy-suite as root</message>
            <defaults>
              <allow_any>auth_admin</allow_any>
              <allow_inactive>auth_admin</allow_inactive>
              <allow_active>auth_admin</allow_active>
            </defaults>
            <annotate key="org.freedesktop.policykit.exec.path">${program}</annotate>
          </action>
        </policyconfig>
      '';
    };
}
