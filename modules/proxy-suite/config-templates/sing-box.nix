# Build-time sing-box backend configuration templates.
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
    singBoxCfg
    hybridEnabled
    globalTun
    globalTproxy
    clashApiEnabled
    perAppRoutingTun
    perAppPinSlots
    perAppPinTproxy
    perAppPinTun
    ;
  inherit (constants)
    xrayDnsBridgePorts
    ;
  defaultTunAutoRouteTableIndex = constants.tunAutoRouteTableIndex;
  defaultTunAutoRouteRulePriority = constants.tunAutoRouteRulePriority;

  mkDnsServer =
    tag: upstream: detour:
    {
      inherit tag;
      type = upstream.type;
      server = upstream.address;
      server_port = upstream.port;
    }
    // lib.optionalAttrs (detour != null) { inherit detour; };

  mkDnsConfig =
    {
      localDetour ? null,
      useOutboundRoutingMark ? false,
      fakeIp ? false,
      # Inbounds whose clients look names up in sing-box: .onion ones get a fake address there.
      onionFakeIpInbounds ? [ ],
    }:
    let
      onionFakeIp = derived.torRouteOnion && onionFakeIpInbounds != [ ];
    in
    {
      servers = [
        (mkDnsServer "remote" proxyCfg.dns.remote "proxy")
        (mkDnsServer "local" proxyCfg.dns.local localDetour)
      ]
      ++ map (
        ob:
        mkDnsServer (constants.awgDnsServerTag ob.tag) proxyCfg.dns.remote null
        // {
          bind_interface = ob.interface;
        }
        // lib.optionalAttrs useOutboundRoutingMark { routing_mark = globalTproxy.proxyMark; }
      ) derived.awgInterfaceOutbounds
      ++ lib.optional (fakeIp || onionFakeIp) {
        tag = "fakeip";
        type = "fakeip";
        inet4_range = proxyCfg.dns.fakeIp.inet4Range;
      }
      ++ proxyCfg.dns.singBox.servers;
      # The route mode keeps the user's rules and fake IP, and may drop what sits between.
      rules =
        proxyCfg.dns.singBox.rules
        # No resolver knows .onion, and asking one leaks the name. A transparent client gets a
        # fake address that routes to Tor by name; everything else is told there is no such name.
        ++ lib.optionals derived.torRouteOnion (
          lib.optional onionFakeIp {
            inbound = onionFakeIpInbounds;
            domain_suffix = [ "onion" ];
            query_type = [
              "A"
              "AAAA"
            ];
            server = "fakeip";
          }
          ++ [
            {
              domain_suffix = [ "onion" ];
              action = "predefined";
              rcode = "NXDOMAIN";
            }
          ]
        )
        ++ rules.singBoxDnsRules
        # Only what apps ask through the TUN: the XRay sidecar's and sing-box's own lookups
        # need real addresses.
        ++ lib.optional fakeIp {
          inbound = [ "tun-in" ];
          query_type = [
            "A"
            "AAAA"
          ];
          server = "fakeip";
        };
      final = if (proxyCfg.routing.default == "proxy") then "remote" else "local";
    }
    // lib.optionalAttrs (proxyCfg.dns.strategy != null) { inherit (proxyCfg.dns) strategy; }
    // lib.optionalAttrs (proxyCfg.dns.clientSubnet != null) {
      client_subnet = proxyCfg.dns.clientSubnet;
    };

  xrayDnsBridgeHijackRule = {
    inbound = [ "xray-dns-in" ];
    network = [
      "tcp"
      "udp"
    ];
    action = "hijack-dns";
  };

  clashApiBlock = port: {
    experimental.clash_api.external_controller = "127.0.0.1:${toString port}";
  };

  # perAppRouting.via's pin slots (constants.perAppPinRulePriority): a selector each, which the
  # backend filter fills with every outbound, block first and by default, and the Clash API
  # switches to the outbound an app runs through. `match` is what of an app's connection
  # tells its slot apart.
  mkPins =
    route: count: match:
    let
      slots = lib.genList (slot: slot) count;
      tag = slot: "proxy-suite-pin-${route}-${toString slot}";
    in
    {
      inherit route;
      rules = map (slot: match slot // { outbound = tag slot; }) slots;
      selectors = map (slot: {
        type = "selector";
        tag = tag slot;
        outbounds = [ "block" ];
        default = "block";
      }) slots;
    };
  pinTproxyInbound = slot: "per-app-pin-tproxy-${toString slot}";
  tproxyPins = mkPins "tproxy" perAppPinSlots (slot: {
    inbound = [ (pinTproxyInbound slot) ] ++ lib.optional proxyCfg.ipv6 "${pinTproxyInbound slot}-6";
  });
  # The slot's source, which its packets are SNATed to as they enter the TUN.
  tunPins = mkPins "tun" perAppPinSlots (
    slot:
    let
      source = constants.perAppPinTunSource slot;
    in
    {
      inbound = [ "tun-in" ];
      source_ip_cidr = [ "${source.ipv4}/32" ] ++ lib.optional proxyCfg.ipv6 "${source.ipv6}/128";
    }
  );

  mkConfig =
    {
      enableMixed ? false,
      enableTProxy ? false,
      enableTun ? false,
      tunInterface ? globalTun.interface,
      tunAddress ? globalTun.address,
      # With proxy.ipv6: both families in the TUN, so strict_route rejects neither.
      tunIPv6Address ? null,
      tunMtu ? globalTun.mtu,
      tunAutoRoute ? true,
      tunAutoRouteTableIndex ? defaultTunAutoRouteTableIndex,
      tunAutoRouteRuleIndex ? defaultTunAutoRouteRulePriority,
      tunAutoRedirect ? true,
      tunStrictRoute ? true,
      forceLocalDnsViaProxy ? false,
      useOutboundRoutingMark ? false,
      enableClashApi ? clashApiEnabled,
      clashApiPort ? singBoxCfg.clashApiPort,
      # perAppRouting.via's pin slots, of mkPins.
      pins ? null,
      enableXrayDnsBridge ? hybridEnabled,
      xrayDnsBridgePort ? xrayDnsBridgePorts.socks,
      # Names the fake IP cache: TUN configs only.
      fakeIpCache ? null,
    }:
    let
      fakeIp = fakeIpCache != null && proxyCfg.dns.fakeIp.enable;
    in
    lib.recursiveUpdate
      (
        {
          log.level = "warn";

          dns = mkDnsConfig {
            localDetour = if forceLocalDnsViaProxy then "proxy" else null;
            inherit useOutboundRoutingMark fakeIp;
            onionFakeIpInbounds =
              lib.optional enableTun "tun-in"
              ++ lib.optionals enableTProxy ([ "tproxy-in" ] ++ lib.optional proxyCfg.ipv6 "tproxy-in6");
          };

          inbounds =
            lib.optional enableXrayDnsBridge {
              type = "direct";
              tag = "xray-dns-in";
              listen = "127.0.0.1";
              listen_port = xrayDnsBridgePort;
            }
            ++ lib.optional enableMixed {
              type = "mixed";
              tag = "mixed-in";
              listen = proxyCfg.listener.address;
              listen_port = proxyCfg.listener.port;
            }
            ++ lib.optionals enableTProxy (
              [
                {
                  type = "tproxy";
                  tag = "tproxy-in";
                  listen = "127.0.0.1";
                  listen_port = globalTproxy.port;
                }
              ]
              ++ lib.optional proxyCfg.ipv6 {
                type = "tproxy";
                tag = "tproxy-in6";
                listen = "::1";
                listen_port = globalTproxy.port;
              }
            )
            ++ lib.optionals (enableTProxy && pins != null && pins.route == "tproxy") (
              lib.concatMap (
                slot:
                [
                  {
                    type = "tproxy";
                    tag = pinTproxyInbound slot;
                    listen = "127.0.0.1";
                    listen_port = constants.perAppPinTproxyPortBase + slot;
                  }
                ]
                ++ lib.optional proxyCfg.ipv6 {
                  type = "tproxy";
                  tag = "${pinTproxyInbound slot}-6";
                  listen = "::1";
                  listen_port = constants.perAppPinTproxyPortBase + slot;
                }
              ) (lib.genList (slot: slot) perAppPinSlots)
            )
            ++ lib.optional enableTun (
              {
                type = "tun";
                tag = "tun-in";
                interface_name = tunInterface;
                address = [ tunAddress ] ++ lib.optional (proxyCfg.ipv6 && tunIPv6Address != null) tunIPv6Address;
                mtu = tunMtu;
                auto_route = tunAutoRoute;
                auto_redirect = tunAutoRedirect;
                strict_route = tunStrictRoute;
                stack = "mixed";
              }
              // lib.optionalAttrs tunAutoRoute {
                iproute2_table_index = tunAutoRouteTableIndex;
                iproute2_rule_index = tunAutoRouteRuleIndex;
              }
            );

          outbounds = [
            (
              {
                type = "direct";
                tag = "direct";
              }
              // lib.optionalAttrs useOutboundRoutingMark { routing_mark = globalTproxy.proxyMark; }
            )
            {
              type = "block";
              tag = "block";
            }
          ]
          ++ lib.optionals (pins != null) pins.selectors;

          route = {
            default_domain_resolver = "local";
            rule_set = rules.geositeRuleSets ++ rules.geoIPRuleSets ++ rules.remoteRuleSets;
            # The pins go after the common hijack-dns and sniff rules, wherever the backend
            # filter finds those.
            rules =
              lib.optionals enableXrayDnsBridge [ xrayDnsBridgeHijackRule ]
              ++ rules.singBoxRoutingRules
              ++ lib.optionals (pins != null) pins.rules;
            final = if (proxyCfg.routing.default == "proxy") then "proxy" else "direct";
          }
          // lib.optionalAttrs (enableTun && tunAutoRoute) {
            auto_detect_interface = true;
          };
        }
        // lib.optionalAttrs enableClashApi (clashApiBlock clashApiPort)
      )
      # Fake addresses handed out survive a restart, so apps still holding one keep working. The
      # start script creates the directory; nothing else is stored, since TUN configs have no
      # Clash API to switch a selector with.
      (
        lib.optionalAttrs fakeIp {
          experimental.cache_file = {
            enabled = true;
            path = "${constants.fakeIpCacheDir}/${fakeIpCache}.db";
            store_fakeip = true;
          };
        }
      );
