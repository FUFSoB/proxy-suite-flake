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
    inherit (derived) proxyInboundsCfg proxyInbounds proxyInboundsRouteOnion;
    inherit (rules) zapretDirectRules;
  };

  proxyInboundsTemplate = import ./config-templates/proxy-inbounds.nix {
    inherit lib derived inboundRules;
    inherit (xrayTemplates) mkDnsServer;
  };

  # Listener specification handed to build-inbound.py at service start. Secrets
  # appear here only as paths; the script reads them at runtime.
  proxyInboundsSpec = {
    serverAddress = derived.proxyInboundsCfg.serverAddress;
    shareLinks = derived.proxyInboundsCfg.shareLinks;
    # Listeners the onion service carries, which get a second set of links to it.
    onionListeners = map (ib: ib.tag) derived.torOnionInbounds;
    listeners = map (
      ib:
      {
        inherit (ib) tag;
        inherit (ib.listener)
          type
          port
          sharePort
          users
          flow
          method
          serverPassword
          serverPasswordFile
          transport
          tls
          reality
          xrayJson
          jsonFile
          ;
        listen = ib.listener.address;
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

  tproxyFile = pkgs.writeText "proxy-suite-core" (
    builtins.toJSON selectedTemplates.tproxy
  );
  tunFile = pkgs.writeText "proxy-suite-core" (
    builtins.toJSON selectedTemplates.tun
  );
  perAppTunFile = pkgs.writeText "proxy-suite-core" (
    builtins.toJSON selectedTemplates.perAppTun
  );
  routeModeRulesFile = pkgs.writeText "proxy-suite-core" (
    builtins.toJSON routeModeRules
  );
  proxyInboundsFile = pkgs.writeText "proxy-suite-inbounds" (
    builtins.toJSON proxyInboundsTemplate
  );
  proxyInboundsSpecFile = pkgs.writeText "proxy-suite-inbounds" (
    builtins.toJSON proxyInboundsSpec
  );
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
