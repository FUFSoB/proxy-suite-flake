# directSync for the hosts zapret2 pins (`proxy-ctl zapret auto add`) and learns at
# runtime: a rule-set the proxy sends direct, so zapret2 sees their traffic. Rebuilt
# whenever a host list changes; sing-box reloads it on the rename.
{
  lib,
  pkgs,
  cfg,
}:

let
  fillTemplate = import ../lib/fill-template.nix;
  inherit (import ../derived.nix { inherit lib cfg; }) constants;
  stateDir = constants.zapret2StateDir;
  ruleSet = "${constants.zapret2DirectDir}/direct.json";

  sync = pkgs.writeShellScript "proxy-suite-zapret2" (
    fillTemplate ./direct-sync.template.sh {
      path = lib.makeBinPath [
        pkgs.coreutils
        pkgs.diffutils
        pkgs.jq
      ];
    }
  );
in
{
  inherit sync ruleSet;

  service = {
    description = "proxy-suite - send the hosts zapret2 pins and learns direct in the proxy";
    # Ahead of the proxy at boot, so it starts with the hosts already in.
    before = [ "proxy-suite-socks.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${sync} ${lib.escapeShellArg stateDir} ${lib.escapeShellArg ruleSet}";
      # Root's alone, like the cutoff's: what is in it skips the proxy, so the zapret
      # scope's group, which edits the host lists, only reaches it through them.
      StateDirectory = "proxy-suite/zapret2-direct";
      StateDirectoryMode = "0755";
    }
    // constants.rootInSharedDirConfig;
  };

  path = {
    description = "proxy-suite - watch zapret2's host lists for directSync";
    wantedBy = [ "paths.target" ];
    pathConfig.PathChanged = map (name: "${stateDir}/${name}") [
      "zapret-hosts-user.txt"
      "zapret-hosts-auto.txt"
      "zapret-hosts-user-exclude.txt"
    ];
  };
}
