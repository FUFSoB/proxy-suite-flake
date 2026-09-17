# Build-time XRay backend configuration templates.
# Proxy outbounds are injected at service start time, not here.
{
  lib,
  derived,
  rules,
}:

let
  constants = derived.constants;
  inherit (derived)
    proxyCfg
    globalTun
    globalTproxy
    perAppRoutingTun
    ;
  inherit (constants)
    globalTunIPv6Address
    perAppTunIPv6Address
    ;

  fakeDnsPools = [
    {
      ipPool = "198.18.0.0/15";
      poolSize = 32768;
    }
    {
      ipPool = "fc00::/18";
      poolSize = 32768;
    }
  ];

  dnsAddress =
    upstream: if upstream.type == "tcp" then "tcp://${upstream.address}" else upstream.address;

  mkDnsServer = tag: upstream: {
    address = dnsAddress upstream;
    inherit tag;
    port = upstream.port;
    queryStrategy = "UseIP";
  };

  # XRay routes each server's own queries by that server's tag: the backend filter pins
  # the proxy servers' names to "local", so reaching them never needs the proxy itself.
  mkDnsConfig =
    {
      fakeDns ? false,
      preferRemote ? (proxyCfg.routing.default == "proxy"),
    }:
    let
      primaryTag = if preferRemote then "remote" else "local";
      secondaryTag = if preferRemote then "local" else "remote";
      primaryUpstream = if preferRemote then proxyCfg.dns.remote else proxyCfg.dns.local;
      secondaryUpstream = if preferRemote then proxyCfg.dns.local else proxyCfg.dns.remote;
    in
    {
      queryStrategy = "UseIP";
      servers =
        lib.optional fakeDns {
          address = "fakedns";
          tag = "fakedns";
        }
        ++ [
          (mkDnsServer primaryTag primaryUpstream)
          (mkDnsServer secondaryTag secondaryUpstream)
        ];
    };

  mkSniffing =
    {
      fakeDnsOnly ? false,
    }:
    if fakeDnsOnly then
      {
        enabled = true;
        destOverride = [ "fakedns" ];
        # Fake IPs only live in memory: after a restart an app still holding one gets its
        # domain back from TLS/HTTP/QUIC instead of a dead end. Real IPs are left alone;
        # the cost is up to 200 ms before a server-speaks-first protocol (SSH, SMTP) starts.
        metadataOnly = false;
      }
    else
      {
        enabled = true;
        destOverride = [
          "http"
          "tls"
          "quic"
        ];
      };

  standardSniffing = mkSniffing { };

  target =
    tag:
    if tag == "proxy" && proxyCfg.selection == "urltest" then
      { balancerTag = "proxy"; }
    else
      { outboundTag = tag; };

  dnsHijackRule = inboundTag: {
    type = "field";
    inherit inboundTag;
    network = "tcp,udp";
    port = 53;
    outboundTag = "dns-out";
    ruleTag = "dns-hijack";
  };

  # As sing-box: remote through the proxy, local direct.
  dnsUpstreamRules = [
    {
      type = "field";
      inboundTag = [ "local" ];
      network = "tcp,udp";
      outboundTag = "direct";
      ruleTag = "dns-upstream-direct";
    }
    (
      {
        type = "field";
        inboundTag = [ "remote" ];
        network = "tcp,udp";
        ruleTag = "dns-upstream-remote";
      }
      // target "proxy"
    )
  ];

  finalRule =
    tag:
    {
      type = "field";
      network = "tcp,udp";
      ruleTag = "final-default";
    }
    // target tag;

  directOutbound =
    useOutboundRoutingMark:
    {
      protocol = "freedom";
      tag = "direct";
      settings = { };
    }
    // lib.optionalAttrs useOutboundRoutingMark {
      streamSettings.sockopt.mark = globalTproxy.proxyMark;
    };

  mkConfig =
    {
      enableMixed ? false,
      enableTProxy ? false,
      enableTun ? false,
      tunInterface ? globalTun.interface,
      tunAddress ? globalTun.address,
      tunIPv6Address ? null,
      tunMtu ? globalTun.mtu,
      useOutboundRoutingMark ? false,
      enableUrlTest ? proxyCfg.selection == "urltest",
      domainStrategy ? "IPIfNonMatch",
      enableTunFakeDns ? false,
    }:
    let
      tunSniffing = mkSniffing { fakeDnsOnly = enableTunFakeDns; };
      tproxyInboundTags = [ "tproxy-in" ] ++ lib.optional proxyCfg.ipv6 "tproxy-in6";
      # Every config takes packets for any destination, DNS included.
      dnsOutbounds = [
        {
          protocol = "dns";
          tag = "dns-out";
          settings = {
            userLevel = 0;
            # No resolver knows .onion, and asking one leaks the name. The TUN's fake DNS
            # answers with an address that routes to Tor by name; anything else is told there
            # is no such name.
            rules =
              lib.optionals derived.torRouteOnion (
                lib.optional enableTunFakeDns {
                  action = "hijack";
                  qType = "1,28";
                  domain = [ "domain:onion" ];
                }
                ++ [
                  {
                    action = "return";
                    rCode = 3;
                    domain = [ "domain:onion" ];
                  }
                ]
              )
              ++ [
                {
                  action = "direct";
                  qType = "2-27,29-65535";
                }
              ];
          };
        }
      ];
      routingRules =
        dnsUpstreamRules
        ++ lib.optional enableTun (dnsHijackRule [ "tun-in" ])
        ++ lib.optional enableTProxy (dnsHijackRule tproxyInboundTags)
        ++ rules.xrayRoutingRules
        ++ [ (finalRule (if (proxyCfg.routing.default == "proxy") then "proxy" else "direct")) ];
    in
    {
      log.loglevel = "warning";
      dns = mkDnsConfig { fakeDns = enableTunFakeDns; };
      inbounds =
        lib.optional enableMixed {
          tag = "mixed-in";
          protocol = "socks";
          listen = proxyCfg.listener.address;
          port = proxyCfg.listener.port;
          settings = {
            auth = "noauth";
            udp = true;
            ip = proxyCfg.listener.address;
          };
          sniffing = standardSniffing;
        }
        ++
          lib.zipListsWith
            (tag: listen: {
              inherit tag listen;
              protocol = "tunnel";
              port = globalTproxy.port;
              settings = {
                allowedNetwork = "tcp,udp";
                followRedirect = true;
              };
              streamSettings.sockopt.tproxy = "tproxy";
              sniffing = standardSniffing;
            })
            (lib.optionals enableTProxy tproxyInboundTags)
            [
              "127.0.0.1"
              "::1"
            ]
        ++ lib.optional enableTun {
          tag = "tun-in";
          protocol = "tun";
          settings = {
            name = tunInterface;
            mtu = tunMtu;
            gateway = [ tunAddress ] ++ lib.optional (proxyCfg.ipv6 && tunIPv6Address != null) tunIPv6Address;
            userLevel = 0;
          };
          sniffing = tunSniffing;
        };
      outbounds = dnsOutbounds ++ [
        (directOutbound useOutboundRoutingMark)
        {
          protocol = "blackhole";
          tag = "block";
          settings = { };
        }
      ];
      routing = {
        domainStrategy = domainStrategy;
        domainMatcher = "hybrid";
        rules = routingRules;
      }
      // lib.optionalAttrs enableUrlTest {
        balancers = [
          {
            tag = "proxy";
            selector = [ "proxy-suite-ob-" ];
            strategy = {
              type = "leastPing";
            };
          }
        ];
      };
    }
    // lib.optionalAttrs enableUrlTest {
      observatory = {
        subjectSelector = [ "proxy-suite-ob-" ];
        probeUrl = proxyCfg.urlTest.url;
        probeInterval = proxyCfg.urlTest.interval;
      };
    }
    // lib.optionalAttrs enableTunFakeDns { fakedns = fakeDnsPools; };
in
{
  # Reused by the server-side inbound template, which builds a different config
  # shape out of the same backend primitives.
  inherit mkDnsServer;

  # As sing-box's: without TProxy and marks on a rootless host.
  tproxy = mkConfig {
    enableMixed = true;
    enableTProxy = constants.privileged;
    useOutboundRoutingMark = constants.privileged;
  };

  tun = mkConfig {
    enableTun = true;
    tunInterface = globalTun.interface;
    tunAddress = globalTun.address;
    tunIPv6Address = globalTunIPv6Address;
    tunMtu = globalTun.mtu;
    useOutboundRoutingMark = true;
    enableTunFakeDns = true;
  };

  perAppTun = mkConfig {
    enableTun = true;
    tunInterface = perAppRoutingTun.interface;
    tunAddress = perAppRoutingTun.address;
    tunIPv6Address = perAppTunIPv6Address;
    tunMtu = perAppRoutingTun.mtu;
    useOutboundRoutingMark = true;
    enableTunFakeDns = true;
  };
}
