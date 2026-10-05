# XRay routing for the inbound service. Separate from the client ruleset:
# "proxy" here is the client stack's SOCKS listener, so its selection applies.
{
  lib,
  proxyInboundsCfg,
  proxyInbounds,
  proxyInboundsRouteOnion,
  proxyInboundsResolveInSingBox,
  proxyInboundsSelfSources,
  proxyInboundsRuntimeEnabled,
  proxyInboundsRuntimeVias,
  proxyInboundsHostPorts,
  proxyInboundsLoopback,
  zapretDirectRules,
}:

let
  defaultVia = proxyInboundsCfg.routing.via;

  # inbounds.runtime: the start script (inbound_runtime.py) adds the runtime listeners' tags
  # to every rule marked with the listeners it is for, by their via, and drops the marked
  # rules no listener is left in. So with runtime listeners possible, a rule stays even
  # while no declared listener is in it. "_anchor" rules are where the runtime users'
  # serverSource rules go; they are replaced whether or not there are any.
  runtime = proxyInboundsRuntimeEnabled;
  mark = members: rule: rule // lib.optionalAttrs runtime { _members = members; };
  forException = mark { notVia = [ "block" ]; };
  forDefault = mark { via = [ defaultVia ]; };
  any = tags: tags != [ ] || runtime;

  # Listeners on the default egress are covered by the final rule.
  overrideInbounds = builtins.filter (ib: ib.via != defaultVia) proxyInbounds;
  defaultInboundTags = map (ib: ib.tag) (builtins.filter (ib: ib.via == defaultVia) proxyInbounds);

  # A blocked listener stays blocked: neither serverAddress nor the proxy exceptions open it.
  exceptionInboundTags = map (ib: ib.tag) (builtins.filter (ib: ib.via != "block") proxyInbounds);

  # .onion goes to the local proxy, which hands it to Tor; first, so no IP rule looks it up.
  # An address with an .onion SNI keeps its listener's via (mkSniffGuard).
  onionListeners = builtins.filter (
    ib: ib.via != "block" && ib.listener.type != "amneziawg"
  ) proxyInbounds;
  onionRule =
    lib.optionals (proxyInboundsRouteOnion && proxyInboundsResolveInSingBox) (
      mkSniffGuard "inbound-tor-onion-sniffed" [ "domain:onion" ] onionListeners runtimeOpenVias { }
    )
    ++ lib.optional proxyInboundsRouteOnion (forException {
      type = "field";
      ruleTag = "inbound-tor-onion";
      domain = [ "domain:onion" ];
      inboundTag = map (ib: ib.tag) (
        builtins.filter (ib: ib.via != "block" && ib.listener.type != "amneziawg") proxyInbounds
      );
      outboundTag = "proxy";
    });

  blockPrivateRule = lib.optional proxyInboundsCfg.routing.blockPrivate {
    type = "field";
    ruleTag = "inbound-block-private";
    ip = [ "geoip:private" ];
    outboundTag = "block";
  };

  # The address clients dial must stay reachable even when blockRu covers it
  # (a .ru domain or IP). After blockPrivate, so it cannot open the LAN. Its aliases
  # too: routing.via usually cannot loop back to this host, so they would fail there.
  # A "domain:" alias is a suffix, for a wildcard DNS record: the name and every name under it.
  isSuffix = lib.hasPrefix "domain:";
  isIp =
    addr:
    !isSuffix addr
    && (lib.hasInfix ":" addr || builtins.match "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+" addr != null);
  serverAddresses =
    lib.optional (proxyInboundsCfg.serverAddress != null) proxyInboundsCfg.serverAddress
    ++ proxyInboundsCfg.serverAliases;
  serverIps = lib.unique (builtins.filter isIp serverAddresses);
  serverNames = lib.unique (builtins.filter (addr: !isIp addr) serverAddresses);

  # Only the ports clients dial there, and the ones listed as public: the rest of this host
  # (wildcard services the firewall keeps from the internet) must not be reachable through it.
  # An allow toward "direct" only: hostFenceRules below refuse the rest there.
  serverAddressPorts = proxyInboundsHostPorts;

  # XRay routes a UDP session by its first packet, so no exception leads to plain "direct"
  # over UDP: IP rules go to outbounds whose finalRules allow only those addresses, name rules
  # are held to TCP.
  exceptionTarget =
    field: ipOutbound:
    if field == "ip" then
      { outboundTag = ipOutbound; }
    else
      {
        outboundTag = "direct";
        network = "tcp";
      };

  # Names and IPs in rules of their own: XRay ANDs the fields of one rule.
  mkServerAddressRule =
    ruleTag: field: items:
    lib.optional (items != [ ] && any exceptionInboundTags) (
      forException (
        {
          type = "field";
          inherit ruleTag;
          ${field} = items;
          inboundTag = exceptionInboundTags;
          port = serverPortList;
        }
        // exceptionTarget field "direct-server"
      )
    );

  # Sniffing is routeOnly (proxy_inbound.py): a name rule also matches a connection to an IP
  # whose TLS SNI or HTTP Host carries that name, and "direct" then dials the IP, from this
  # host's own address. Any client could reach any address past routing.via that way by
  # naming this host (or a zapret site) in its handshake. So before a name rule sends
  # anything direct, a connection to an IP it would match goes where it would have gone
  # without the name rule: its listener's via. Under AsIs an ip condition matches only
  # connections to an IP. Under IPOnDemand it resolves names as well, so there it only works
  # after the IP rules, which a name resolving to this host matches first.
  anyIp = [
    "0.0.0.0/0"
    "::/0"
  ];
  # One rule per via; runtimeVias get theirs even with no declared listener on them.
  mkSniffGuard =
    ruleTag: domains: inbounds: runtimeVias: extra:
    lib.mapAttrsToList (
      via: ibs:
      mark { via = [ via ]; } (
        {
          type = "field";
          ruleTag = "${ruleTag}-${via}";
          domain = domains;
          ip = anyIp;
          inboundTag = map (ib: ib.tag) ibs;
          outboundTag = via;
        }
        // extra
      )
    ) (lib.genAttrs (lib.optionals runtime runtimeVias) (_: [ ]) // lib.groupBy (ib: ib.via) inbounds);
  # Where a runtime listener that is not blocked may exit.
  runtimeOpenVias = builtins.filter (via: via != "block") proxyInboundsRuntimeVias;

  serverNameDomains = map (name: if isSuffix name then name else "full:${name}") serverNames;
  serverPortList = lib.concatMapStringsSep "," toString serverAddressPorts;

  # inbounds.routing.serverSource: each user's connections to this host leave from the
  # user's own address (the "direct-self" outbounds, config-templates/proxy-inbounds.nix),
  # ahead of the rules that dial them from this host's. A name is dialed over the family the
  # user has an address in.
  serverIps4 = builtins.filter (ip: !lib.hasInfix ":" ip) serverIps;
  serverIps6 = builtins.filter (lib.hasInfix ":") serverIps;
  mkSelfRule =
    ruleTag: field: items: source: outboundTag:
    lib.optional (items != [ ] && any exceptionInboundTags) (forException {
      type = "field";
      ruleTag = "${ruleTag}-${source.id}";
      ${field} = items;
      user = [ source.email ];
      inboundTag = exceptionInboundTags;
      port = serverPortList;
      inherit outboundTag;
    });
  selfIpRules = lib.concatMap (
    s:
    lib.optionals (s.ipv4 != null) (
      mkSelfRule "inbound-server-address-self-ip4" "ip" serverIps4 s "direct-self4-${s.id}"
    )
    ++ lib.optionals (s.ipv6 != null) (
      mkSelfRule "inbound-server-address-self-ip6" "ip" serverIps6 s "direct-self6-${s.id}"
    )
  ) proxyInboundsSelfSources;
  selfNameRules = lib.concatMap (
    s:
    mkSelfRule "inbound-server-address-self" "domain" serverNameDomains s (
      if s.ipv4 != null then "direct-self4-${s.id}" else "direct-self6-${s.id}"
    )
  ) proxyInboundsSelfSources;
  # The runtime users' rules, as the declared users' are made: inbound_runtime.py numbers
  # them and makes one of each per user from these.
  serverSourceOn =
    proxyInboundsCfg.routing.serverSource.ipv4 != null
    || proxyInboundsCfg.routing.serverSource.ipv6 != null;
  mkSelfAnchor =
    anchor: fields:
    lib.optional (runtime && serverSourceOn) (
      forException (
        {
          _anchor = anchor;
          ruleTag = "inbound-runtime-anchor-${anchor}";
          inboundTag = exceptionInboundTags;
          port = serverPortList;
        }
        // fields
      )
    );
  serverNameGuarded = proxyInboundsResolveInSingBox || serverIps != [ ];
  serverAddressRule =
    selfIpRules
    ++ mkSelfAnchor "selfIp" {
      ip4 = serverIps4;
      ip6 = serverIps6;
    }
    ++ mkServerAddressRule "inbound-server-address-direct-ip" "ip" serverIps
    ++ lib.optionals (serverNames != [ ] && serverNameGuarded && any exceptionInboundTags) (
      mkSniffGuard "inbound-server-address-sniffed" serverNameDomains (builtins.filter (
        ib: ib.via != "block"
      ) proxyInbounds) runtimeOpenVias { port = serverPortList; }
    )
    ++ lib.optionals (serverNames != [ ] && serverNameGuarded) (
      selfNameRules ++ mkSelfAnchor "selfName" { domain = serverNameDomains; }
    )
    ++ mkServerAddressRule "inbound-server-address-direct" "domain" serverNameDomains;

  blockRuRules = lib.optionals proxyInboundsCfg.routing.blockRu [
    {
      type = "field";
      ruleTag = "inbound-block-ru-domain";
      domain = [ "geosite:category-ru" ];
      outboundTag = "block";
    }
    {
      type = "field";
      ruleTag = "inbound-block-ru-ip";
      ip = [ "geoip:ru" ];
      outboundTag = "block";
    }
  ];

  inboundProxy = proxyInboundsCfg.routing.proxy;

  proxyDomainRule =
    lib.optional
      (any exceptionInboundTags && (inboundProxy.domains != [ ] || inboundProxy.geosites != [ ]))
      (forException {
        type = "field";
        ruleTag = "inbound-proxy-domain";
        domain =
          map (domain: "domain:${domain}") inboundProxy.domains
          ++ map (name: "geosite:${name}") inboundProxy.geosites;
        inboundTag = exceptionInboundTags;
        outboundTag = "proxy";
      });

  proxyIpRule =
    lib.optional (any exceptionInboundTags && (inboundProxy.ips != [ ] || inboundProxy.geoips != [ ]))
      (forException {
        type = "field";
        ruleTag = "inbound-proxy-ip";
        ip = inboundProxy.ips ++ map (name: "geoip:${name}") inboundProxy.geoips;
        inboundTag = exceptionInboundTags;
        outboundTag = "proxy";
      });

  # Only when the default egress is a proxy, and only for its listeners.
  zapretDirectEnabled =
    proxyInboundsCfg.routing.zapretDirect
    && any defaultInboundTags
    && !builtins.elem defaultVia [
      "direct"
      "block"
    ];

  mkZapretRule =
    ruleTag: field: items:
    lib.optional (zapretDirectEnabled && items != [ ]) (
      forDefault (
        {
          type = "field";
          inherit ruleTag;
          ${field} = items;
          inboundTag = defaultInboundTags;
        }
        // exceptionTarget field "direct-zapret"
      )
    );

  zapretDomains = map (domain: "domain:${domain}") zapretDirectRules.domains;
  # Under IPOnDemand the guard would take every zapret name too: the domain rule stays off.
  zapretRules =
    mkZapretRule "inbound-zapret-direct-ip" "ip" zapretDirectRules.ips
    ++ lib.optionals (zapretDirectEnabled && zapretDomains != [ ] && proxyInboundsResolveInSingBox) (
      mkSniffGuard "inbound-zapret-sniffed" zapretDomains (builtins.filter (
        ib: builtins.elem ib.tag defaultInboundTags
      ) proxyInbounds) [ defaultVia ] { }
    )
    ++ lib.optionals proxyInboundsResolveInSingBox (
      mkZapretRule "inbound-zapret-direct-domain" "domain" zapretDomains
    );

  overrideRules = map (ib: {
    type = "field";
    ruleTag = "inbound-via-${ib.tag}";
    inboundTag = [ ib.tag ];
    outboundTag = ib.via;
  }) overrideInbounds;

  finalRule = {
    type = "field";
    ruleTag = "inbound-final";
    network = "tcp,udp";
    outboundTag = defaultVia;
  };

  # Explicit proxy exceptions beat blockRu: RU-geolocated ranges (Telegram's,
  # at times) would otherwise swallow them.
  xrayInboundRules =
    onionRule
    ++ blockPrivateRule
    ++ serverAddressRule
    ++ proxyDomainRule
    ++ proxyIpRule
    ++ blockRuRules
    ++ zapretRules
    ++ overrideRules
    ++ [ finalRule ];
  # The serverSource outbounds' own last word: only ever to this host, its listed IPs where
  # there are some, and never somewhere private.
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

  # The "direct" outbound's fence around this host, whose own addresses it reaches past the
  # firewall: only the ports above. The start script adds its interfaces' addresses.
  hostAddresses =
    proxyInboundsLoopback
    ++ lib.filter (range: range != null) [
      proxyInboundsCfg.routing.serverSource.ipv4
      proxyInboundsCfg.routing.serverSource.ipv6
    ]
    ++ serverIps;
  hostFenceRules =
    lib.optional (serverAddressPorts != [ ]) {
      action = "allow";
      ip = hostAddresses;
      port = serverPortList;
      _hostAddresses = true;
    }
    ++ [
      {
        action = "block";
        ip = hostAddresses;
        _hostAddresses = true;
      }
    ];
in
{
  inherit xrayInboundRules selfFinalRules hostFenceRules;
  # The names whose rules send a connection past its listener's via (this host, zapret's
  # sites, .onion): matched only on the address the client asked for, never a sniffed name.
  sniffDomainsExcluded = lib.unique (
    serverNameDomains
    ++ lib.optionals zapretDirectEnabled zapretDomains
    ++ lib.optional (onionListeners != [ ]) "domain:onion"
  );
  # The outbounds the IP exceptions above lead to: each dials its own addresses alone. The
  # start script puts "direct"'s fence around this host ahead of their rules.
  exceptionOutbounds =
    lib.optional (serverIps != [ ] && serverAddressPorts != [ ] && any exceptionInboundTags) {
      protocol = "freedom";
      tag = "direct-server";
      settings.finalRules = [
        {
          action = "allow";
          ip = serverIps;
          port = serverPortList;
        }
        { action = "block"; }
      ];
    }
    ++ lib.optional (zapretDirectEnabled && zapretDirectRules.ips != [ ]) {
      protocol = "freedom";
      tag = "direct-zapret";
      settings.finalRules = [
        {
          action = "allow";
          ip = zapretDirectRules.ips;
        }
        { action = "block"; }
      ];
    };
  # Names of this host sent direct with no guard (IPOnDemand, and no IP aliases): a warning.
  unguardedServerNames = lib.optionals (!serverNameGuarded) serverNames;
}
