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
  priorityOutboundFile,
  outboundInventoryFile,
  runtimeOutboundsDir,
  runtimeSubscriptionsDir,
  userControlGroup,
  localProxyUrl,
  autoProxyEnabled,
  autoProxyStateDir,
}:

let
  unwrapped = pkgs.writeShellScriptBin "proxy-ctl" (
    builtins.readFile ./proxy-ctl-lib.sh + "\n" + builtins.readFile ./proxy-ctl.sh
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
    PRIORITY_OUTBOUND_FILE = priorityOutboundFile;
    OUTBOUND_INVENTORY_FILE = outboundInventoryFile;
    RUNTIME_OUTBOUNDS_DIR = runtimeOutboundsDir;
    RUNTIME_SUBS_DIR = runtimeSubscriptionsDir;
    USER_CONTROL_GROUP = userControlGroup;
    LOCAL_PROXY_URL = localProxyUrl;
    AUTOPROXY_ENABLED = autoProxyEnabled;
    AUTOPROXY_STATE_DIR = autoProxyStateDir;
  };
in
pkgs.symlinkJoin {
  name = "proxy-ctl";
  paths = [ unwrapped ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
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
    install -Dm644 ${./proxy-ctl-completion.bash} \
      "$out/share/bash-completion/completions/proxy-ctl"
    probe_curl=$(ls ${pkgs.curl-impersonate}/bin/curl_chrome[0-9]* | grep -E '/curl_chrome[0-9]+$' | sort -V | tail -n 1)
    [ -x "$probe_curl" ]
    wrapProgram "$out/bin/proxy-ctl" \
      --set PROBE_CURL "$probe_curl" \
      --prefix PATH : "${
        lib.makeBinPath [
          # curl-impersonate's curl_chrome* wrappers are `#!/usr/bin/env bash`.
          pkgs.bash
          pkgs.coreutils
          pkgs.curl
          pkgs.fzf
          pkgs.gawk
          pkgs.gnugrep
          pkgs.jq
          pkgs.proxychains-ng
          pkgs.qrencode
          pkgs.systemd
        ]
      }" ${
        lib.concatStringsSep " " (
          lib.mapAttrsToList (name: value: "--set ${name} ${lib.escapeShellArg value}") wrapperEnv
        )
      }
  '';
}
