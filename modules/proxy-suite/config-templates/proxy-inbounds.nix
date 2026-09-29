# XRay config template for the inbound service. Inbounds and pinned outbounds
# are injected at start, so no credential reaches the Nix store.
{
  lib,
  derived,
  inboundRules,
  mkDnsServer,
}:

let
  inherit (derived)
    proxyCfg
    proxyInboundsNeedLocalProxy
    proxyInboundsResolveInSingBox
    ;

  localProxyAddress = derived.localProxy.host;

  # Checked on the address actually dialed, so a name resolving private is caught too
  # (routing's geoip:private sees only literal IPs under AsIs). Explicit either way:
  # XRay's own default blocks private for vless/vmess/trojan/shadowsocks only, which
  # left socks/http open and ignored blockPrivate = false.
  directFinalRules =
    if derived.proxyInboundsCfg.routing.blockPrivate then
      [
        {
          action = "block";
          ip = [ "geoip:private" ];
        }
      ]
    else
      [ { action = "allow"; } ];

  # inbounds.routing.serverSource: a user's connections to this host, from the user's own
  # address on the dummy interface. Only ever to this host: its listed IPs where there are
  # some, and never somewhere private.
  serverIps =
    builtins.filter
      (a: !lib.hasPrefix "domain:" a && (lib.hasInfix ":" a || builtins.match "[0-9.]+" a != null))
      (
        lib.optional (derived.proxyInboundsCfg.serverAddress != null) derived.proxyInboundsCfg.serverAddress
        ++ derived.proxyInboundsCfg.serverAliases
      );
  selfFinalRules =
    if serverIps != [ ] then
      [
        {
          action = "allow";
          ip = serverIps;
        }
        { action = "block"; }
      ]
    else
      [
        {
          action = "block";
          ip = [ "geoip:private" ];
        }
      ];
  mkSelfOutbound = family: address: id: {
    protocol = "freedom";
    tag = "direct-self${family}-${id}";
    sendThrough = address;
    settings = {
      domainStrategy = if family == "4" then "UseIPv4" else "UseIPv6";
      finalRules = selfFinalRules;
    };
  };
  selfOutbounds = lib.concatMap (
    s:
    lib.optional (s.ipv4 != null) (mkSelfOutbound "4" s.ipv4 s.id)
    ++ lib.optional (s.ipv6 != null) (mkSelfOutbound "6" s.ipv6 s.id)
  ) derived.proxyInboundsSelfSources;

  # The client stack's SOCKS listener; credentials are injected at start.
  localProxyOutbound = lib.optional proxyInboundsNeedLocalProxy {
    protocol = "socks";
    tag = "proxy";
    settings = {
      servers = [
        {
          address = localProxyAddress;
          port = proxyCfg.listener.port;
        }
      ];
    };
  };
in
{
  log.loglevel = "warning";

  dns.servers = [
    (mkDnsServer "remote" proxyCfg.dns.remote)
    (mkDnsServer "local" proxyCfg.dns.local)
  ];

  # Counters per user, inbound and outbound for proxy-suite-inbound-stats, and who is
  # connected right now, from where. A socket rather than loopback, which any local
  # user could ask: the start script's setgid directory gives it the group that may
  # read the stats. The listeners are appended at start.
  inbounds = [
    {
      tag = "api-in";
      protocol = "dokodemo-door";
      listen = "${derived.constants.inboundStatsApiSocket},0660";
      settings = {
        address = "127.0.0.1";
        network = "unix";
      };
    }
  ];
  stats = { };
  api = {
    tag = "api";
    services = [ "StatsService" ];
  };
  policy = {
    levels."0" = {
      statsUserUplink = true;
      statsUserDownlink = true;
      statsUserOnline = true;
    };
    system = {
      statsInboundUplink = true;
      statsInboundDownlink = true;
      statsOutboundUplink = true;
      statsOutboundDownlink = true;
    };
  };

  outbounds =
    localProxyOutbound
    ++ [
      {
        protocol = "freedom";
        tag = "direct";
        settings.finalRules = directFinalRules;
      }
      {
        protocol = "blackhole";
        tag = "block";
        settings = { };
      }
    ]
    ++ selfOutbounds;

  routing = {
    # AsIs where sing-box dials: resolving here made every new site wait on a
    # lookup through the proxy, and sing-box enforces blockPrivate after its
    # own. Where XRay dials itself it must resolve, and IPOnDemand: under
    # IPIfNonMatch the network-only final rule matches names unresolved.
    domainStrategy = if proxyInboundsResolveInSingBox then "AsIs" else "IPOnDemand";
    domainMatcher = "hybrid";
    rules = [
      {
        ruleTag = "inbound-stats-api";
        inboundTag = [ "api-in" ];
        outboundTag = "api";
      }
    ]
    ++ inboundRules.xrayInboundRules;
  };
}