in
{
  # The local proxy, ready for TProxy. A rootless host can neither take transparent
  # connections nor mark sockets: there it is the SOCKS/HTTP listener alone.
  tproxy = mkConfig {
    enableMixed = true;
    enableTProxy = constants.privileged;
    pins = if perAppPinTproxy then tproxyPins else null;
    useOutboundRoutingMark = constants.privileged;
    xrayDnsBridgePort = xrayDnsBridgePorts.socks;
  };

  tun = mkConfig {
    enableTun = true;
    tunInterface = globalTun.interface;
    tunAddress = globalTun.address;
    tunIPv6Address = constants.globalTunIPv6Address;
    tunMtu = globalTun.mtu;
    tunAutoRoute = true;
    tunAutoRedirect = true;
    tunStrictRoute = true;
    forceLocalDnsViaProxy = false;
    enableClashApi = false;
    xrayDnsBridgePort = xrayDnsBridgePorts.tun;
    fakeIpCache = "tun";
  };

  perAppTun = mkConfig {
    enableTun = true;
    tunInterface = perAppRoutingTun.interface;
    tunAddress = perAppRoutingTun.address;
    tunIPv6Address = constants.perAppTunIPv6Address;
    pins = if perAppPinTun then tunPins else null;
    # The pins' selectors are switched through it.
    enableClashApi = perAppPinTun;
    clashApiPort = constants.perAppTunClashApiPort;
    tunMtu = perAppRoutingTun.mtu;
    tunAutoRoute = false;
    tunAutoRedirect = false;
    tunStrictRoute = false;
    forceLocalDnsViaProxy = false;
    useOutboundRoutingMark = globalTproxy.enable;
    xrayDnsBridgePort = xrayDnsBridgePorts.perAppTun;
    fakeIpCache = "per-app-tun";
  };
}
