{
  checkLib,
  pkgs,
  evalProxySuite,
  baseModule,
  mkProxyCtlDerived,
  mkPerAppUserRules,
  mkPerAppTunConfig,
  dnsServerByTag,
}:

let
  inherit (checkLib) ok;
  generated = import ./read-generated.nix;

  perAppRoutingTunFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite = {
        perAppRouting = {
          enable = true;
          createDefaultProfiles = true;
          tun.enable = true;
        };
      };
    }
  ];
  perAppRoutingTun = mkProxyCtlDerived perAppRoutingTunFixture;
  perAppRoutingTunScript = perAppRoutingTun.script;
  perAppRoutingTunProfiles = perAppRoutingTun.profiles;
  perAppRoutingTunServiceConfig =
    perAppRoutingTunFixture.config.systemd.services."proxy-suite-per-app-tun".serviceConfig;
  perAppRoutingTunStartScript = generated.readDerivation perAppRoutingTunServiceConfig.ExecStart;
  perAppRoutingTunUpScript = generated.readDerivation perAppRoutingTunServiceConfig.ExecStartPost;
  perAppRoutingTunCleanupScript = generated.readDerivation perAppRoutingTunServiceConfig.ExecStopPost;
  perAppRoutingTunConfig = mkPerAppTunConfig perAppRoutingTunFixture;
  perAppRoutingTunDirectOutbound = builtins.head (
    builtins.filter (item: item.tag == "direct") perAppRoutingTunConfig.outbounds
  );
  perAppRoutingTunUserStartScript = generated.readDerivation (
    (mkPerAppUserRules perAppRoutingTunFixture).perAppTunUserRuleStart
  );
  perAppRoutingTunNftRules =
    generated.readDerivation
      (import ../../modules/proxy-suite/nftables.nix {
        inherit (pkgs) lib;
        inherit pkgs;
        cfg = perAppRoutingTunFixture.config.services.proxy-suite;
      }).perAppTunChainFile;

  perAppRoutingTunWithTproxyFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite = {
        proxy.tproxy.enable = true;
        perAppRouting = {
          enable = true;
          createDefaultProfiles = true;
          tun.enable = true;
        };
      };
    }
  ];
  perAppRoutingTunWithTproxyStartScript =
    generated.readDerivation
      perAppRoutingTunWithTproxyFixture.config.systemd.services."proxy-suite-per-app-tun".serviceConfig.ExecStart;
  perAppRoutingTunWithTproxyConfig = mkPerAppTunConfig perAppRoutingTunWithTproxyFixture;
  perAppRoutingTunWithTproxyDirectOutbound = builtins.head (
    builtins.filter (item: item.tag == "direct") perAppRoutingTunWithTproxyConfig.outbounds
  );
