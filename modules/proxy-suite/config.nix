# Build-time proxy backend configuration templates.
# Proxy outbounds are injected at service start time, not here.
{
  lib,
  pkgs,
  cfg,
  rules,
}:

let
  derived = import ./derived.nix { inherit lib cfg; };
  singBoxTemplates = import ./config-templates/sing-box.nix {
    inherit
      lib
      derived
      rules
      ;
  };
  xrayTemplates = import ./config-templates/xray.nix {
    inherit
      lib
      derived
      rules
      ;
  };

  inboundRules = import ./rules/proxy-inbounds.nix {
    inherit lib;
    inherit (derived)
      proxyInboundsCfg
      proxyInbounds
      proxyInboundsRouteOnion
      proxyInboundsResolveInSingBox
      proxyInboundsSelfSources
      proxyInboundsRuntimeEnabled
      proxyInboundsRuntimeVias
      proxyInboundRuntimePorts
      ;
    inherit (rules) zapretDirectRules;
  };

  proxyInboundsTemplate = import ./config-templates/proxy-inbounds.nix {
    inherit lib derived inboundRules;
    inherit (xrayTemplates) mkDnsServer;
  };

  # Fallbacks to another listener are resolved here, where every listener is known.
  inboundByTag = tag: lib.findFirst (ib: ib.tag == tag) null derived.proxyInbounds;
  fallbackFront =
    tag:
    lib.findFirst (
      ib: lib.any (fb: fb.listener == tag) ib.listener.fallbacks
    ) null derived.proxyInbounds;
  renderFallback =
    fb:
    {
      inherit (fb) name alpn path;
    }
    // (
      if fb.listener == null then
        { inherit (fb) dest xver; }
      else
        let
          target = (inboundByTag fb.listener).listener;
          host = if lib.hasInfix ":" target.address then "[${target.address}]" else target.address;
        in
        {
          dest = "${host}:${toString target.port}";
          xver = 2;
        }
    );

  # A listener with nothing set: what inbound_runtime.py fills a runtime listener's JSON in
  # with, so its defaults are the option's. Not the AmneziaWG part, which runtime listeners
  # cannot have, nor what the JSON must not set.
  listenerDefaults =
    builtins.removeAttrs
      (lib.evalModules {
        modules = [
          {
            options.listener = lib.mkOption {
              type = (import ./options/types.nix { inherit lib; }).inboundType;
              default = { };
            };
          }
        ];
      }).config.listener
      [
        "amneziaWg"
        "users"
        "xrayJson"
        "jsonFile"
      ];

  # inbounds.runtime, for inbound_runtime.py: where the spool is and what it may use.
  runtimeSpec =
    let
      rt = derived.proxyInboundsCfg.runtime;
    in
    {
      spool = derived.constants.runtimeInboundsDir;
      inherit (rt) ports fallbackDests tlsCertificates;
      vias = derived.proxyInboundsRuntimeVias;
      defaultVia = derived.proxyInboundsCfg.routing.via;
      inherit (inboundRules) selfFinalRules;
      salamanderStateDir = "${cfg.host.stateDir}/inbounds";
      inherit listenerDefaults;
    };

  # Listener specification handed to build-inbound.py at service start. Secrets
  # appear here only as paths; the script reads them at runtime.
  proxyInboundsSpec = {
    runtime = if derived.proxyInboundsRuntimeEnabled then runtimeSpec else null;
    # Every declared user, on a listener or not, and their serverSource numbers: what
    # `proxy-ctl inbounds users` lists, and what runtime users go around. Secrets as paths.
    users = derived.proxyInboundsCfg.users;
    serverSource = {
      inherit (derived.proxyInboundsCfg.routing.serverSource) ipv4 ipv6;
      declared = map (s: {
        name = s.email;
        inherit (s) number;
      }) derived.proxyInboundsSelfSources;
    };
    serverAddress = derived.proxyInboundsCfg.serverAddress;
    shareLinks = derived.proxyInboundsCfg.shareLinks;
    # Listeners the onion service carries, which get a second set of links to it.
    onionListeners = map (ib: ib.tag) derived.torOnionInbounds;
    listeners = map (
      ib:
      {
        inherit (ib) tag via;
        inherit (ib.listener)
          order
          type
          port
          sharePort
          shareAddress
          acceptProxyProtocol
          users
          flow
          method
          serverPassword
          serverPasswordFile
          transport
          tls
          reality
          hysteria
          xrayJson
          jsonFile
          ;
        listen = ib.listener.address;
        # Where a Salamander password given neither inline nor as a file is kept.
        salamanderStateFile = "${cfg.host.stateDir}/inbounds/${ib.tag}/salamander-password";
        fallbacks = map renderFallback ib.listener.fallbacks;
        # The listener in front, whose port and TLS or REALITY the share links carry.
        front =
          let
            f = fallbackFront ib.tag;
          in
          if f == null then
            null
          else
            {
              inherit (f) tag;
              inherit (f.listener)
                type
                port
                sharePort
                shareAddress
                tls
                reality
                ;
            };
      }
      # Only on AmneziaWG listeners: the defaults of the others need not type-check.
      // lib.optionalAttrs (ib.listener.type == "amneziawg") {
        amneziaWg =
          let
            runtime = lib.findFirst (awg: awg.tag == ib.tag) null derived.proxyInboundsAwg;
          in
          {
            inherit (ib.listener.amneziaWg)
              mode
              interfaceName
              subnet
              subnet6
              privateKeyFile
              obfuscation
              dns
              mtu
              persistentKeepalive
              clientAllowedIPs
              ;
            inherit (runtime) internalPort internalListen stateFile;
            fwmark = cfg.proxy.tproxy.proxyMark;
          };
      }
    ) derived.proxyInbounds;
  };

  selectedTemplates = if derived.pureXrayEnabled then xrayTemplates else singBoxTemplates;
  routeModeRules =
    if derived.pureXrayEnabled then rules.xrayRouteModeRules else rules.singBoxRouteModeRules;

  tproxyFile = pkgs.writeText "proxy-suite-core" (builtins.toJSON selectedTemplates.tproxy);
  tunFile = pkgs.writeText "proxy-suite-core" (builtins.toJSON selectedTemplates.tun);
  perAppTunFile = pkgs.writeText "proxy-suite-core" (builtins.toJSON selectedTemplates.perAppTun);
  routeModeRulesFile = pkgs.writeText "proxy-suite-core" (builtins.toJSON routeModeRules);
  proxyInboundsFile = pkgs.writeText "proxy-suite-inbounds" (builtins.toJSON proxyInboundsTemplate);
  proxyInboundsSpecFile = pkgs.writeText "proxy-suite-inbounds" (builtins.toJSON proxyInboundsSpec);
in
{
  inherit
    tproxyFile
    tunFile
    perAppTunFile
    routeModeRulesFile
    proxyInboundsFile
    proxyInboundsSpecFile
    ;
}
