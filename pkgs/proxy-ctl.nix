{
  lib,
  pkgs,
}:

{
  clashApi,
  selection,
  subscriptionTagsFile,
  subscriptionCacheDir,
  perAppRoutingEnabled,
  perAppRoutingProxychainsEnabled,
  perAppRoutingTunEnabled,
  perAppRoutingTproxyEnabled,
  perAppRoutingZapretEnabled,
  perAppRoutingProfilesFile,
  proxychainsConfigFile,
  proxychainsQuietArg,
  routeModeStateFile,
  defaultRouteMode,
  amneziaWgProfileNamesFile,
  inboundsEnabled,
  inboundsLinksFile,
  inboundsStatsFile,
  inboundsXray,
  inboundsApi,
  inboundsSubscriptionsFile,
  inboundsSubscriptionsBaseUrl,
  zapretAutoEnabled,
  zapretStateDir,
  zapretCutoffEnabled,
  outboundInventoryFile,
  runtimeOutboundsDir,
  runtimeSubscriptionsDir,
  userControlGroup,
  localProxyUrl,
  autoProxyEnabled,
  autoProxyStateDir,
  torControlSocket ? "",
  singBox,
  stateDir ? "/var/lib/proxy-suite",
  runtimeDir ? "/run",
  serviceManager ? "systemd",
  privileged ? "1",
  # proxy-suitectl, when serviceManager is "supervisor".
  supervisorCtl ? "",
  guiRefreshInterval ? 3,
}:

