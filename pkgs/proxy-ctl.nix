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
  singBox,
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
    SING_BOX = singBox;
  };
  envFlags = lib.concatStringsSep " " (
    lib.mapAttrsToList (name: value: "--set ${name} ${lib.escapeShellArg value}") wrapperEnv
  );
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
      wrapProgram "$out/bin/proxy-tui" \
        --prefix PYTHONPATH : ${pkgs.writeTextDir "proxy_ctl.py" (builtins.readFile ./proxy-ctl/proxy_ctl.py)} \
        --prefix PATH : "${
          lib.makeBinPath [
            proxyCtl
            pkgs.systemd
          ]
        }" ${envFlags}
    '';
  };
  proxyCtl = pkgs.symlinkJoin {
    name = "proxy-ctl";
    paths = [ unwrapped ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    passthru.tui = tui;
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
