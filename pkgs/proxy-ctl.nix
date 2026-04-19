{
  lib,
  pkgs,
}:

{
  clashApi,
  selection,
  subscriptionTagsFile,
  perAppRoutingEnabled,
  perAppRoutingProxychainsEnabled,
  perAppRoutingTunEnabled,
  perAppRoutingTproxyEnabled,
  perAppRoutingZapretEnabled,
  perAppRoutingProfilesFile,
  proxychainsConfigFile,
  proxychainsQuietArg,
}:

let
  unwrapped = pkgs.writeShellScriptBin "proxy-ctl" (
    builtins.readFile ./proxy-ctl-lib.sh
    + "\n"
    + builtins.readFile ./proxy-ctl.sh
  );
in
pkgs.symlinkJoin {
  name = "proxy-ctl";
  paths = [ unwrapped ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    wrapProgram "$out/bin/proxy-ctl" \
      --prefix PATH : "${lib.makeBinPath [
        pkgs.coreutils
        pkgs.curl
        pkgs.gawk
        pkgs.gnugrep
        pkgs.jq
        pkgs.proxychains-ng
        pkgs.systemd
      ]}" \
      --set CLASH_API ${lib.escapeShellArg clashApi} \
      --set SELECTION ${lib.escapeShellArg selection} \
      --set SUB_TAGS_FILE ${lib.escapeShellArg (toString subscriptionTagsFile)} \
      --set PER_APP_ROUTING_ENABLED ${lib.escapeShellArg perAppRoutingEnabled} \
      --set PER_APP_ROUTING_PROXYCHAINS_ENABLED ${lib.escapeShellArg perAppRoutingProxychainsEnabled} \
      --set PER_APP_ROUTING_TUN_ENABLED ${lib.escapeShellArg perAppRoutingTunEnabled} \
      --set PER_APP_ROUTING_TPROXY_ENABLED ${lib.escapeShellArg perAppRoutingTproxyEnabled} \
      --set PER_APP_ROUTING_ZAPRET_ENABLED ${lib.escapeShellArg perAppRoutingZapretEnabled} \
      --set PER_APP_ROUTING_PROFILES_FILE ${lib.escapeShellArg (toString perAppRoutingProfilesFile)} \
      --set PROXYCHAINS_CONFIG ${lib.escapeShellArg (toString proxychainsConfigFile)} \
      --set PROXYCHAINS_QUIET_ARG ${lib.escapeShellArg (lib.removeSuffix " " proxychainsQuietArg)}
  '';
}
