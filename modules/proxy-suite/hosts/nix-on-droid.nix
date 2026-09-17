# nix-on-droid: no systemd and no root. The units run under proxy-suitectl, a small
# supervisor that reads them, rendered as for a user manager, from a manifest the
# activation links into place; proxy-ctl and the scripts talk to it in systemctl's words.
{
  config,
  lib,
  pkgs,
  proxySuiteUpstream,
  ...
}:

let
  cfg = config.services.proxy-suite;
  host = cfg.host;
  internal = cfg.internal;
  home = config.user.home;

  inherit
    (import ./user-units.nix {
      inherit lib pkgs;
      inherit (host) runtimeDir;
      stateDir = dirOf host.stateDir;
      hostPath = "${home}/.nix-profile/bin";
    })
    toService
    toTimer
    toPath
    ;

  enabled = lib.filterAttrs (_: unit: unit.enable);

  supervisorDir = "${host.runtimeDir}/proxy-suite-supervisor";
  # Outside the store, so proxy-suitectl stays the same from one generation to the next.
  manifestLink = "${host.stateDir}/supervisor/manifest.json";
  manifest = pkgs.writeText "proxy-suite-units.json" (
    builtins.toJSON {
      services = lib.mapAttrs toService (enabled (internal.services // internal.userServices));
      timers = lib.mapAttrs toTimer (enabled internal.timers);
      paths = lib.mapAttrs toPath (enabled internal.paths);
      inherit (internal) tmpfiles;
    }
  );

  suitectl = import ../../../pkgs/proxy-suite-supervisor.nix { inherit lib pkgs; } {
    inherit supervisorDir;
    manifest = manifestLink;
    inherit (host) runtimeDir;
    stateDir = dirOf host.stateDir;
  };
  suitectlBin = "${suitectl}/bin/proxy-suitectl";

  # Once per session tree: nested shells find it exported.
  sessionStart = ''
    if [ -z "''${__PROXY_SUITE_SESSION:-}" ]; then
      export __PROXY_SUITE_SESSION=1
      ( ${suitectlBin} ensure >/dev/null 2>&1 & )
    fi
  '';
in
{
  options.services.proxy-suite.nixOnDroid.startWithSession = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Start the services when a Nix-on-Droid shell opens, if they are not running yet.
      Android offers the app no boot hook, so without this they only start on
      `nix-on-droid switch` or `proxy-suitectl boot`. Android may still stop them in
      the background: keep the app's wake lock on and exempt it from battery optimisation.
    '';
  };

  config = lib.mkMerge [
    {
      services.proxy-suite.host = {
        kind = "nix-on-droid";
        privileged = false;
        serviceManager = "supervisor";
        stateDir = lib.mkDefault "${home}/.local/state/proxy-suite";
        runtimeDir = lib.mkDefault "${home}/.cache/proxy-suite/run";
        systemctl = suitectlBin;
        journalctl = "${suitectlBin} journal";
        enableIPv6 = true;
        # Android's kernel, resolver and firewall are not the app's to change.
        kernelPackages = null;
        firewallPackage = null;
        resolvconfPackage = null;
      };
      # An app may not join netlink's route groups: without this sing-box fails to start.
      services.proxy-suite.proxy.singBox.package = lib.mkDefault (
        import ../../../pkgs/sing-box-rootless-netlink.nix { inherit (proxySuiteUpstream) sing-box; }
      );
    }

    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = !cfg.gui.enable;
          message = "proxy-suite: the GUI needs a desktop session, which a nix-on-droid host does not have; use proxy-ctl or proxy-tui";
        }
      ];

      environment.packages = internal.earlyPackages ++ internal.packages ++ [ suitectl ];

      build.activationAfter.proxySuite = ''
        $DRY_RUN_CMD mkdir -p ${lib.escapeShellArg (dirOf manifestLink)}
        $DRY_RUN_CMD ln -sfn ${manifest} ${lib.escapeShellArg manifestLink}
        # Starts the supervisor, or restarts what changed under a running one.
        if ! $DRY_RUN_CMD ${suitectlBin} boot; then
          warnEcho "proxy-suite: some units did not start; see proxy-ctl status"
        fi
      '';

      environment.etc = lib.mkIf cfg.nixOnDroid.startWithSession {
        "profile".text = lib.mkAfter sessionStart;
        "zshenv".text = lib.mkAfter sessionStart;
      };
    })

    (lib.mkIf (!cfg.enable) {
      # Disabled since the last generation: nothing should keep running.
      build.activationAfter.proxySuite = ''
        if [ -S ${lib.escapeShellArg "${supervisorDir}/control.sock"} ]; then
          $DRY_RUN_CMD ${suitectlBin} shutdown || true
        fi
      '';
    })
  ];
}
