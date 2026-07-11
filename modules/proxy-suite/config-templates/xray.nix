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
    xrayGlobalTunIPv6Address
    xrayPerAppTunIPv6Address
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

  mkTunDnsConfig =
    {
      preferRemote ? proxyCfg.proxyByDefault,
    }:
    let
      primaryTag = if preferRemote then "remote" else "local";
      secondaryTag = if preferRemote then "local" else "remote";
      primaryUpstream = if preferRemote then proxyCfg.dns.remote else proxyCfg.dns.local;
      secondaryUpstream = if preferRemote then proxyCfg.dns.local else proxyCfg.dns.remote;
    in
    {
      queryStrategy = "UseIP";
      tag = "dns-in";
      servers = [
        {
          address = "fakedns";
          tag = "fakedns";
        }
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
        metadataOnly = true;
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

  tunDnsHijackRule = {
    type = "field";
    inboundTag = [ "tun-in" ];
    network = "tcp,udp";
    port = 53;
    outboundTag = "dns-out";
    ruleTag = "dns-hijack";
  };

  tunDnsUpstreamRule = {
    type = "field";
    inboundTag = [ "dns-in" ];
    network = "tcp,udp";
    outboundTag = "direct";
    ruleTag = "dns-upstream-direct";
  };

  finalRule =
    tag:
    {
      type = "field";
      network = "tcp,udp";
      ruleTag = "final-default";
    }
    // (
      if tag == "proxy" && proxyCfg.selection == "urltest" then
        { balancerTag = "proxy"; }
      else
        { outboundTag = tag; }
    );

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
      tunDnsServers = [
        (if proxyCfg.proxyByDefault then proxyCfg.dns.remote.address else proxyCfg.dns.local.address)
        (if proxyCfg.proxyByDefault then proxyCfg.dns.local.address else proxyCfg.dns.remote.address)
      ];
      tunSniffing = mkSniffing { fakeDnsOnly = enableTunFakeDns; };
      dnsConfig =
        if enableTunFakeDns then
          mkTunDnsConfig { }
        else
          {
            servers = [
              (mkDnsServer "remote" proxyCfg.dns.remote)
              (mkDnsServer "local" proxyCfg.dns.local)
            ];
          };
      tunOutbounds = lib.optionals enableTunFakeDns [
        {
          protocol = "dns";
          tag = "dns-out";
          settings = {
            userLevel = 0;
            rules = [
              {
                action = "direct";
                qType = "2-27,29-65535";
              }
            ];
          };
        }
      ];
      routingRules =
        lib.optionals enableTunFakeDns [
          tunDnsUpstreamRule
          tunDnsHijackRule
        ]
        ++ rules.xrayRoutingRules
        ++ [ (finalRule (if proxyCfg.proxyByDefault then "proxy" else "direct")) ];
    in
    {
      log.loglevel = "warning";
      dns = dnsConfig;
      inbounds =
        lib.optional enableMixed {
          tag = "mixed-in";
          protocol = "socks";
          listen = proxyCfg.listenAddress;
          port = proxyCfg.port;
          settings = {
            auth = "noauth";
            udp = true;
            ip = proxyCfg.listenAddress;
          };
          sniffing = standardSniffing;
        }
        ++ lib.optional enableTProxy {
          tag = "tproxy-in";
          protocol = "tunnel";
          listen = "127.0.0.1";
          port = globalTproxy.port;
          settings = {
            allowedNetwork = "tcp,udp";
            followRedirect = true;
          };
          streamSettings.sockopt.tproxy = "tproxy";
          sniffing = standardSniffing;
        }
        ++ lib.optional enableTun {
          tag = "tun-in";
          protocol = "tun";
          settings = {
            name = tunInterface;
            mtu = tunMtu;
            gateway = [ tunAddress ] ++ lib.optionals (tunIPv6Address != null) [ tunIPv6Address ];
            dns = tunDnsServers;
            userLevel = 0;
            autoOutboundsInterface = "auto";
          };
          sniffing = tunSniffing;
        };
      outbounds = tunOutbounds ++ [
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
  tproxy = mkConfig {
    enableMixed = true;
    enableTProxy = true;
    useOutboundRoutingMark = true;
  };

  tun = mkConfig {
    enableTun = true;
    tunInterface = globalTun.interface;
    tunAddress = globalTun.address;
    tunIPv6Address = xrayGlobalTunIPv6Address;
    tunMtu = globalTun.mtu;
    useOutboundRoutingMark = true;
    enableTunFakeDns = true;
  };

  perAppTun = mkConfig {
    enableTun = true;
    tunInterface = perAppRoutingTun.interface;
    tunAddress = perAppRoutingTun.address;
    tunIPv6Address = xrayPerAppTunIPv6Address;
    tunMtu = perAppRoutingTun.mtu;
    useOutboundRoutingMark = true;
    enableTunFakeDns = true;
  };
}
