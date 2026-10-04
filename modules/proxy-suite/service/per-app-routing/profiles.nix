# Per-app routing profile expansion and proxychains config.
{ ctx }:

let
  inherit (ctx)
    lib
    pkgs
    proxyCfg
    perAppRoutingCfg
    perAppRoutingTun
    perAppRoutingTproxy
    perAppZapretCfg
    constants
    ;
  inherit (constants) runtimeDir;
  perAppRoutingProfileNames = map (profile: profile.name) perAppRoutingCfg.profiles;
  defaultPerAppRoutingProfiles = lib.optionals perAppRoutingCfg.createDefaultProfiles (
    lib.optionals perAppRoutingCfg.proxychains.enable [
      {
        name = "proxychains";
        route = "proxychains";
      }
    ]
    ++ lib.optionals perAppRoutingTun.enable [
      {
        name = "tun";
        route = "tun";
      }
    ]
    ++ lib.optionals perAppRoutingTproxy.enable [
      {
        name = "tproxy";
        route = "tproxy";
      }
    ]
    ++ lib.optionals perAppZapretCfg.enable [
      {
        name = "zapret";
        route = "zapret";
      }
    ]
  );
  effectivePerAppRoutingProfiles =
    perAppRoutingCfg.profiles
    ++ builtins.filter (
      profile: !(builtins.elem profile.name perAppRoutingProfileNames)
    ) defaultPerAppRoutingProfiles;
  effectivePerAppRoutingProfileNames = map (profile: profile.name) effectivePerAppRoutingProfiles;

  localProxyAuth = proxyCfg.listener.auth;
  localProxyAuthEnabled = ctx.localProxy.authEnabled;

  perAppRoutingProfilesFile = pkgs.writeText "proxy-suite-per-app" (
    builtins.toJSON effectivePerAppRoutingProfiles
  );

  proxychainsConfigFile =
    if localProxyAuthEnabled then
      "${runtimeDir}/proxy-suite-socks/proxychains.conf"
    else
      pkgs.writeText "proxy-suite-per-app" ''
        strict_chain
        ${lib.optionalString perAppRoutingCfg.proxychains.quiet "quiet_mode"}
        ${lib.optionalString perAppRoutingCfg.proxychains.proxyDns "proxy_dns"}
        tcp_read_time_out 15000
        tcp_connect_time_out 8000

        [ProxyList]
        socks5 ${proxyCfg.listener.address} ${toString proxyCfg.listener.port}
      '';
  proxychainsQuietArg = lib.optionalString perAppRoutingCfg.proxychains.quiet "-q ";

  # A profile run straight into an AmneziaWG interface uses no method, whatever its route.
  methodProfiles = builtins.filter (
    profile: (profile.outbound or null) == null || !ctx.perAppViaDirect profile.outbound
  ) effectivePerAppRoutingProfiles;
  hasRoute = route: builtins.any (profile: profile.route == route) methodProfiles;
  hasProxychainsProfiles = hasRoute "proxychains";
  hasTunProfiles = hasRoute "tun";
  hasTproxyProfiles = hasRoute "tproxy";
  hasZapretProfiles = hasRoute "zapret";
in
{
  inherit
    effectivePerAppRoutingProfiles
    effectivePerAppRoutingProfileNames
    perAppRoutingProfilesFile
    proxychainsConfigFile
    proxychainsQuietArg
    hasProxychainsProfiles
    hasTunProfiles
    hasTproxyProfiles
    hasZapretProfiles
    ;
}
