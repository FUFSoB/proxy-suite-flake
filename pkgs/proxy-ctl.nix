{
  lib,
  pkgs,
}:

{
  # NAME -> value, exported into proxy-ctl and both front ends. The module builds it
  # (modules/proxy-suite/service/control.nix); proxy_ctl.py reads every name with env().
  env,
  guiRefreshInterval ? 3,
  # The window opens floating where a tiling compositor would tile it (proxy_gui.open_floating).
  guiFloating ? true,
  # Off where proxy-suitectl runs the units (nix-on-droid): proxy-ctl reaches it through
  # SUPERVISOR_CTL, and systemd stays out of the closure.
  withSystemd ? true,
  # `proxy-ctl logs` follows in less without it.
  withLnav ? true,
  # Probes go through plain curl without it.
  withCurlImpersonate ? true,
  # These four are also passed as derivations: the checks read the files' contents through
  # passthru.proxySuiteCheck, which toString in env would lose.
  subscriptionTagsFile,
  perAppRoutingProfilesFile,
  proxychainsConfigFile,
  amneziaWgProfileNamesFile,
}:

let
  # Not writePython3Bin: its flake8 pass would gate the build on style.
  unwrapped = pkgs.writeScriptBin "proxy-ctl" (
    "#!${pkgs.python3}/bin/python3\n" + builtins.readFile ./proxy-ctl/proxy_ctl.py
  );
  wrapperEnv = env;
  # Probes present a browser's TLS fingerprint: bot protection refuses plain
  # curl. The newest Chrome profile the package ships, since the set varies by
  # version; the build fails if there is none.
  findProbeCurl = lib.optionalString withCurlImpersonate ''
    probe_curl=$(ls ${pkgs.curl-impersonate}/bin/curl_chrome[0-9]* | grep -E '/curl_chrome[0-9]+$' | sort -V | tail -n 1)
    [ -x "$probe_curl" ]
  '';
  # Unset, proxy_ctl.py probes with the curl on PATH.
  probeCurlFlag = lib.optionalString withCurlImpersonate (
    ''--set PROBE_CURL "$probe_curl" \'' + "\n  "
  );
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
        --prefix PATH : "${lib.makeBinPath ([ proxyCtl ] ++ lib.optional withSystemd pkgs.systemd)}" \
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
          lib.makeBinPath ([ proxyCtl ] ++ lib.optional withSystemd pkgs.systemd ++ [ pkgs.qrencode ])
        }" \
        --prefix PATH : /run/wrappers/bin \
        --set PROXY_GUI_ICON_DIR "$out/share/proxy-suite-gui/icons" \
        --set PROXY_GUI_REFRESH ${toString guiRefreshInterval} \
        --set PROXY_GUI_FLOATING ${if guiFloating then "1" else "0"} ${envFlags}
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
    postBuild = ''
      install -Dm644 ${./proxy-ctl/completions/proxy-ctl.bash} \
        "$out/share/bash-completion/completions/proxy-ctl"
      install -Dm644 ${./proxy-ctl/completions/_proxy-ctl} "$out/share/zsh/site-functions/_proxy-ctl"
      install -Dm644 ${./proxy-ctl/completions/proxy-ctl.fish} \
        "$out/share/fish/vendor_completions.d/proxy-ctl.fish"
      ${findProbeCurl}wrapProgram "$out/bin/proxy-ctl" \
        ${probeCurlFlag}--set PROXY_CTL_MODULES ${pythonModules} \
        --prefix PATH : "${
          lib.makeBinPath (
            # curl-impersonate's curl_chrome* wrappers are `#!/usr/bin/env bash`.
            lib.optional withCurlImpersonate pkgs.bash
            ++ [
              pkgs.curl
              pkgs.fzf
              # `proxy-ctl logs` follows in lnav, or in less without it.
              (if withLnav then pkgs.lnav else pkgs.less)
              pkgs.proxychains-ng
              pkgs.qrencode
            ]
            ++ lib.optional withSystemd pkgs.systemd
          )
        }" ${envFlags}
    '';
  };
in
proxyCtl
