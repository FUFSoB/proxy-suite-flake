# Build-time XRay configuration template for the server-side inbound service.
# Inbounds and proxy outbounds are both injected at service start time, so no
# credential reaches the Nix store.
{
  lib,
  derived,
  inboundRules,
  mkDnsServer,
}:

let
  inherit (derived) proxyCfg proxyInboundsCfg proxyInboundsNeedLocalProxy;

  # Relaying goes through the client stack's SOCKS listener rather than a second
  # copy of the outbound machinery, so the inbound service always follows the
  # currently selected outbound. Connect over loopback when the listener is on a
  # wildcard address.
  localProxyAddress =
    if builtins.elem proxyCfg.listenAddress [
      "0.0.0.0"
      "::"
      ""
    ] then
      "127.0.0.1"
    else
      proxyCfg.listenAddress;

  # Credentials, when the local proxy has them, are injected at start time.
  localProxyOutbound = lib.optional proxyInboundsNeedLocalProxy {
    protocol = "socks";
    tag = "proxy";
    settings = {
      servers = [
        {
          address = localProxyAddress;
          port = proxyCfg.port;
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

  # Filled in at start time from the listener spec.
  inbounds = [ ];

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
    domainStrategy = "IPIfNonMatch";
    domainMatcher = "hybrid";
    rules = inboundRules.xrayInboundRules;
  };
}
