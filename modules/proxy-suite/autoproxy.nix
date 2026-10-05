# autoProxy: probes the destinations the inbound listener dials through each
# exit in turn and remembers the first exit that gets content. The probe itself
# is `proxy-ctl proxy auto probe --json`, so every verdict is reproducible by hand.
{
  lib,
  pkgs,
  cfg,
  proxyCtl,
  autoProxyStateDir,
  autoProxySpoolDir,
  runtimeDir,
  journalctl,
  userControlAllows,
}:

let
  fillTemplate = import ./lib/fill-template.nix;
  apCfg = cfg.proxy.autoProxy;
  derived = import ./derived.nix { inherit lib cfg; };
  inherit (derived.constants) rootInSharedDirConfig;
  # The autoProxy scope's groups read the state (userControl.groups through ACLs), root alone
  # writes it (autoproxy-migrate.nix sets the mode).
  grantAcl = pkgs.writeShellScript "proxy-suite-autoproxy-acl" (
    derived.constants.grantDirAcl pkgs (lib.escapeShellArg autoProxyStateDir)
      (derived.userControlExtraGroupsFor "autoProxy")
      "rX"
  );
  migrate = import ./autoproxy-migrate.nix { inherit pkgs; };
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

  bin = lib.makeBinPath (
    [
      pkgs.coreutils
      pkgs.curl
      pkgs.findutils
      pkgs.gawk
      pkgs.gnugrep
      pkgs.gnused
      pkgs.jq
    ]
    # journalctl; proxy-suitectl, by path, answers it on its own.
    ++ lib.optional (cfg.host.serviceManager != "supervisor") pkgs.systemd
    ++ [
      pkgs.util-linux
      proxyCtl
    ]
  );

  excludePattern = lib.concatStringsSep "|" (map lib.escapeRegex apCfg.exclude);

  # Public suffixes, the private section's too, in the xn-- form names come in: to_reg groups
  # a host under its registrable domain by them.
  publicSuffixes =
    pkgs.runCommand "proxy-suite-autoproxy-public-suffixes" { nativeBuildInputs = [ pkgs.python3 ]; }
      "python3 ${./zapret2/public-suffixes.py} --private ${pkgs.publicsuffix-list}/share/publicsuffix/public_suffix_list.dat >$out";

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
      spoolDir = lib.escapeShellArg autoProxySpoolDir;
      inherit runtimeDir clashApiBlock migrate;
      minBytes = toString (300 * 1024);
      slowBelowBytes = toString (apCfg.slowBelowKiBps * 1024);
      slowSampleJq = jqFile ./autoproxy-slow-sample.jq;
    }
  );

  runner = pkgs.writeShellScript "proxy-suite-autoproxy" (
    fillTemplate ./autoproxy-run.template.sh {
      path = bin;
      stateDir = lib.escapeShellArg autoProxyStateDir;
      spoolDir = lib.escapeShellArg autoProxySpoolDir;
      inherit runtimeDir;
      ttlDays = toString apCfg.ttlDays;
      inherit migrate;
      editJq = jqFile ./autoproxy-edit.jq;
      inherit render;
      strikeJq = jqFile ./autoproxy-strike.jq;
      roundsJq = jqFile ./autoproxy-rounds.jq;
      interval = apCfg.interval;
      inherit journalctl;
      # Quoted whole: escapeRegex leaves a quote or backtick in a name as it is.
      excludeHosts = lib.optionalString (
        excludePattern != ""
      ) "grep -vE ${lib.escapeShellArg "(^|\\.)(${excludePattern})$"} |";
      excludeSampleHosts = lib.optionalString (
        excludePattern != ""
      ) "grep -vE ${lib.escapeShellArg "(^|\\.)(${excludePattern})"}$'\\t' |";
      slowJudgeJq = jqFile ./autoproxy-slow-judge.jq;
      probesPerRun = toString apCfg.probesPerRun;
      inherit publicSuffixes;
    }
  );

  # Group: `proxy-ctl proxy auto list|queue` reads state.json. Set on every unit that
  # declares the directory - systemd re-applies the ownership on each start.
  stateDirConfig = {
    StateDirectory = "proxy-suite/autoproxy";
    # 0751 and a 027 umask: sing-box (proxy-suite-daemon) reaches the rule-sets through
    # rules/, which its group reads (autoproxy-render.nix), and nothing else. An existing
    # directory takes it from autoproxy-migrate.nix: systemd leaves its mode be.
    StateDirectoryMode = "0751";
    UMask = "0027";
    ExecStartPre = "${grantAcl}";
  }
  // lib.optionalAttrs (userControlAllows "autoProxy") { Group = cfg.userControl.group; }
  # Root works in the spool members write to: nothing else is writable.
  // rootInSharedDirConfig
  // lib.optionalAttrs cfg.host.privileged {
    ReadWritePaths = [ "-${autoProxySpoolDir}" ];
    # Nothing it runs (curl, jq, proxy-ctl, systemctl) is setuid.
    NoNewPrivileges = true;
    LockPersonality = true;
    RestrictRealtime = true;
    # Root for files alone: chgrp, ACLs, the spool and the Clash secret (CHOWN, FOWNER, DAC_*).
    CapabilityBoundingSet = [
      "CAP_CHOWN"
      "CAP_DAC_OVERRIDE"
      "CAP_DAC_READ_SEARCH"
      "CAP_FOWNER"
    ];
    ProtectKernelModules = true;
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
      "AF_UNIX"
      "AF_NETLINK"
    ];
  };

  # Sticky, so no member takes another's request; setgid for the group. By tmpfiles, so the
  # group can queue before any unit has run.
  spoolMode =
    if userControlAllows "autoProxy" then
      "3770 root ${cfg.userControl.group}"
    # userControl.groups only, through ACLs (proxy-suite-acls): the mode keeps them open.
    else if derived.userControlAnyAllows "autoProxy" then
      "3770 root root"
    else if cfg.host.privileged then
      "0700 root root"
    else
      "0700 - -";

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
      # A run of tarpits must not hold the lock for good; each probe's verdict is saved as it
      # comes, so one cut short keeps what it learned. Far past any honest run's length.
      TimeoutStartSec = "2h";
    }
    // stateDirConfig;
  };
in
{
  services.proxy-suite.internal.tmpfiles = [ "d ${autoProxySpoolDir} ${spoolMode} -" ];

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
          # Its timer comes every minute.
          TimeoutStartSec = "50s";
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
