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
        tunDnsUpstreamRules = builtins.filter (
          rule: builtins.elem (rule.ruleTag or "") [ "dns-upstream-direct" "dns-upstream-remote" ]
        ) xrayTunConfig.routing.rules;
      in
      assert tunInbound.protocol == "tun";
      assert tunInbound.settings.name == "singtun0";
      assert
        tunInbound.settings.gateway == [
          "172.19.0.1/30"
          checkConstants.globalTunIPv6Address
        ];
      assert tunInbound.sniffing.destOverride == [ "fakedns" ];
      assert tunInbound.sniffing.metadataOnly == false;
      assert xrayTunConfig.routing.domainStrategy == "IPIfNonMatch";
      assert tunHasFinalRuleTag;
      assert tunHasDirectGeositeRule;
      assert tunHasDnsHijackRule;
      # Servers route by their own tags: local direct, remote through the proxy.
      assert map (rule: rule.inboundTag) tunDnsUpstreamRules == [ [ "local" ] [ "remote" ] ];
      assert xrayTunConfig.dns.queryStrategy == "UseIP";
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
      assert pkgs.lib.hasInfix "BACKEND_JQ_FILTER=" xrayTunStartScript;
      assert pkgs.lib.hasInfix ''-f "$BACKEND_JQ_FILTER"'' xrayTunStartScript;
      assert pkgs.lib.hasInfix "xray_tun_dns_runtime" xrayTunStartScript;
      assert pkgs.lib.hasInfix ''tun_route_prefix="$(cidr_network "$tun_cidr")"'' xrayTunUpScript;
      assert pkgs.lib.hasInfix checkConstants.globalTunIPv6Address xrayTunUpScript;
      assert pkgs.lib.hasInfix ''addr replace "$tun_cidr" dev singtun0'' xrayTunUpScript;
      assert pkgs.lib.hasInfix ''-6 addr replace "$tun6_cidr" dev singtun0'' xrayTunUpScript;
      assert pkgs.lib.hasInfix
        ''route replace "$tun_route_prefix" dev singtun0 src "$tun_addr" table ${toString checkConstants.tunAutoRouteTableIndex}''
        xrayTunUpScript;
      assert pkgs.lib.hasInfix
        "-4 route replace default dev singtun0 table ${toString checkConstants.tunAutoRouteTableIndex}"
        xrayTunUpScript;
      assert pkgs.lib.hasInfix
        ''-6 route replace "$tun6_route_prefix" dev singtun0 table ${toString checkConstants.tunAutoRouteTableIndex}''
        xrayTunUpScript;
      assert pkgs.lib.hasInfix
        "-6 route replace default dev singtun0 table ${toString checkConstants.tunAutoRouteTableIndex}"
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
      assert pkgs.lib.hasInfix
        ''"$family" rule add pref ${toString checkConstants.xrayTunMarkBypassRulePriority} fwmark 2 lookup main''
        xrayTunUpScript;
      assert pkgs.lib.hasInfix
        ''"$family" rule add pref ${toString checkConstants.xrayTunDnsRulePriority} ipproto udp dport 53 table ${toString checkConstants.tunAutoRouteTableIndex}''
        xrayTunUpScript;
      assert pkgs.lib.hasInfix
        ''"$family" rule add pref ${toString checkConstants.xrayTunMainRulePriority} lookup main suppress_prefixlength 0''
        xrayTunUpScript;
      assert pkgs.lib.hasInfix "proxy-suite-xray-tun.nft" xrayTunUpScript;
      assert pkgs.lib.hasInfix "delete table inet proxy_suite_xray_tun" xrayTunUpScript;
      # No uplink src: it would go stale when the uplink address changes.
      assert !(pkgs.lib.hasInfix "uplink_addr" xrayTunUpScript);
      # Every rule the up script adds is flushed first, v4 and v6.
      assert builtins.all (
        priority:
        pkgs.lib.hasInfix "-4 rule del pref ${toString priority}" xrayTunUpScript
        && pkgs.lib.hasInfix "-6 rule del pref ${toString priority}" xrayTunUpScript
      ) [
        checkConstants.xrayTunMarkBypassRulePriority
        checkConstants.xrayTunServiceUserRulePriority
        checkConstants.xrayTunPerAppTunRulePriority
        checkConstants.xrayTunDnsRulePriority
        checkConstants.xrayTunMainRulePriority
        checkConstants.tunAutoRouteRulePriority
      ];
      true
    )
  ];
}
