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
        # Fake IPs map back to names; real addresses (DoH, stale caches, a restart's lost fake IPs)
        # get theirs sniffed. Costs up to 200 ms before a server-speaks-first protocol starts.
        destOverride = [ "fakedns+others" ];
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

  # No loopback by any name (sniffed, fake DNS, one resolving there): as the daemon it would
  # reach the hops the nft guard keeps from other users. dns.*'s loopback resolver stays.
  loopbackDnsPorts = lib.unique (
    map (upstream: upstream.port) (
      builtins.filter
        (
          upstream:
          lib.hasPrefix "127." upstream.address
          || builtins.elem upstream.address [
            "::1"
            "localhost"
          ]
        )
        [
          proxyCfg.dns.local
          proxyCfg.dns.remote
        ]
    )
  );
  directFinalRules = lib.optionals constants.privileged (
    lib.optional (loopbackDnsPorts != [ ]) {
      action = "allow";
      ip = derived.proxyInboundsLoopback;
      port = lib.concatMapStringsSep "," toString loopbackDnsPorts;
    }
    ++ [
      {
        action = "block";
        ip = derived.proxyInboundsLoopback;
        blockDelay = 0;
      }
    ]
  );

  directOutbound =
    useOutboundRoutingMark:
    {
      protocol = "freedom";
      tag = "direct";
      settings = lib.optionalAttrs (directFinalRules != [ ]) { finalRules = directFinalRules; };
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
      # A loopback port of this config's own, where dns-out hands the queries XRay's resolver
      # does not answer (HTTPS, MX, TXT, SRV...) to dns.remote through the proxy.
      remoteDnsBridgePort ? null,
    }:
    let
      remote = proxyCfg.dns.remote;
      # With routing.default = "direct" they keep going where they were sent, as all else does.
      remoteDnsBridge = remoteDnsBridgePort != null && proxyCfg.routing.default == "proxy";
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
          }
          # "direct" would forward the query past routing and the kill switch: to the bridge
          # instead, which routing takes through the proxy.
          // lib.optionalAttrs remoteDnsBridge {
            address = "127.0.0.1";
            port = remoteDnsBridgePort;
            network = if remote.type == "udp" then "udp" else "tcp";
          };
        }
      ];
      remoteDnsBridgeInbound = lib.optional remoteDnsBridge {
        tag = "dns-remote-in";
        protocol = "tunnel";
        listen = "127.0.0.1";
        port = remoteDnsBridgePort;
        # dns.remote as it is: pure XRay, the only user of this template, refuses "tls"
        # (service-assertions.nix), as XRay's DNS has no DoT.
        settings = {
          inherit (remote) address port;
          allowedNetwork = "tcp,udp";
        };
      };
      remoteDnsBridgeRule = lib.optional remoteDnsBridge (
        {
          type = "field";
          inboundTag = [ "dns-remote-in" ];
          ruleTag = "dns-remote-bridge";
        }
        // target "proxy"
      );
      # inbounds.routing.blockPrivate for the names the server's listeners hand mixed-in, which
      # this config looks up again (as backend-filter-private-guard.template.jq for sing-box).
      inboundsPrivateGuard =
        lib.optional
          (
            enableMixed
            && derived.pureXrayEnabled
            && derived.proxyInboundsEnabled
            && derived.proxyInboundsNeedLocalProxy
          )
          {
            type = "field";
            ruleTag = "inbounds-private-guard";
            inboundTag = [ "mixed-in" ];
            # Without blockPrivate, this host's loopback still, as the "direct" via's fence.
            ip =
              if derived.proxyInboundsCfg.routing.blockPrivate then
                [ "geoip:private" ]
              else
                derived.proxyInboundsLoopback;
            outboundTag = "block";
          };
      routingRules =
        remoteDnsBridgeRule
        ++ dnsUpstreamRules
        ++ lib.optional enableTun (dnsHijackRule [ "tun-in" ])
        ++ lib.optional enableTProxy (dnsHijackRule tproxyInboundTags)
        ++ inboundsPrivateGuard
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
        }
        ++ remoteDnsBridgeInbound;
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
    # Pure XRay only, where the hybrid sidecar's DNS bridge ports are free.
    remoteDnsBridgePort = constants.xrayDnsBridgePorts.socks;
  };

  tun = mkConfig {
    enableTun = true;
    tunInterface = globalTun.interface;
    tunAddress = globalTun.address;
    tunIPv6Address = globalTunIPv6Address;
    tunMtu = globalTun.mtu;
    useOutboundRoutingMark = true;
    enableTunFakeDns = true;
    remoteDnsBridgePort = constants.xrayDnsBridgePorts.tun;
  };

  perAppTun = mkConfig {
    enableTun = true;
    tunInterface = perAppRoutingTun.interface;
    tunAddress = perAppRoutingTun.address;
    tunIPv6Address = perAppTunIPv6Address;
    tunMtu = perAppRoutingTun.mtu;
    useOutboundRoutingMark = true;
    enableTunFakeDns = true;
    remoteDnsBridgePort = constants.xrayDnsBridgePorts.perAppTun;
  };
}
