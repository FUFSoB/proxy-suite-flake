{
  pkgs,
  checkConstants,
  xrayTunConfig,
  xrayTunStartScript,
  xrayTunUpScript,
}:

{
  assertions = [
    # -- xray backend: global TUN runtime config/scripts --
    (
      let
        tunInbound = builtins.head (
          builtins.filter (inbound: inbound.tag == "tun-in") xrayTunConfig.inbounds
        );
        tunDirectOutbound = builtins.head (
          builtins.filter (outbound: outbound.tag == "direct") xrayTunConfig.outbounds
        );
        tunDnsOutbound = builtins.head (
          builtins.filter (outbound: outbound.tag == "dns-out") xrayTunConfig.outbounds
        );
        tunHasFinalRuleTag = builtins.any (
          rule: (rule ? ruleTag) && rule.ruleTag == "final-default"
        ) xrayTunConfig.routing.rules;
        tunHasDirectGeositeRule = builtins.any (
          rule: (rule ? ruleTag) && rule.ruleTag == "direct-geosite"
        ) xrayTunConfig.routing.rules;
        tunHasDnsHijackRule = builtins.any (
          rule: (rule ? ruleTag) && rule.ruleTag == "dns-hijack"
        ) xrayTunConfig.routing.rules;
        tunHasDnsUpstreamRule = builtins.any (
          rule: (rule ? ruleTag) && rule.ruleTag == "dns-upstream-direct"
        ) xrayTunConfig.routing.rules;
      in
      assert tunInbound.protocol == "tun";
      assert tunInbound.settings.name == "singtun0";
      assert
        tunInbound.settings.gateway == [
          "172.19.0.1/30"
          checkConstants.xrayGlobalTunIPv6Address
        ];
      assert builtins.length tunInbound.settings.dns == 2;
      assert tunInbound.settings.autoOutboundsInterface == "auto";
      assert tunInbound.sniffing.destOverride == [ "fakedns" ];
      assert tunInbound.sniffing.metadataOnly == true;
      assert xrayTunConfig.routing.domainStrategy == "IPIfNonMatch";
      assert tunHasFinalRuleTag;
      assert tunHasDirectGeositeRule;
      assert tunHasDnsHijackRule;
      assert tunHasDnsUpstreamRule;
      assert xrayTunConfig.dns.queryStrategy == "UseIP";
      assert xrayTunConfig.dns.tag == "dns-in";
      assert (builtins.head xrayTunConfig.dns.servers).address == "fakedns";
      assert (builtins.head xrayTunConfig.dns.servers).tag == "fakedns";
      assert (builtins.elemAt xrayTunConfig.dns.servers 1).tag == "remote";
      assert (builtins.elemAt xrayTunConfig.dns.servers 2).tag == "local";
      assert builtins.length xrayTunConfig.fakedns == 2;
      assert tunDnsOutbound.protocol == "dns";
      assert
        tunDnsOutbound.settings.rules == [
          {
            action = "direct";
            qType = "2-27,29-65535";
          }
        ];
      assert tunDirectOutbound.streamSettings.sockopt.mark == 2;
      assert pkgs.lib.hasInfix "xray-loglevel" xrayTunStartScript;
      assert pkgs.lib.hasInfix "XRAY_SINGLE_PROXY_TAG=" xrayTunStartScript;
      assert pkgs.lib.hasInfix "ip -4 route get 1.1.1.1" xrayTunStartScript;
      assert pkgs.lib.hasInfix "ip -4 route get 1.1.1.1 mark 2" xrayTunStartScript;
      assert pkgs.lib.hasInfix "BACKEND_JQ_FILTER=" xrayTunStartScript;
      assert pkgs.lib.hasInfix ''-f "$BACKEND_JQ_FILTER"'' xrayTunStartScript;
      assert pkgs.lib.hasInfix "xray_tun_dns_runtime" xrayTunStartScript;
      assert pkgs.lib.hasInfix ''tun_route_prefix="$(cidr_network "$tun_cidr")"'' xrayTunUpScript;
      assert pkgs.lib.hasInfix checkConstants.xrayGlobalTunIPv6Address xrayTunUpScript;
      assert pkgs.lib.hasInfix ''uplink_addr="$('' xrayTunUpScript;
      assert pkgs.lib.hasInfix ''addr replace "$tun_cidr" dev singtun0'' xrayTunUpScript;
      assert pkgs.lib.hasInfix ''-6 addr replace "$tun6_cidr" dev singtun0'' xrayTunUpScript;
      assert pkgs.lib.hasInfix
        ''route replace "$tun_route_prefix" dev singtun0 src "$tun_addr" table ${toString checkConstants.tunAutoRouteTableIndex}''
        xrayTunUpScript;
      assert pkgs.lib.hasInfix
        ''route replace default dev singtun0 src "$uplink_addr" table ${toString checkConstants.tunAutoRouteTableIndex}''
        xrayTunUpScript;
      assert pkgs.lib.hasInfix
        ''-6 route replace "$tun6_route_prefix" dev singtun0 table ${toString checkConstants.tunAutoRouteTableIndex}''
        xrayTunUpScript;
      assert pkgs.lib.hasInfix
        "-6 route replace default dev singtun0 table ${toString checkConstants.tunAutoRouteTableIndex}"
        xrayTunUpScript;
      assert pkgs.lib.hasInfix
        "rule add pref ${toString checkConstants.xrayTunPerAppTproxyRulePriority} fwmark 17 table 102"
        xrayTunUpScript;
      assert pkgs.lib.hasInfix
        "rule add pref ${toString checkConstants.xrayTunPerAppTunRulePriority} fwmark 16 table 101"
        xrayTunUpScript;
      assert pkgs.lib.hasInfix
        "rule add pref ${toString checkConstants.tunAutoRouteRulePriority} not fwmark 2 table ${toString checkConstants.tunAutoRouteTableIndex}"
        xrayTunUpScript;
      assert pkgs.lib.hasInfix
        "-6 rule add pref ${toString checkConstants.xrayTunPerAppTunRulePriority} fwmark 16 table 101"
        xrayTunUpScript;
      assert pkgs.lib.hasInfix
        "-6 rule add pref ${toString checkConstants.tunAutoRouteRulePriority} not fwmark 2 table ${toString checkConstants.tunAutoRouteTableIndex}"
        xrayTunUpScript;
      true
    )
  ];
}
