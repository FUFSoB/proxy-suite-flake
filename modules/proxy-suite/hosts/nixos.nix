# NixOS: the core's declarations become NixOS settings as they are.
{
  config,
  options,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.proxy-suite;
  internal = options.services.proxy-suite.internal;
  inherit (import ./common.nix { inherit lib; })
    forwardWith
    forward
    systemdForward
    systemUsersAndGroups
    unitsWithOwnSyslogIdentifier
    ;
in
{
  options.systemd.services = unitsWithOwnSyslogIdentifier;
  options.systemd.user.services = unitsWithOwnSyslogIdentifier;

  config = lib.mkMerge [
    {
      services.proxy-suite.host = {
        kind = "nixos";
        privileged = true;
        serviceManager = "systemd";
        inherit (config.networking) enableIPv6;
        inherit (config.boot) kernelPackages;
        firewallPackage = config.networking.firewall.package;
        openUdpPorts =
          let
            firewall = config.networking.firewall;
          in
          lib.unique (
            lib.concatMap (
              open:
              map toString open.allowedUDPPorts
              ++ map (range: "${toString range.from}-${toString range.to}") open.allowedUDPPortRanges
            ) ([ firewall ] ++ lib.attrValues firewall.interfaces)
          );
        resolvconfPackage = config.networking.resolvconf.package;
        # ntpd-rs runs as a dynamic user, which has no name until it starts.
        timeSyncUsers =
          lib.optional config.services.timesyncd.enable "systemd-timesync"
          ++ lib.optional config.services.chrony.enable "chrony"
          ++ lib.optional (config.services.ntp.enable || config.services.openntpd.enable) "ntp";
      };
      # NixOS's place for helper functions; set even while disabled, so a config can
      # refer to it unconditionally.
      lib.proxy-suite = cfg.internal.helpers;
    }

    (lib.mkIf cfg.enable (
      lib.mkMerge [
        (systemdForward internal)
        (systemUsersAndGroups cfg)
        {
          systemd.user.services = forward internal.userServices;

          security.polkit.enable = lib.mkIf cfg.internal.polkit.enable true;
          security.polkit.extraConfig = forwardWith lib.mkAfter internal.polkit.rules;
          # polkitd reads actions from the system profile's share/polkit-1/actions.
          environment.systemPackages = lib.mkIf (cfg.internal.polkit.actions != { }) [
            (pkgs.linkFarm "proxy-suite-polkit-actions" (
              lib.mapAttrsToList (name: path: {
                name = "share/polkit-1/actions/${name}";
                inherit path;
              }) cfg.internal.polkit.actions
            ))
          ];

          networking.nftables.enable = lib.mkIf cfg.internal.nftables (lib.mkDefault true);
          # proxy-suite's tables that are up, put back in the firewall's own load, whose flush would
          # otherwise drop them (constants.persistedNftDir). An empty glob is no error.
          networking.nftables.ruleset = lib.mkIf config.networking.nftables.enable (
            lib.mkAfter ''
              include "${cfg.host.runtimeDir}/proxy-suite-nft/*.nft"
            ''
          );
          # A persisted table that no longer loads (a user it names is gone, its store path
          # collected) would fail the whole load: dropped until its unit writes it again.
          systemd.services.nftables.serviceConfig = lib.mkIf config.networking.nftables.enable (
            let
              prune = pkgs.writeShellScript "proxy-suite-nft-prune" ''
                for f in ${cfg.host.runtimeDir}/proxy-suite-nft/*.nft; do
                  [ -e "$f" ] || continue
                  ${pkgs.nftables}/bin/nft -c -f "$f" > /dev/null 2>&1 || ${pkgs.coreutils}/bin/rm -f -- "$f"
                done
              '';
            in
            {
              ExecStart = lib.mkBefore [ prune ];
              ExecReload = lib.mkBefore [ prune ];
            }
          );
          networking.nftables.tables = lib.mapAttrs (_: content: {
            family = "inet";
            inherit content;
          }) cfg.internal.nftablesTables;
          networking.firewall = {
            allowedTCPPorts = forward internal.firewall.allowedTCPPorts;
            allowedUDPPorts = forward internal.firewall.allowedUDPPorts;
            allowedTCPPortRanges = forward internal.firewall.allowedTCPPortRanges;
            allowedUDPPortRanges = forward internal.firewall.allowedUDPPortRanges;
            extraReversePathFilterRules = forward internal.firewall.extraReversePathFilterRules;
            extraInputRules = forward internal.firewall.extraInputRules;
            trustedInterfaces = forward internal.firewall.trustedInterfaces;
          };

          # networkd drops foreign ip rules and unreachable routes (TProxy's and AmneziaWG's IPv6
          # refusal) in every table whenever it reconfigures a link.
          systemd.network.config.networkConfig = lib.mkIf config.systemd.network.enable {
            ManageForeignRoutingPolicyRules = lib.mkDefault false;
            ManageForeignRoutes = lib.mkDefault false;
          };

          boot.extraModulePackages = forward internal.kernelModulePackages;
          boot.kernel.sysctl = lib.mapAttrs (_: lib.mkDefault) cfg.internal.sysctl;

          assertions = [
            {
              assertion = cfg.internal.nftablesTables == { } || config.networking.nftables.enable;
              message = "proxy-suite: hysteria.portHopping needs nftables (networking.nftables.enable)";
            }
            {
              assertion =
                cfg.internal.firewall.extraInputRules == ""
                || !config.networking.firewall.enable
                || config.networking.nftables.enable;
              message = "proxy-suite: proxy.tproxy.lanInterfaces needs the nftables firewall (networking.nftables.enable); the iptables one drops the gateway clients' diverted traffic";
            }
            # The kill switch lets that user's traffic past, all of it: a login user's browser
            # and apps too, whenever no tunnel is up.
            (
              let
                user = cfg.sshProxy.serviceUser;
                declared = config.users.users.${user} or null;
              in
              {
                assertion =
                  !(cfg.sshProxy.enable && user != null && user != "proxy-suite-daemon" && declared != null)
                  || !declared.isNormalUser;
                message = "proxy-suite: sshProxy.serviceUser = \"${toString user}\" is a login user, whose traffic would all get past the kill switch; use a system user of its own (isSystemUser = true), or the default";
              }
            )
          ];
        }
      ]
    ))

    # Off by default since nixpkgs 26.11, and always there before, where the option does
    # not exist.
    (lib.optionalAttrs (options.security.polkit ? enablePkexecWrapper) {
      security.polkit.enablePkexecWrapper = lib.mkIf (
        cfg.enable && cfg.internal.polkit.pkexecWrapper
      ) true;
    })
  ];
}
