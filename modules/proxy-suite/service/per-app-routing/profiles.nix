# Per-app routing profile expansion and proxychains config.
{
  lib,
  pkgs,
  proxyCfg,
  perAppRoutingCfg,
  perAppRoutingTun,
  perAppRoutingTproxy,
  perAppZapretCfg,
}:

let
  perAppRoutingProfileNames = map (profile: profile.name) perAppRoutingCfg.profiles;
  defaultPerAppRoutingProfiles = lib.optionals perAppRoutingCfg.createDefaultProfiles (
    [
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

  localProxyAuth = proxyCfg.auth;
  localProxyAuthEnabled =
    localProxyAuth.username != null
    && (localProxyAuth.password != null || localProxyAuth.passwordFile != null);

  perAppRoutingProfilesFile = pkgs.writeText "proxy-suite-per-app-routing-profiles.json" (
    builtins.toJSON effectivePerAppRoutingProfiles
  );

  proxychainsConfigFile =
    if localProxyAuthEnabled then
      "/run/proxy-suite-socks/proxychains.conf"
    else
      pkgs.writeText "proxy-suite-proxychains.conf" ''
        strict_chain
        ${lib.optionalString perAppRoutingCfg.proxychains.quiet "quiet_mode"}
        ${lib.optionalString perAppRoutingCfg.proxychains.proxyDns "proxy_dns"}
        tcp_read_time_out 15000
        tcp_connect_time_out 8000

        [ProxyList]
        socks5 ${proxyCfg.listenAddress} ${toString proxyCfg.port}
      '';
  proxychainsQuietArg = lib.optionalString perAppRoutingCfg.proxychains.quiet "-q ";

  hasProxychainsProfiles = builtins.any (
    profile: profile.route == "proxychains"
  ) effectivePerAppRoutingProfiles;
  hasTunProfiles = builtins.any (profile: profile.route == "tun") effectivePerAppRoutingProfiles;
  hasTproxyProfiles = builtins.any (
    profile: profile.route == "tproxy"
  ) effectivePerAppRoutingProfiles;
  hasZapretProfiles = builtins.any (
    profile: profile.route == "zapret"
  ) effectivePerAppRoutingProfiles;
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