let
  # Not writePython3Bin: its flake8 pass would gate the build on style.
  unwrapped = pkgs.writeScriptBin "proxy-ctl" (
    "#!${pkgs.python3}/bin/python3\n" + builtins.readFile ./proxy-ctl/proxy_ctl.py
  );
  wrapperEnv = {
    CLASH_API = clashApi;
    SELECTION = selection;
    SUB_TAGS_FILE = toString subscriptionTagsFile;
    SUB_CACHE_DIR = subscriptionCacheDir;
    PER_APP_ROUTING_ENABLED = perAppRoutingEnabled;
    PER_APP_ROUTING_PROXYCHAINS_ENABLED = perAppRoutingProxychainsEnabled;
    PER_APP_ROUTING_TUN_ENABLED = perAppRoutingTunEnabled;
    PER_APP_ROUTING_TPROXY_ENABLED = perAppRoutingTproxyEnabled;
    PER_APP_ROUTING_ZAPRET_ENABLED = perAppRoutingZapretEnabled;
    PER_APP_ROUTING_PROFILES_FILE = toString perAppRoutingProfilesFile;
    PROXYCHAINS_CONFIG = toString proxychainsConfigFile;
    PROXYCHAINS_QUIET_ARG = lib.removeSuffix " " proxychainsQuietArg;
    ROUTE_MODE_STATE_FILE = routeModeStateFile;
    DEFAULT_ROUTE_MODE = defaultRouteMode;
    AWG_PROFILES_FILE = toString amneziaWgProfileNamesFile;
    INBOUNDS_ENABLED = inboundsEnabled;
    INBOUNDS_LINKS_FILE = inboundsLinksFile;
    INBOUNDS_STATS_FILE = inboundsStatsFile;
    INBOUNDS_XRAY = inboundsXray;
    INBOUNDS_API = inboundsApi;
    INBOUNDS_SUBS_FILE = inboundsSubscriptionsFile;
    INBOUNDS_SUB_BASE_URL = inboundsSubscriptionsBaseUrl;
    ZAPRET_AUTO_ENABLED = zapretAutoEnabled;
    ZAPRET_STATE_DIR = zapretStateDir;
    ZAPRET_CUTOFF_ENABLED = zapretCutoffEnabled;
    OUTBOUND_INVENTORY_FILE = outboundInventoryFile;
    RUNTIME_OUTBOUNDS_DIR = runtimeOutboundsDir;
    RUNTIME_SUBS_DIR = runtimeSubscriptionsDir;
    USER_CONTROL_GROUP = userControlGroup;
    LOCAL_PROXY_URL = localProxyUrl;
    AUTOPROXY_ENABLED = autoProxyEnabled;
    AUTOPROXY_STATE_DIR = autoProxyStateDir;
    TOR_CONTROL_SOCKET = torControlSocket;
    SING_BOX = singBox;
    STATE_DIR = stateDir;
    RUNTIME_DIR = runtimeDir;
    SERVICE_MANAGER = serviceManager;
    PRIVILEGED = privileged;
  }
  // lib.optionalAttrs (supervisorCtl != "") {
    SUPERVISOR_CTL = supervisorCtl;
  };
  envFlags = lib.concatStringsSep " " (
    lib.mapAttrsToList (name: value: "--set ${name} ${lib.escapeShellArg value}") wrapperEnv
  );
  # The modules both front-ends import: proxy_ctl for reads, proxy_model for the tabs and the tray menu.
  # proxy_export: what `proxy-ctl proxy config` imports.
  pythonModules = pkgs.runCommand "proxy-suite-python-modules" { } ''
    install -Dm644 ${./proxy-ctl/proxy_ctl.py} "$out/proxy_ctl.py"
    install -Dm644 ${./proxy-ctl/proxy_model.py} "$out/proxy_model.py"
    install -Dm644 ${./proxy-ctl/proxy_export.py} "$out/proxy_export.py"
  '';
  # A separate package: the Textual closure stays off hosts that don't enable it.
  # It imports proxy_ctl for reads and runs proxy-ctl for every change.
  tui = pkgs.symlinkJoin {
    name = "proxy-tui";
    paths = [
      (pkgs.writeScriptBin "proxy-tui" (
        "#!${pkgs.python3.withPackages (ps: [ ps.textual ])}/bin/python3\n"
        + builtins.readFile ./proxy-ctl/proxy_tui.py
      ))
    ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      # /run/wrappers/bin first: the store's sudo, earlier on a PATH, refuses to run without setuid.
      wrapProgram "$out/bin/proxy-tui" \
        --prefix PYTHONPATH : ${pythonModules} \
        --prefix PATH : "${
          lib.makeBinPath [
            proxyCtl
            pkgs.systemd
          ]
        }" \
        --prefix PATH : /run/wrappers/bin ${envFlags}
    '';
  };
  guiPython = pkgs.python3.withPackages (ps: [ ps.pygobject3 ]);
  # Proxy Suite GUI: a GTK4/libadwaita window over the same tabs as the TUI, with a tray icon.
  # Separate for the same reason as the TUI: GTK stays off hosts that don't enable it.
  gui = pkgs.stdenv.mkDerivation {
    pname = "proxy-suite-gui";
    version = "0.2.0";
    dontUnpack = true;
    nativeBuildInputs = [
      pkgs.wrapGAppsHook4
      pkgs.gobject-introspection
      pkgs.makeWrapper
      guiPython
    ];
    buildInputs = [
      pkgs.gtk4
      pkgs.libadwaita
      pkgs.adwaita-icon-theme
      guiPython
    ];
    # A Python script: the wrapper is made by hand below, with the GApps arguments.
    dontWrapGApps = true;
    installPhase = ''
      runHook preInstall
      install -Dm644 ${./proxy-ctl/proxy_gui.py} "$out/lib/proxy-suite-gui/proxy_gui.py"
      install -Dm644 ${./proxy-ctl/proxy_sni.py} "$out/lib/proxy-suite-gui/proxy_sni.py"

      # Tray icons in one flat directory (the tray's IconThemePath), and in hicolor for everything else.
      icons="$out/share/proxy-suite-gui/icons"
      python3 ${./proxy-ctl/icons/badges.py} ${./proxy-ctl/icons} "$icons"
      install -Dm644 ${./proxy-ctl/icons/io.github.FUFSoB.ProxySuite.svg} "$icons/io.github.FUFSoB.ProxySuite.svg"
      for icon in "$icons"/*.svg; do
        case "$icon" in
          *-symbolic.svg) install -Dm644 "$icon" "$out/share/icons/hicolor/symbolic/apps/''${icon##*/}" ;;
          *) install -Dm644 "$icon" "$out/share/icons/hicolor/scalable/apps/''${icon##*/}" ;;
        esac
      done

      mkdir -p "$out/share/applications" "$out/share/systemd/user"
      cat > "$out/share/applications/io.github.FUFSoB.ProxySuite.desktop" <<EOF
      [Desktop Entry]
      Type=Application
      Name=Proxy Suite
      GenericName=Proxy Control
      Comment=Control proxy-suite services, routing and outbounds
      Exec=$out/bin/proxy-suite-gui
      Icon=io.github.FUFSoB.ProxySuite
      Categories=Network;System;
      Keywords=proxy;vpn;sing-box;zapret;tray;
      StartupNotify=true
      Terminal=false
      EOF

      cat > "$out/share/systemd/user/proxy-suite-gui.service" <<EOF
      [Unit]
      Description=Proxy Suite GUI (tray icon)
      PartOf=graphical-session.target
      After=graphical-session.target
      ConditionEnvironment=|WAYLAND_DISPLAY
      ConditionEnvironment=|DISPLAY

      [Service]
      ExecStart=$out/bin/proxy-suite-gui --hidden
      Restart=on-failure
      RestartSec=3

      [Install]
      WantedBy=graphical-session.target
      EOF
      runHook postInstall
    '';
    postFixup = ''
      # /run/wrappers/bin first: the store's pkexec, earlier on a PATH, refuses to run without setuid.
      makeWrapper ${guiPython}/bin/python3 "$out/bin/proxy-suite-gui" \
        --add-flags "$out/lib/proxy-suite-gui/proxy_gui.py" \
        "''${gappsWrapperArgs[@]}" \
        --prefix PYTHONPATH : "${pythonModules}:$out/lib/proxy-suite-gui" \
        --prefix PATH : "${
          lib.makeBinPath [
            proxyCtl
            pkgs.systemd
            pkgs.qrencode
          ]
        }" \
        --prefix PATH : /run/wrappers/bin \
        --set PROXY_GUI_ICON_DIR "$out/share/proxy-suite-gui/icons" \
        --set PROXY_GUI_REFRESH ${toString guiRefreshInterval} ${envFlags}
    '';
    meta = {
      description = "Desktop app and tray icon for proxy-suite";
      mainProgram = "proxy-suite-gui";
    };
  };
  proxyCtl = pkgs.symlinkJoin {
    name = "proxy-ctl";
    paths = [ unwrapped ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    passthru.tui = tui;
    passthru.gui = gui;
    passthru.proxySuiteCheck = {
      inherit
        wrapperEnv
        subscriptionTagsFile
        perAppRoutingProfilesFile
        proxychainsConfigFile
        amneziaWgProfileNamesFile
        ;
      script = unwrapped.drvAttrs.text;
    };
    # Probes present a browser's TLS fingerprint: bot protection refuses plain
    # curl. The newest Chrome profile the package ships, since the set varies by
    # version; the build fails if there is none.
    postBuild = ''
      install -Dm644 ${./proxy-ctl/completions/proxy-ctl.bash} \
        "$out/share/bash-completion/completions/proxy-ctl"
      install -Dm644 ${./proxy-ctl/completions/_proxy-ctl} "$out/share/zsh/site-functions/_proxy-ctl"
      install -Dm644 ${./proxy-ctl/completions/proxy-ctl.fish} \
        "$out/share/fish/vendor_completions.d/proxy-ctl.fish"
      probe_curl=$(ls ${pkgs.curl-impersonate}/bin/curl_chrome[0-9]* | grep -E '/curl_chrome[0-9]+$' | sort -V | tail -n 1)
      [ -x "$probe_curl" ]
      wrapProgram "$out/bin/proxy-ctl" \
        --set PROBE_CURL "$probe_curl" \
        --set PROXY_CTL_MODULES ${pythonModules} \
        --prefix PATH : "${
          lib.makeBinPath [
            # curl-impersonate's curl_chrome* wrappers are `#!/usr/bin/env bash`.
            pkgs.bash
            pkgs.curl
            pkgs.fzf
            pkgs.proxychains-ng
            pkgs.qrencode
            pkgs.systemd
          ]
        }" ${envFlags}
    '';
  };
in
proxyCtl
