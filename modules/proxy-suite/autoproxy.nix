# autoProxy: probes the destinations the inbound listener dials through each
# exit in turn and remembers the first exit that gets content. The probe itself
# is `proxy-ctl proxy auto probe --json`, so every verdict is reproducible by hand.
{
  lib,
  pkgs,
  cfg,
  proxyCtl,
  autoProxyStateDir,
  runtimeDir,
  journalctl,
  userControlAllows,
}:

let
  fillTemplate = import ./lib/fill-template.nix;
  apCfg = cfg.proxy.autoProxy;
  derived = import ./derived.nix { inherit lib cfg; };
  inherit (derived.constants) rootInSharedDirConfig;
  # The autoProxy scope's groups write the directory: `proxy auto learn` queues there. Those
  # in userControl.groups through ACLs, which the group bits (the ACL mask) leave open.
  stateDirMode = if derived.userControlAnyAllows "autoProxy" then "0771" else "0751";
  grantAcl = pkgs.writeShellScript "proxy-suite-autoproxy-acl" (
    derived.constants.grantDirAcl pkgs (lib.escapeShellArg autoProxyStateDir)
      (derived.userControlExtraGroupsFor "autoProxy")
      "rwX"
  );
  render = import ./autoproxy-render.nix {
    inherit pkgs;
    inherit ((import ./derived.nix { inherit lib cfg; }).constants) serviceUser ifPrivileged;
  };
  jqFile =
    path:
    builtins.path {
      name = "proxy-suite-autoproxy";
      inherit path;
    };

  bin = lib.makeBinPath [
    pkgs.coreutils
    pkgs.curl
    pkgs.gawk
    pkgs.gnugrep
    pkgs.gnused
    pkgs.jq
    pkgs.systemd
    pkgs.util-linux
    proxyCtl
  ];

  excludePattern = lib.concatStringsSep "|" (map lib.escapeRegex apCfg.exclude);

  # Sets $clash_api (empty when the API is off) and $clash_secret (curl sends it through
  # clash_auth_header, never argv, which every local user can read).
  clashApiBlock = ''
    socks_config="$(dirname "$index")/config.json"
    clash_api=$(jq -r '.experimental.clash_api.external_controller // empty' "$socks_config" 2>/dev/null || true)
    # Root's copy: config.json no longer holds it (start-scripts.nix).
    clash_secret=$(tr -d '\r\n' 2>/dev/null < "$(dirname "$index")/clash-secret" || true)
    clash_auth_header() { printf 'Authorization: Bearer %s\n' "$clash_secret"; }
  '';

  sampler = pkgs.writeShellScript "proxy-suite-autoproxy" (
    fillTemplate ./autoproxy-sample.template.sh {
      path = bin;
      stateDir = lib.escapeShellArg autoProxyStateDir;
      inherit runtimeDir clashApiBlock stateDirMode;
      minBytes = toString (300 * 1024);
      slowBelowBytes = toString (apCfg.slowBelowKiBps * 1024);
      slowSampleJq = jqFile ./autoproxy-slow-sample.jq;
    }
  );

  runner = pkgs.writeShellScript "proxy-suite-autoproxy" (
    fillTemplate ./autoproxy-run.template.sh {
      path = bin;
      stateDir = lib.escapeShellArg autoProxyStateDir;
      inherit runtimeDir;
      ttlDays = toString apCfg.ttlDays;
      inherit stateDirMode;
      editJq = jqFile ./autoproxy-edit.jq;
      inherit render;
      strikeJq = jqFile ./autoproxy-strike.jq;
      roundsJq = jqFile ./autoproxy-rounds.jq;
      interval = apCfg.interval;
      inherit journalctl;
      excludeHosts = lib.optionalString (excludePattern != "") "grep -vE '(^|\\.)(${excludePattern})$' |";
      excludeSampleHosts = lib.optionalString (
        excludePattern != ""
      ) "grep -vE '(^|\\.)(${excludePattern})'$'\\t' |";
      slowJudgeJq = jqFile ./autoproxy-slow-judge.jq;
      probesPerRun = toString apCfg.probesPerRun;
    }
  );

  # Group: `proxy-ctl proxy auto list|queue` reads state.json, `learn` queues requests.
  # Set on every unit that declares the directory - systemd re-applies the ownership
  # on each start.
  stateDirConfig = {
    StateDirectory = "proxy-suite/autoproxy";
    # 0751 and a 027 umask: sing-box (proxy-suite-daemon) reaches the rule-sets through
    # rules/, which its group reads (autoproxy-render.nix), and nothing else.
    StateDirectoryMode = stateDirMode;
    UMask = "0027";
    # Inside the sandbox below, which keeps a name a member left there from leading it
    # anywhere else.
    ExecStartPre = "${grantAcl}";
  }
  // lib.optionalAttrs (userControlAllows "autoProxy") { Group = cfg.userControl.group; }
  # Root writes by fixed names in a directory the group writes to: nowhere else, whatever
  # a name there points at.
  // rootInSharedDirConfig;

  mkUnit = description: args: {
    inherit description;
    after = [
      "proxy-suite-socks.service"
      "proxy-suite-inbounds.service"
    ];
    # No wants: a timer run must not start a proxy stopped on purpose; without
    # its listeners the runner has nothing to do and says so.
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${runner}${args}";
    }
    // stateDirConfig;
  };
in
{
  services.proxy-suite.internal.services.proxy-suite-autoproxy =
    mkUnit "proxy-suite - find the exit that reaches each destination, and remember it" "";

  services.proxy-suite.internal.services.proxy-suite-autoproxy-learn =
    mkUnit "proxy-suite - probe the destinations asked for with proxy-ctl proxy auto learn" " --requests-only";

  services.proxy-suite.internal.services.proxy-suite-autoproxy-sample =
    lib.mkIf (apCfg.slowBelowKiBps > 0)
      {
        description = "proxy-suite - watch live transfers for destinations that crawl directly";
        after = [ "proxy-suite-socks.service" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${sampler}";
        }
        // stateDirConfig;
      };

  services.proxy-suite.internal.timers.proxy-suite-autoproxy-sample =
    lib.mkIf (apCfg.slowBelowKiBps > 0)
      {
        description = "proxy-suite autoProxy transfer sampling";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnActiveSec = "1m";
          OnUnitActiveSec = "1m";
          AccuracySec = "5s";
        };
      };

  services.proxy-suite.internal.timers.proxy-suite-autoproxy = {
    description = "proxy-suite autoProxy probe schedule";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Not OnBootSec: after a rebuild restarts the timer, OnUnitActiveSec had
      # nothing to count from and the prober never ran again.
      OnActiveSec = "10m";
      OnUnitActiveSec = apCfg.interval;
      RandomizedDelaySec = "2m";
      Persistent = true;
    };
  };
}
