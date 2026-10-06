# The proxy's two rule-sets from zapret2's runtime state (direct-sync.template.sh):
# direct.json, the hosts zapret2 pins (`proxy-ctl zapret auto add`) and learns and can
# fix, sent direct so zapret2 sees their traffic (directSync); proxy.json, what it cannot
# fix, for the proxy to carry (zapret2.proxyFallback); and names.tsv, the names the
# addresses blocked outright were looked up by, for proxy-ctl. Rebuilt whenever a host
# list or a verdict changes; sing-box reloads them on the rename.
{
  lib,
  pkgs,
  cfg,
}:

let
  fillTemplate = import ../lib/fill-template.nix;
  inherit (import ../derived.nix { inherit lib cfg; }) constants;
  stateDir = constants.zapret2StateDir;
  outDir = constants.zapret2DirectDir;

  sync = pkgs.writeShellScript "proxy-suite-zapret2" (
    fillTemplate ./direct-sync.template.sh {
      path = lib.makeBinPath [
        pkgs.coreutils
        pkgs.diffutils
        pkgs.jq
        # resolvectl: the names of the addresses blocked outright.
        pkgs.systemd
      ];
    }
  );
in
{
  inherit sync;
  directRuleSet = "${outDir}/direct.json";
  proxyRuleSet = "${outDir}/proxy.json";

  service = {
    description = "proxy-suite - route by what zapret2 can and cannot fix";
    # Ahead of the proxy at boot, so it starts with the hosts already in.
    before = [ "proxy-suite-socks.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${sync} ${lib.escapeShellArg stateDir} ${lib.escapeShellArg outDir}";
      # Root's alone, like the cutoff's: it decides what skips the proxy, so the zapret
      # scope's group, which edits the host lists, only reaches it through them.
      StateDirectory = "proxy-suite/zapret2-direct";
      StateDirectoryMode = "0755";
    }
    // constants.rootInSharedDirConfig;
  };

  path = {
    description = "proxy-suite - watch zapret2's host lists and verdicts";
    wantedBy = [ "paths.target" ];
    pathConfig.PathChanged = map (name: "${stateDir}/${name}") [
      "zapret-hosts-user.txt"
      "zapret-hosts-auto.txt"
      "zapret-hosts-user-exclude.txt"
      "verdicts.tsv"
    ];
  };
}
