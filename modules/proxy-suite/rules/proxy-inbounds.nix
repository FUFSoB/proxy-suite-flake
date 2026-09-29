# XRay routing for the inbound service. Separate from the client ruleset:
# "proxy" here is the client stack's SOCKS listener, so its selection applies.
{
  lib,
  proxyInboundsCfg,
  proxyInbounds,
  proxyInboundsRouteOnion,
  proxyInboundsResolveInSingBox,
  proxyInboundsSelfSources,
  zapretDirectRules,
}:

let
  defaultVia = proxyInboundsCfg.routing.via;

  # Listeners on the default egress are covered by the final rule.
  overrideInbounds = builtins.filter (ib: ib.via != defaultVia) proxyInbounds;
  defaultInboundTags = map (ib: ib.tag) (builtins.filter (ib: ib.via == defaultVia) proxyInbounds);

  # A blocked listener stays blocked: neither serverAddress nor the proxy exceptions open it.
  exceptionInboundTags = map (ib: ib.tag) (builtins.filter (ib: ib.via != "block") proxyInbounds);

  # Only Tor reaches .onion: to the local proxy, whose own rule sends it there. First, so no
  # IP rule before it has XRay look the name up, which would leak it to a resolver.
  onionRule = lib.optional proxyInboundsRouteOnion {
    type = "field";
    ruleTag = "inbound-tor-onion";
    domain = [ "domain:onion" ];
    inboundTag = map (ib: ib.tag) (
      builtins.filter (ib: ib.via != "block" && ib.listener.type != "amneziawg") proxyInbounds
    );
    outboundTag = "proxy";
  };

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
  serverAddressPorts = lib.unique (
    map (ib: if ib.listener.sharePort != null then ib.listener.sharePort else ib.listener.port) (
      # AmneziaWG is UDP to the interface, never relayed through XRay.
      builtins.filter (ib: ib.listener.type != "amneziawg") proxyInbounds
    )
    ++ lib.optionals proxyInboundsCfg.subscriptions.enable [
      80
      443
    ]
    ++ proxyInboundsCfg.serverPorts
  );

  # Names and IPs in rules of their own: XRay ANDs the fields of one rule.
  mkServerAddressRule =
    ruleTag: field: items:
    lib.optional (items != [ ] && exceptionInboundTags != [ ]) {
      type = "field";
      inherit ruleTag;
      ${field} = items;
      inboundTag = exceptionInboundTags;
      port = serverPortList;
      outboundTag = "direct";
    };

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
  mkSniffGuard =
    ruleTag: domains: inbounds: extra:
    lib.mapAttrsToList (
      via: ibs:
      {
        type = "field";
        ruleTag = "${ruleTag}-${via}";
        domain = domains;
        ip = anyIp;
        inboundTag = map (ib: ib.tag) ibs;
        outboundTag = via;
      }
      // extra
    ) (lib.groupBy (ib: ib.via) inbounds);

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
    lib.optional (items != [ ] && exceptionInboundTags != [ ]) {
      type = "field";
      ruleTag = "${ruleTag}-${source.id}";
      ${field} = items;
      user = [ source.email ];
      inboundTag = exceptionInboundTags;
      port = serverPortList;
      inherit outboundTag;
    };
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
  serverNameGuarded = proxyInboundsResolveInSingBox || serverIps != [ ];
  serverAddressRule =
    selfIpRules
    ++ mkServerAddressRule "inbound-server-address-direct-ip" "ip" serverIps
    ++ lib.optionals (serverNames != [ ] && serverNameGuarded && exceptionInboundTags != [ ]) (
      mkSniffGuard "inbound-server-address-sniffed" serverNameDomains (builtins.filter (
        ib: ib.via != "block"
      ) proxyInbounds) { port = serverPortList; }
    )
    ++ lib.optionals (serverNames != [ ] && serverNameGuarded) selfNameRules
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
      (exceptionInboundTags != [ ] && (inboundProxy.domains != [ ] || inboundProxy.geosites != [ ]))
      {
        type = "field";
        ruleTag = "inbound-proxy-domain";
        domain =
          map (domain: "domain:${domain}") inboundProxy.domains
          ++ map (name: "geosite:${name}") inboundProxy.geosites;
        inboundTag = exceptionInboundTags;
        outboundTag = "proxy";
      };

  proxyIpRule =
    lib.optional
      (exceptionInboundTags != [ ] && (inboundProxy.ips != [ ] || inboundProxy.geoips != [ ]))
      {
        type = "field";
        ruleTag = "inbound-proxy-ip";
        ip = inboundProxy.ips ++ map (name: "geoip:${name}") inboundProxy.geoips;
        inboundTag = exceptionInboundTags;
        outboundTag = "proxy";
      };

  # Only when the default egress is a proxy, and only for its listeners.
  zapretDirectEnabled =
    proxyInboundsCfg.routing.zapretDirect
    && defaultInboundTags != [ ]
    && !builtins.elem defaultVia [
      "direct"
      "block"
    ];

  mkZapretRule =
    ruleTag: field: items:
    lib.optional (zapretDirectEnabled && items != [ ]) {
      type = "field";
      inherit ruleTag;
      ${field} = items;
      inboundTag = defaultInboundTags;
      outboundTag = "direct";
    };

  zapretDomains = map (domain: "domain:${domain}") zapretDirectRules.domains;
  # Under IPOnDemand the guard would take every zapret name too: the domain rule stays off.
  zapretRules =
    mkZapretRule "inbound-zapret-direct-ip" "ip" zapretDirectRules.ips
    ++ lib.optionals (zapretDirectEnabled && zapretDomains != [ ] && proxyInboundsResolveInSingBox) (
      mkSniffGuard "inbound-zapret-sniffed" zapretDomains (builtins.filter (
        ib: builtins.elem ib.tag defaultInboundTags
      ) proxyInbounds) { }
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
in
{
  inherit xrayInboundRules;
  # Names of this host sent direct with no guard (IPOnDemand, and no IP aliases): a warning.
  unguardedServerNames = lib.optionals (!serverNameGuarded) serverNames;
}
