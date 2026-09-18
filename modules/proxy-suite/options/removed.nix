{ lib, ... }:

let
  p = (import ./lib.nix { inherit lib; }).path;
  rm = path: replacement: lib.mkRemovedOptionModule (p path) replacement;
  # Top-level zapret options that moved under the engine namespace; the value is
  # the leaf name they carry there.
  zapretMoved = {
    configName = "configName";
    gameFilter = "gameFilter";
    hostlistRules = "hostlistRules";
    includeExtraUpstreamLists = "includeExtraUpstreamLists";
    listGeneral = "domains";
    listExclude = "excludeDomains";
    ipsetAll = "ips";
    ipsetExclude = "excludeIps";
  };
in
{
  imports = [
    # The tray indicator became Proxy Suite GUI, which has the tray icon built in.
    (lib.mkRenamedOptionModule (p "tray.enable") (p "gui.enable"))
    (lib.mkRenamedOptionModule (p "tray.autostart") (p "gui.autostart"))
    (lib.mkRenamedOptionModule (p "tray.pollInterval") (p "gui.refreshInterval"))

    # These were aliases; they are removal notices now, so there is one
    # compatibility policy instead of two.
    (rm "proxyInbounds" "Use services.proxy-suite.inbounds.")
    (rm "proxy.tun.perApp" "Use services.proxy-suite.perAppRouting.tun.")
    (rm "proxy.tproxy.perApp" "Use services.proxy-suite.perAppRouting.tproxy.")
    (rm "zapret.perApp" "Use services.proxy-suite.perAppRouting.zapret.")
    (rm "proxy.singBox.urlTest.tolerance" "Use services.proxy-suite.proxy.urlTest.tolerance.")
    (rm "tgWsProxy.host" "Use services.proxy-suite.tgWsProxy.listener.address.")
    (rm "singBox" "Use services.proxy-suite.proxy, with sing-box-specific options under proxy.singBox.")

    # proxy.
    (rm "proxy.singBox.enable" ''Use services.proxy-suite.proxy.backend = "sing-box" (or "hybrid").'')
    (rm "proxy.xray.enable" ''Use services.proxy-suite.proxy.backend = "xray" (or "hybrid").'')
    (rm "proxy.listenAddress" "Use services.proxy-suite.proxy.listener.address.")
    (rm "proxy.port" "Use services.proxy-suite.proxy.listener.port.")
    (rm "proxy.auth.username" "Use services.proxy-suite.proxy.listener.auth.username.")
    (rm "proxy.auth.password" "Use services.proxy-suite.proxy.listener.auth.password.")
    (rm "proxy.auth.passwordFile" "Use services.proxy-suite.proxy.listener.auth.passwordFile.")
    (rm "proxy.proxyByDefault" ''Use services.proxy-suite.proxy.routing.default = "proxy" or "direct".'')
    (rm "proxy.routing.enableRuDirect" "Use services.proxy-suite.proxy.routing.directRu.")
    (rm "proxy.tun.autostart" ''Use services.proxy-suite.proxy.autostart = "tun".'')
    (rm "proxy.tproxy.autostart" ''Use services.proxy-suite.proxy.autostart = "tproxy".'')

    # zapret. Both engines now spell their lists the same way.
    (rm "zapret.syncDirectRouting" "Use services.proxy-suite.zapret.directSync.enable.")
    (rm "zapret.syncDirectRoutingUpstreamIps" "Use services.proxy-suite.zapret.directSync.upstreamIps.")
    (rm "zapret.syncDirectRoutingUserIps" "Use services.proxy-suite.zapret.directSync.userIps.")

    # sshProxy splits into server (where it dials) and listener (what it opens).
    (rm "sshProxy.user" "Use services.proxy-suite.sshProxy.server.user.")
    (rm "sshProxy.host" "Use services.proxy-suite.sshProxy.server.host.")
    (rm "sshProxy.sshPort" "Use services.proxy-suite.sshProxy.server.port.")
    (rm "sshProxy.listenAddress" "Use services.proxy-suite.sshProxy.listener.address.")
    (rm "sshProxy.listenPort" "Use services.proxy-suite.sshProxy.listener.port.")

    # tgWsProxy groups its listener, Cloudflare and logging knobs.
    (rm "tgWsProxy.port" "Use services.proxy-suite.tgWsProxy.listener.port.")
    (rm "tgWsProxy.cfProxyDomains" "Use services.proxy-suite.tgWsProxy.cloudflare.domains.")
    (rm "tgWsProxy.cfProxyWorkerDomains" "Use services.proxy-suite.tgWsProxy.cloudflare.workerDomains.")
    (rm "tgWsProxy.cfProxyFallback" "Use services.proxy-suite.tgWsProxy.cloudflare.fallback.")
    (rm "tgWsProxy.bufKb" "Use services.proxy-suite.tgWsProxy.bufferKiB.")
    (rm "tgWsProxy.routingMark" "Use services.proxy-suite.tgWsProxy.fwmark.")
    (rm "tgWsProxy.verbose" "Use services.proxy-suite.tgWsProxy.log.verbose.")
    (rm "tgWsProxy.logFile" "Use services.proxy-suite.tgWsProxy.log.file.")
    (rm "tgWsProxy.logMaxMb" "Use services.proxy-suite.tgWsProxy.log.maxSizeMiB.")
    (rm "tgWsProxy.logBackups" "Use services.proxy-suite.tgWsProxy.log.keep.")

    # userControl.
    (rm "userControl.global.enable" ''Use services.proxy-suite.userControl.enable, with "services" in userControl.scopes.'')
    (rm "userControl.perApp.enable" ''Use services.proxy-suite.userControl.enable, with "perApp" in userControl.scopes.'')
    (rm "userControl.allow" "Use services.proxy-suite.userControl.enable, and userControl.scopes to limit it.")
  ]
  ++ lib.mapAttrsToList (
    old: new: rm "zapret.${old}" "Use services.proxy-suite.zapret.zapret-discord-youtube.${new}."
  ) zapretMoved;
}
