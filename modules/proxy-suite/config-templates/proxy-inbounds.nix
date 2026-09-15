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

  localProxyAddress =
    if
      builtins.elem proxyCfg.listener.address [
        "0.0.0.0"
        "::"
        ""
      ]
    then
      "127.0.0.1"
    else
      proxyCfg.listener.address;

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

  inbounds = [ ];

  # Counters per user, inbound and outbound for proxy-suite-inbound-stats, and who is
  # connected right now, on loopback only.
  stats = { };
  api = {
    tag = "api";
    listen = "127.0.0.1:${toString derived.constants.inboundStatsApiPort}";
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

  outbounds = localProxyOutbound ++ [
    {
      protocol = "freedom";
      tag = "direct";
      settings = { };
    }
    {
      protocol = "blackhole";
      tag = "block";
      settings = { };
    }
  ];

  routing = {
    # AsIs where sing-box dials: resolving here made every new site wait on a
    # lookup through the proxy, and sing-box enforces blockPrivate after its
    # own. Where XRay dials itself it must resolve, and IPOnDemand: under
    # IPIfNonMatch the network-only final rule matches names unresolved.
    domainStrategy = if proxyInboundsResolveInSingBox then "AsIs" else "IPOnDemand";
    domainMatcher = "hybrid";
    rules = inboundRules.xrayInboundRules;
  };
}
