# XRay routing rules for the server-side inbound service.
#
# Deliberately separate from the client ruleset: inbound traffic belongs to
# somebody else's session, so it is not subject to routing.rules, route-mode
# overrides, or the DNS-hijack machinery the client config needs.
#
# The "proxy" outbound here is the local client stack's SOCKS listener, so
# anything the client decides (selected outbound, urltest, route-mode) applies
# to relayed traffic without being reimplemented.
{
  lib,
  proxyInboundsCfg,
  proxyInbounds,
  zapretDirectRules,
}:

let
  defaultVia = proxyInboundsCfg.via;

  # Listeners that follow the tree-wide default need no rule of their own; the
  # final rule already sends them there.
  overrideInbounds = builtins.filter (ib: ib.via != defaultVia) proxyInbounds;
  defaultInboundTags = map (ib: ib.tag) (builtins.filter (ib: ib.via == defaultVia) proxyInbounds);

  blockPrivateRule = lib.optional proxyInboundsCfg.blockPrivate {
    type = "field";
    ruleTag = "inbound-block-private";
    ip = [ "geoip:private" ];
    outboundTag = "block";
  };

  # A relay must not blackhole the address clients dial to reach it. Without
  # this, a server on a .ru domain (or a .ru IP) blocks itself under blockRu:
  # anyone connected through the host cannot open the very site the listeners
  # are hidden behind, and a blackholed connection reads as a refusal rather
  # than as a rule. Placed after blockPrivate so a NATed serverAddress cannot
  # be used to reach the LAN.
  #
  # It may be given in either form, and geoip:ru catches a literal IP just as
  # geosite catches the name. An IPv6 literal is the only form carrying a colon;
  # a bare name cannot.
  serverAddressIsIp =
    let
      addr = proxyInboundsCfg.serverAddress;
    in
    addr != null
    && (lib.hasInfix ":" addr || builtins.match "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+" addr != null);

  serverAddressRule = lib.optional (proxyInboundsCfg.serverAddress != null) (
    {
      type = "field";
      ruleTag = "inbound-server-address-direct";
      outboundTag = "direct";
    }
    // (
      if serverAddressIsIp then
        { ip = [ proxyInboundsCfg.serverAddress ]; }
      else
        { domain = [ "full:${proxyInboundsCfg.serverAddress}" ]; }
    )
  );

  blockRuRules = lib.optionals proxyInboundsCfg.blockRu [
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

  # Only meaningful when the default egress leaves through a proxy: zapret works
  # on traffic this host emits itself, so destinations it can already unblock
  # are better left direct than sent through a proxy hop. Scoped to the
  # listeners on the default egress, so an explicit per-listener `via` wins.
  zapretDirectEnabled =
    proxyInboundsCfg.zapretDirect
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

  xrayInboundRules = blockPrivateRule ++ serverAddressRule ++ blockRuRules ++ zapretRules ++ overrideRules ++ [ finalRule ];
in
{
  inherit xrayInboundRules;
}
