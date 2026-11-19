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
    singBoxLogLevel
    connectionLogEnabled
    mitmCfg
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
        # proxy.dns.browserDoh: Firefox's canary. With no address, it leaves its own DNS off.
        ++ lib.optional (proxyCfg.dns.browserDoh != "allow") {
          domain = [ "use-application-dns.net" ];
          action = "predefined";
          rcode = "NXDOMAIN";
        }
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
  # With mitm.udp a slot has two more, switched with it: its UDP's, which takes "mitm-udp" where
  # the slot's takes "mitm" (mitmproxy's HTTP listener carries no UDP), and its QUIC's, which
  # blocks there, so a browser takes TCP and is read (per-app-routing/via.nix).
  mkPins =
    route: count: match:
    let
      slots = lib.genList (slot: slot) count;
      tag = slot: "proxy-suite-pin-${route}-${toString slot}";
      udp = derived.mitmUdpEnabled;
      selector = name: {
        type = "selector";
        tag = name;
        outbounds = [ "block" ];
        default = "block";
      };
    in
    {
      inherit route;
      rules = lib.concatMap (
        slot:
        lib.optionals udp [
          (
            match slot
            // {
              network = [ "udp" ];
              port = [ 443 ];
              outbound = "${tag slot}-quic";
            }
          )
          (
            match slot
            // {
              network = [ "udp" ];
              outbound = "${tag slot}-udp";
            }
          )
        ]
        ++ [ (match slot // { outbound = tag slot; }) ]
      ) slots;
      selectors = lib.concatMap (
        slot:
        [ (selector (tag slot)) ]
        ++ lib.optionals udp [
          (selector "${tag slot}-udp")
          (selector "${tag slot}-quic")
        ]
      ) slots;
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
      # mitm's listeners: what mitmproxy sends back, mitm.listener and mitm.interfaces.
      enableMitm ? false,
    }:
    let
      fakeIp = fakeIpCache != null && proxyCfg.dns.fakeIp.enable;
    in
    lib.recursiveUpdate
      (
        {
          log.level = singBoxLogLevel;

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
            ++ lib.optionals (enableMitm && derived.mitmOutboundEnabled) (
              # Its login is the hop login, set at start (backend-jq-filter.nix): whoever
              # connects here picks an exit past every routing rule.
              [
                {
                  type = "mixed";
                  tag = "mitm-return";
                  listen = "127.0.0.1";
                  listen_port = mitmCfg.returnPort;
                }
              ]
              ++ lib.optional derived.mitmListenerEnabled {
                type = "mixed";
                tag = "mitm-in";
                listen = mitmCfg.listener.address;
                listen_port = mitmCfg.listener.port;
              }
              ++ lib.optionals derived.mitmInterfacesEnabled (
                [
                  {
                    type = "tproxy";
                    tag = "mitm-tproxy-in";
                    listen = "127.0.0.1";
                    listen_port = mitmCfg.interfacesPort;
                  }
                ]
                ++ lib.optional proxyCfg.ipv6 {
                  type = "tproxy";
                  tag = "mitm-tproxy-in6";
                  listen = "::1";
                  listen_port = mitmCfg.interfacesPort;
                }
              )
              # mitm.udp: what mitmproxy sends on, marked by its user and diverted here
              # (nftables.nix), to leave by the upstream as mitm-return's TCP does. And the
              # TUN backends' UDP for mitmproxy, by SOCKS5 into the tunnel's one end, here; its
              # login is the hop login, set at start.
              ++ lib.optionals derived.mitmUdpEnabled (
                [
                  {
                    type = "socks";
                    tag = constants.mitmUdpRelayInbound;
                    listen = "127.0.0.1";
                    listen_port = mitmCfg.udp.relayPort;
                  }
                  {
                    type = "tproxy";
                    tag = constants.mitmUdpReturnInbound;
                    listen = "127.0.0.1";
                    listen_port = mitmCfg.udp.returnPort;
                    network = "udp";
                  }
                ]
                ++ lib.optional proxyCfg.ipv6 {
                  type = "tproxy";
                  tag = "${constants.mitmUdpReturnInbound}6";
                  listen = "::1";
                  listen_port = mitmCfg.udp.returnPort;
                  network = "udp";
                }
              )
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
          ++ lib.optionals (pins != null) pins.selectors
          # In every config, as the rules naming them are (rules.nix): mitmproxy itself, and
          # the selector its traffic leaves by, which the backend filter fills with every
          # outbound but "mitm" and `proxy-ctl mitm upstream` switches.
          ++ lib.optionals derived.mitmOutboundEnabled [
            {
              type = "http";
              tag = derived.mitmOutboundTag;
              server = "127.0.0.1";
              server_port = mitmCfg.port;
            }
            {
              type = "selector";
              tag = derived.mitmUpstreamSelector;
              outbounds = [ "direct" ];
              default = "direct";
              interrupt_exist_connections = true;
            }
          ]
          # mitm.udp in the TUN backends: their UDP for mitmproxy, to the local proxy's relay,
          # which has the tunnel. The local proxy has the tunnel itself under the tag.
          ++ lib.optional (derived.mitmUdpEnabled && !enableMitm) {
            type = "socks";
            tag = derived.mitmUdpTag;
            server = "127.0.0.1";
            server_port = mitmCfg.udp.relayPort;
            version = "5";
            username = constants.hopUser;
            password = "";
            network = "udp";
          };

          route = {
            default_domain_resolver = "local";
            rule_set =
              rules.geositeRuleSets ++ rules.geoIPRuleSets ++ rules.asnRuleSets ++ rules.remoteRuleSets;
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
        # mitm.udp: the way UDP reaches mitmproxy, its WireGuard listener on loopback. The keys
        # are set at start (backend-jq-filter.nix), from the file root drew them into.
        // lib.optionalAttrs (enableMitm && derived.mitmUdpEnabled) {
          endpoints = [
            {
              type = "wireguard";
              tag = derived.mitmUdpTag;
              address = [
                (builtins.head constants.mitmUdpAddresses)
              ]
              ++ lib.optionals proxyCfg.ipv6 (builtins.tail constants.mitmUdpAddresses);
              mtu = constants.mitmUdpMtu;
              private_key = "";
              peers = [
                {
                  address = "127.0.0.1";
                  port = mitmCfg.udp.port;
                  public_key = "";
                  allowed_ips = [ "0.0.0.0/0" ] ++ lib.optional proxyCfg.ipv6 "::/0";
                }
              ];
            }
          ];
        }
        // lib.optionalAttrs enableClashApi (clashApiBlock clashApiPort)
      )
      # Fake addresses handed out survive a restart, so apps still holding one keep working. The
      # start script creates the directory; nothing else is stored, since no selector of a TUN
      # config is switched through the Clash API.
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
    enableMitm = true;
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
    # Only for debug.connectionLog to read the connections.
    enableClashApi = connectionLogEnabled;
    clashApiPort = constants.globalTunClashApiPort;
    xrayDnsBridgePort = xrayDnsBridgePorts.tun;
    fakeIpCache = "tun";
  };

  perAppTun = mkConfig {
    enableTun = true;
    tunInterface = perAppRoutingTun.interface;
    tunAddress = perAppRoutingTun.address;
    tunIPv6Address = constants.perAppTunIPv6Address;
    pins = if perAppPinTun then tunPins else null;
    # The pins' selectors are switched through it; debug.connectionLog reads the connections.
    enableClashApi = perAppPinTun || connectionLogEnabled;
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
