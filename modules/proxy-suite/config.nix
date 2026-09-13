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
    inherit (derived) proxyInboundsCfg proxyInbounds;
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
    listeners = map (ib: {
      inherit (ib) tag;
      inherit (ib.listener)
        type
        port
        sharePort
        users
        flow
        method
        transport
        tls
        reality
        xrayJson
        jsonFile
        ;
      listen = ib.listener.address;
    }) derived.proxyInbounds;
  };

  selectedTemplates = if derived.pureXrayEnabled then xrayTemplates else singBoxTemplates;
  routeModeRules =
    if derived.pureXrayEnabled then rules.xrayRouteModeRules else rules.singBoxRouteModeRules;

  tproxyFile = pkgs.writeText "proxy-suite-tproxy-template.json" (
    builtins.toJSON selectedTemplates.tproxy
  );
  tunFile = pkgs.writeText "proxy-suite-tun-template.json" (
    builtins.toJSON selectedTemplates.tun
  );
  perAppTunFile = pkgs.writeText "proxy-suite-per-app-tun-template.json" (
    builtins.toJSON selectedTemplates.perAppTun
  );
  routeModeRulesFile = pkgs.writeText "proxy-suite-route-mode-rules.json" (
    builtins.toJSON routeModeRules
  );
  proxyInboundsFile = pkgs.writeText "proxy-suite-inbounds-template.json" (
    builtins.toJSON proxyInboundsTemplate
  );
  proxyInboundsSpecFile = pkgs.writeText "proxy-suite-inbounds-spec.json" (
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
