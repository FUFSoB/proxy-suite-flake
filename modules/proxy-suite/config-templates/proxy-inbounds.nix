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

  # Checked on the address actually dialed, so a name resolving private is caught too; explicit,
  # as XRay's default covers some protocols only. This host's own addresses after it.
  # AmneziaWG "proxy" peers: cut off from each other and this host's network, via "direct" too.
  awgProxyPeerRules =
    let
      subnets = lib.concatMap (
        listener: [ listener.subnet ] ++ lib.optional (listener.subnet6 != null) listener.subnet6
      ) (builtins.filter (listener: listener.mode != "lan") derived.proxyInboundsAwg);
    in
    lib.optional (subnets != [ ]) {
      action = "block";
      ip = subnets;
    };
  directFinalRules =
    if derived.proxyInboundsCfg.routing.blockPrivate then
      [
        {
          action = "block";
          ip = [ "geoip:private" ];
        }
      ]
      ++ awgProxyPeerRules
      ++ hostRules
    else
      # Cloud instance metadata (credentials, IAM tokens) stays this host's alone, as for
      # the AmneziaWG listeners: blockPrivate = false opens the LAN, not that.
      [
        {
          action = "block";
          ip = derived.constants.cloudMetadata.ipv4 ++ derived.constants.cloudMetadata.ipv6;
        }
      ]
      ++ awgProxyPeerRules
      ++ hostRules
      ++ [ { action = "allow"; } ];
  # XRay's own queries to the resolvers below are routed too, through "direct" when that is
  # the via: one on this host stays reachable on its own port.
  isIpUpstream = upstream: builtins.match "[0-9.]+|[0-9a-fA-F:]+" upstream.address != null;
  resolverRules = lib.unique (
    map
      (upstream: {
        action = "allow";
        ip = [ upstream.address ];
        port = toString upstream.port;
      })
      (
        builtins.filter isIpUpstream [
          proxyCfg.dns.remote
          proxyCfg.dns.local
        ]
      )
  );
  hostRules = resolverRules ++ inboundRules.hostFenceRules;

  # inbounds.routing.serverSource: a user's connections to this host, from the user's own
  # address on the dummy interface. inbound_runtime.py makes the runtime users' the same way.
  mkSelfOutbound = family: address: id: {
    protocol = "freedom";
    tag = "direct-self${family}-${id}";
    sendThrough = address;
    settings = {
      domainStrategy = if family == "4" then "UseIPv4" else "UseIPv6";
      finalRules = inboundRules.selfFinalRules;
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
  # Without "access" XRay logs every connection: its user, their address, the site.
  log = {
    loglevel = "warning";
  }
  // lib.optionalAttrs (!(derived.proxyInboundsCfg.accessLog || proxyCfg.autoProxy.enable)) {
    access = "none";
  };

  dns.servers = [
    (mkDnsServer "remote" proxyCfg.dns.remote)
    (mkDnsServer "local" proxyCfg.dns.local)
  ];

  # Counters and online users for proxy-suite-inbound-stats, on a root-only socket (asking
  # resets counters). The listeners are appended at start.
  inbounds = [
    {
      tag = "api-in";
      protocol = "dokodemo-door";
      listen = "${derived.constants.inboundStatsApiSocket},0600";
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
    ++ inboundRules.exceptionOutbounds
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
