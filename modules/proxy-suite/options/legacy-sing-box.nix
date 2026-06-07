{ lib, config, ... }:

let
  inherit (lib) mkIf mkOption types;
  cfg = config.services.proxy-suite;
  legacy = cfg.singBox or { };
  legacyUsed = legacy != { };

  has = name: builtins.hasAttr name legacy;
  hasNested = path: lib.hasAttrByPath path legacy;
  getNested = path: lib.getAttrFromPath path legacy;
  setIf = condition: value: lib.optionalAttrs condition value;
in
{
  options.services.proxy-suite.singBox = mkOption {
    type = types.submodule {
      freeformType = types.anything;
    };
    default = { };
    visible = false;
    description = ''
      Deprecated compatibility tree for the old services.proxy-suite.singBox
      options. Use services.proxy-suite.proxy instead.
    '';
  };

  config = mkIf legacyUsed {
    warnings = [
      ''
        services.proxy-suite.singBox is deprecated. Move shared options to
        services.proxy-suite.proxy and SingBox-specific options to
        services.proxy-suite.proxy.singBox.
      ''
    ];

    services.proxy-suite.proxy = lib.mkMerge [
      (setIf (!has "enable") {
        enable = lib.mkDefault true;
        singBox.enable = lib.mkDefault true;
      })
      (setIf (has "enable") {
        enable = lib.mkDefault legacy.enable;
        singBox.enable = lib.mkDefault legacy.enable;
      })
      (setIf (has "listenAddress") { listenAddress = lib.mkDefault legacy.listenAddress; })
      (setIf (has "port") { port = lib.mkDefault legacy.port; })
      (setIf (has "auth") { auth = lib.mkDefault legacy.auth; })
      (setIf (has "proxyByDefault") { proxyByDefault = lib.mkDefault legacy.proxyByDefault; })
      (setIf (has "outbounds") { outbounds = lib.mkDefault legacy.outbounds; })
      (setIf (has "subscriptions") { subscriptions = lib.mkDefault legacy.subscriptions; })
      (setIf (has "subscriptionUpdateInterval") {
        subscriptionUpdateInterval = lib.mkDefault legacy.subscriptionUpdateInterval;
      })
      (setIf (has "selection") { selection = lib.mkDefault legacy.selection; })
      (setIf (has "dns") { dns = lib.mkDefault legacy.dns; })
      (setIf (has "routing") { routing = lib.mkDefault legacy.routing; })
      (setIf (has "tun") { tun = lib.mkDefault legacy.tun; })
      (setIf (has "tproxy") { tproxy = lib.mkDefault legacy.tproxy; })
      (setIf (hasNested [ "urlTest" "url" ]) {
        urlTest.url = lib.mkDefault (getNested [ "urlTest" "url" ]);
      })
      (setIf (hasNested [ "urlTest" "interval" ]) {
        urlTest.interval = lib.mkDefault (getNested [ "urlTest" "interval" ]);
      })
      (setIf (hasNested [ "urlTest" "tolerance" ]) {
        singBox.urlTest.tolerance = lib.mkDefault (getNested [ "urlTest" "tolerance" ]);
      })
      (setIf (has "package") { singBox.package = lib.mkDefault legacy.package; })
      (setIf (has "clashApiPort") { singBox.clashApiPort = lib.mkDefault legacy.clashApiPort; })
    ];
  };
}
