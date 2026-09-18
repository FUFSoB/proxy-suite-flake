# The Python unit tests, as Nix checks. Every entry is the same runCommand: the test file, the
# interpreter (with the packages it imports) and the env it needs.
{ pkgs }:

let
  scripts = ../../scripts;
  proxyCtl = ../../pkgs/proxy-ctl;

  mkPythonCheck =
    name:
    {
      file,
      drv ? name,
      python ? pkgs.python3,
      env ? { },
      extraInputs ? [ ],
      buildInputs ? [ ],
    }:
    pkgs.runCommand "${drv}-check"
      {
        nativeBuildInputs = [ python ] ++ extraInputs;
        inherit buildInputs;
      }
      ''
        export PYTHONDONTWRITEBYTECODE=1
        ${pkgs.lib.concatStringsSep "\n" (
          pkgs.lib.mapAttrsToList (variable: value: "export ${variable}=${value}") env
        )}
        python ${file}
        touch "$out"
      '';

  withPath = path: { PYTHONPATH = "${path}:$PYTHONPATH"; };
  singBox = {
    SING_BOX = "${pkgs.sing-box}/bin/sing-box";
  };
in
pkgs.lib.mapAttrs mkPythonCheck {
  # The runtime helpers the module's start scripts call: share-link parsing, inbound and
  # AmneziaWG rendering, subscription fetching.
  build-outbound-parser = {
    file = "${scripts}/test-build-outbound.py";
    env = withPath scripts;
  };
  build-inbound-renderer = {
    file = "${scripts}/test-build-inbound.py";
    env = withPath scripts;
  };
  fetch-subscription-parser = {
    file = "${scripts}/test-fetch-subscription.py";
    env = withPath scripts;
  };
  warp-outbound-parser = {
    file = "${scripts}/test-warp-outbound.py";
    env = withPath scripts;
  };
  amneziawg-config-parser = {
    file = "${scripts}/test-amneziawg-config.py";
    env = withPath scripts;
  };
  awg-inbound-state = {
    file = "${scripts}/test-awg-inbound.py";
    env = withPath scripts;
  };
  # The NFQWS_OPT rewrites the zapret v1 package build applies.
  patch-zapret-config = {
    file = "${scripts}/test-patch-zapret-config.py";
    env = withPath scripts;
  };

  # proxy_ctl.py's function-level tests: the probe verdict table and exit walk,
  # autoProxy learn/queue, inbound stats and subscriptions, apps run.
  proxy-ctl-unit = {
    drv = "proxy-suite-proxy-ctl-unit";
    file = "${proxyCtl}/test_proxy_ctl.py";
    env = singBox;
  };
  # proxy-suitectl, nix-on-droid's service manager: real processes restarted, timed and stopped.
  proxy-suite-supervisor-unit = {
    file = "${proxyCtl}/test_proxy_supervisor.py";
    env.HOME = "\"$TMPDIR\"";
  };
  # proxy_export: the running config made portable, and sing-box still accepts it.
  proxy-export-unit = {
    drv = "proxy-suite-proxy-export-unit";
    file = "${proxyCtl}/test_proxy_export.py";
    env = singBox // {
      PYTHONPATH = "${proxyCtl}";
    };
  };
  # proxy-tui driven headless: keys turn into the right proxy-ctl argv.
  proxy-tui-unit = {
    drv = "proxy-suite-proxy-tui-unit";
    file = "${proxyCtl}/test_proxy_tui.py";
    python = pkgs.python3.withPackages (ps: [ ps.textual ]);
    env.PYTHONPATH = "${proxyCtl}";
  };
  # proxy_model: the status strip, tab loads and the tray menu tree, without a UI toolkit.
  proxy-model-unit = {
    drv = "proxy-suite-proxy-model-unit";
    file = "${proxyCtl}/test_proxy_model.py";
    env.PYTHONPATH = "${proxyCtl}";
  };
  # proxy_gui and proxy_sni import against GTK4/libadwaita, the D-Bus interfaces parse, and the
  # tray menu serializes to dbusmenu's layout type. No display needed.
  proxy-gui-smoke = {
    drv = "proxy-suite-proxy-gui-smoke";
    file = "${proxyCtl}/test_proxy_gui.py";
    python = pkgs.python3.withPackages (ps: [ ps.pygobject3 ]);
    extraInputs = [ pkgs.gobject-introspection ];
    buildInputs = [
      pkgs.gtk4
      pkgs.libadwaita
    ];
    env.PYTHONPATH = "${proxyCtl}";
  };
}