in
{
  assertions = [
    # -- perAppRouting: createDefaultProfiles injects curated tun profile when backend is enabled --
    (
      assert builtins.length perAppRoutingTunProfiles == 2;
      assert builtins.any (
        profile: profile.name == "tun" && profile.route == "tun"
      ) perAppRoutingTunProfiles;
      true
    )

    # -- perAppRouting: generated proxy-ctl script dispatches tun profiles through systemd slices --
    (ok (pkgs.lib.hasInfix "PER_APP_ROUTING_TUN_ENABLED" perAppRoutingTunScript))

    # -- perAppRouting: user mark script installs fwmark + conntrack mark rules --
    (
      assert pkgs.lib.hasInfix "meta mark set" perAppRoutingTunUserStartScript;
      assert pkgs.lib.hasInfix "ct mark set" perAppRoutingTunUserStartScript;
      true
    )

    # -- perAppRouting: app TUN config is separate and does not auto-route globally --
    (
      let
        inbound = builtins.head (
          builtins.filter (item: item.tag == "tun-in") perAppRoutingTunConfig.inbounds
        );
      in
      assert inbound.interface_name == "psperapptun0";
      assert
        inbound.address == [
          "172.20.0.1/30"
          "fd66:20::1/64"
        ];
      assert inbound.auto_route == false;
      assert inbound.auto_redirect == false;
      assert inbound.strict_route == false;
      assert !(inbound ? iproute2_table_index);
      assert !(inbound ? iproute2_rule_index);
      true
    )

    # -- perAppRouting: app TUN local DNS keeps direct path without explicit detour --
    (
      let
        localDns = dnsServerByTag perAppRoutingTunConfig "local";
      in
      assert !(localDns ? detour);
      true
    )

    # -- perAppRouting: app TUN uses local domain resolver and avoids global auto-routing --
    (ok (perAppRoutingTunConfig.route.default_domain_resolver == "local"))

    # -- perAppRouting: app TUN does not set outbound routing marks when TProxy is disabled --
    (
      assert builtins.match ".*--routing-mark.*" perAppRoutingTunStartScript == null;
      assert !(perAppRoutingTunDirectOutbound ? routing_mark);
      true
    )

    # -- perAppRouting: app TUN applies outbound routing marks when TProxy is enabled --
    (
      let
        expectedMark = perAppRoutingTunWithTproxyFixture.config.services.proxy-suite.proxy.tproxy.proxyMark;
      in
      assert builtins.match ".*--routing-mark.*" perAppRoutingTunWithTproxyStartScript != null;
      assert perAppRoutingTunWithTproxyDirectOutbound.routing_mark == expectedMark;
      true
    )

    # -- perAppRouting: app TUN service and helper units are created --
    (
      assert perAppRoutingTunFixture.config.systemd.services ? "proxy-suite-per-app-tun";
      assert perAppRoutingTunFixture.config.systemd.services ? "proxy-suite-per-app-tun-user@";
      assert perAppRoutingTunFixture.config.systemd.user.services ? "proxy-suite-per-app-tun-anchor";
      assert perAppRoutingTunServiceConfig.ExecStartPre == perAppRoutingTunServiceConfig.ExecStopPost;
      # With proxy.ipv6, wrapped apps' IPv6 goes through the app TUN too.
      assert pkgs.lib.hasInfix ''-6 addr replace "$tun6_cidr" dev psperapptun0'' perAppRoutingTunUpScript;
      assert pkgs.lib.hasInfix "-6 route replace default dev psperapptun0 table 101"
        perAppRoutingTunUpScript;
      assert !(pkgs.lib.hasInfix "unreachable" perAppRoutingTunUpScript);
      assert pkgs.lib.hasInfix "-6 rule add fwmark 16 table 101" perAppRoutingTunUpScript;
      assert pkgs.lib.hasInfix "-6 route flush table 101" perAppRoutingTunCleanupScript;
      assert pkgs.lib.hasInfix "link del dev" perAppRoutingTunCleanupScript;
      assert pkgs.lib.hasInfix "psperapptun0" perAppRoutingTunCleanupScript;
      assert pkgs.lib.hasInfix "rule del fwmark 16 table 101" perAppRoutingTunCleanupScript;
      true
    )

    # -- perAppRouting: wrapped apps' replies to incoming connections skip the mark (and the
    # user rule appended after it), so they leave directly --
    (ok (
      pkgs.lib.hasInfix "ct direction reply return" (
        builtins.head (pkgs.lib.splitString "ct mark 16 meta mark set 16" perAppRoutingTunNftRules)
      )
    ))

    # -- perAppRouting: wrapped apps' DNS reaches the app TUN even when the resolver sits on
    # a local or reserved address, and their local IPv6 still leaves directly --
    (
      let
        beforeReserved = builtins.head (
          pkgs.lib.splitString "ip daddr $RESERVED_IP return" perAppRoutingTunNftRules
        );
      in
      assert pkgs.lib.hasInfix "meta l4proto { tcp, udp } th dport 53 goto app_mark" beforeReserved;
      assert pkgs.lib.hasInfix "ip6 daddr $RESERVED_IP6 return" perAppRoutingTunNftRules;
      assert pkgs.lib.hasInfix "goto app_mark" (
        builtins.elemAt (pkgs.lib.splitString "192.168.0.0/16 return" perAppRoutingTunNftRules) 1
      );
      # The mark rules live in the jumped-to chain, which both paths reach.
      assert pkgs.lib.hasInfix "proxy_suite_per_app_tun app_mark" perAppRoutingTunUserStartScript;
      true
    )

    # -- perAppRouting: app TUN enables nftables --
    (ok (perAppRoutingTunFixture.config.networking.nftables.enable))
  ];
}
