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
in
{
  inherit
    tproxyFile
    tunFile
    perAppTunFile
    routeModeRulesFile
    ;
}
