# Assembles proxy-suite systemd services from the sub-modules.
{
  config,
  lib,
  pkgs,
  packages,
  cfg,
  tproxyFile,
  tunFile,
  perAppTunFile,
  routeModeRulesFile,
  proxyInboundsFile,
  proxyInboundsSpecFile,
  nftablesRulesFile,
  perAppTproxyRulesFile,
  perAppZapretRulesFile,
  perAppTunChainFile,
  ip,
  nft,
}:

let
  context = import ./context.nix {
    inherit
      lib
      pkgs
      packages
      cfg
      tproxyFile
      tunFile
      perAppTunFile
      routeModeRulesFile
      proxyInboundsFile
      proxyInboundsSpecFile
      perAppTunChainFile
      perAppTproxyRulesFile
      perAppZapretRulesFile
      ip
      nft
      ;
  };

  builders = import ./builders.nix { inherit lib pkgs; };
  inherit (builders) mkNamedUnits;

  inherit (context)
    derived
    polkit
    scripts
    perAppRouting
    control
    ;

  inherit (derived)
    proxyCfg
    proxyEnabled
    hybridEnabled
    pureXrayEnabled
    globalTun
    globalTproxy
    perAppRoutingTun
    perAppRoutingTproxy
    userControlCfg
    userControlEnabled
    perAppZapretEnabled
    hasSubscriptions
    sshProxyOutboundEnabled
    sshProxyUnitEnabled
    proxyInboundsEnabled
    proxyInboundsNeedLocalProxy
    proxyInboundFirewallPorts
    proxyInboundFirewallUdpPorts
    outboundTags
    effectiveOutboundTags
    subscriptionTags
    invalidRoutingTargets
    builtinTags
    ;
  constants = derived.constants;
  routingScripts = import ./routing-scripts.nix {
    inherit
      lib
      pkgs
      builders
      ip
      nft
      nftablesRulesFile
      constants
      globalTun
      globalTproxy
      perAppRoutingTun
      perAppRoutingTproxy
      ;
  };

  serviceUnits = import ./units.nix {
    inherit
      lib
      builders
      proxyCfg
      proxyEnabled
      hybridEnabled
      pureXrayEnabled
      globalTun
      globalTproxy
      perAppRoutingTun
      perAppRoutingTproxy
      perAppZapretEnabled
      hasSubscriptions
      sshProxyOutboundEnabled
      sshProxyUnitEnabled
      proxyInboundsEnabled
      proxyInboundsNeedLocalProxy
      scripts
      perAppRouting
      routingScripts
      ;
  };
  inherit (serviceUnits)
    localProxyAuthEnabled
    systemServiceEntries
    userServiceEntries
    timerEntries
    ;
in
{
  environment.systemPackages = [ control.proxyCtl ];

  # nftables must be on for transparent routing backends. Global TUN uses
  # SingBox auto_redirect programs an `inet sing-box` nftables table.
  networking.nftables.enable = lib.mkIf (
    globalTun.enable
    || globalTproxy.enable
    || perAppRoutingTun.enable
    || perAppRoutingTproxy.enable
    || perAppZapretEnabled
  ) (lib.mkDefault true);

  # Inbound listeners are reached from outside, so their ports have to be open.
  networking.firewall = lib.mkIf (proxyInboundsEnabled && cfg.proxyInbounds.openFirewall) {
    allowedTCPPorts = proxyInboundFirewallPorts;
    allowedUDPPorts = proxyInboundFirewallUdpPorts;
  };

  users.groups = lib.mkIf (cfg.enable && (userControlEnabled || localProxyAuthEnabled)) {
    "${userControlCfg.group}" = { };
  };

  security.polkit.enable = lib.mkIf (cfg.enable && userControlEnabled) true;
  security.polkit.extraConfig = lib.mkIf (cfg.enable && userControlEnabled) (
    lib.mkAfter ''
      polkit.addRule(function(action, subject) {
        if (!subject.isInGroup("${userControlCfg.group}")) {
          return null;
        }

        if (action.id !== "org.freedesktop.systemd1.manage-units") {
          return null;
        }

        var unit = action.lookup("unit");
        ${polkit.userControlPolkitRules}

        return null;
      });
    ''
  );

  systemd.user.services = mkNamedUnits userServiceEntries;

  assertions = import ../service-assertions.nix {
    inherit lib cfg derived;
    tgWsProxyCfg = cfg.tgWsProxy;
    inherit
      builtinTags
      outboundTags
      effectiveOutboundTags
      subscriptionTags
      invalidRoutingTargets
      ;
    inherit (perAppRouting)
      effectivePerAppRoutingProfileNames
      hasProxychainsProfiles
      hasTunProfiles
      hasTproxyProfiles
      hasZapretProfiles
      ;
  };

  systemd.services = mkNamedUnits systemServiceEntries;

  systemd.timers = mkNamedUnits timerEntries;
}
