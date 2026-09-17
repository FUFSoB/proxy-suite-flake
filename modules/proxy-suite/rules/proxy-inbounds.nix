# XRay routing for the inbound service. Separate from the client ruleset:
# "proxy" here is the client stack's SOCKS listener, so its selection applies.
{
  lib,
  proxyInboundsCfg,
  proxyInbounds,
  zapretDirectRules,
}:

let
  defaultVia = proxyInboundsCfg.routing.via;

  # Listeners on the default egress are covered by the final rule.
  overrideInbounds = builtins.filter (ib: ib.via != defaultVia) proxyInbounds;
  defaultInboundTags = map (ib: ib.tag) (builtins.filter (ib: ib.via == defaultVia) proxyInbounds);

  # A blocked listener stays blocked: neither serverAddress nor the proxy exceptions open it.
  exceptionInboundTags = map (ib: ib.tag) (builtins.filter (ib: ib.via != "block") proxyInbounds);

  blockPrivateRule = lib.optional proxyInboundsCfg.routing.blockPrivate {
    type = "field";
    ruleTag = "inbound-block-private";
    ip = [ "geoip:private" ];
    outboundTag = "block";
  };

  # The address clients dial must stay reachable even when blockRu covers it
  # (a .ru domain or IP). After blockPrivate, so it cannot open the LAN.
  serverAddressIsIp =
    let
      addr = proxyInboundsCfg.serverAddress;
    in
    addr != null
    && (lib.hasInfix ":" addr || builtins.match "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+" addr != null);

  # Only the ports clients dial there: the rest of this host (wildcard services the
  # firewall keeps from the internet) must not be reachable through it.
  serverAddressPorts = lib.unique (
    map (ib: if ib.listener.sharePort != null then ib.listener.sharePort else ib.listener.port) (
      # AmneziaWG is UDP to the interface, never relayed through XRay.
      builtins.filter (ib: ib.listener.type != "amneziawg") proxyInbounds
    )
    ++ lib.optionals proxyInboundsCfg.subscriptions.enable [
      80
      443
    ]
  );

  serverAddressRule =
    lib.optional (proxyInboundsCfg.serverAddress != null && exceptionInboundTags != [ ])
      (
        {
          type = "field";
          ruleTag = "inbound-server-address-direct";
          inboundTag = exceptionInboundTags;
          port = lib.concatMapStringsSep "," toString serverAddressPorts;
          outboundTag = "direct";
        }
        // (
          if serverAddressIsIp then
            { ip = [ proxyInboundsCfg.serverAddress ]; }
          else
            { domain = [ "full:${proxyInboundsCfg.serverAddress}" ]; }
        )
      );

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

  zapretRules =
    mkZapretRule "inbound-zapret-direct-domain" "domain" (
      map (domain: "domain:${domain}") zapretDirectRules.domains
    )
    ++ mkZapretRule "inbound-zapret-direct-ip" "ip" zapretDirectRules.ips;

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
    blockPrivateRule
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
}
