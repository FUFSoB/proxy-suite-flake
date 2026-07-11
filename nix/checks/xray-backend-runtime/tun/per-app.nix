{
  pkgs,
  checkConstants,
  xrayPerAppTunConfig,
  xrayPerAppTunStartScript,
  xrayPerAppTunUpScript,
  xrayPerAppTunCleanupScript,
}:

{
  assertions = [
    # -- xray backend: per-app TUN runtime config/scripts --
    (
      let
        perAppTunInbound = builtins.head (
          builtins.filter (inbound: inbound.tag == "tun-in") xrayPerAppTunConfig.inbounds
        );
        perAppTunDirectOutbound = builtins.head (
          builtins.filter (outbound: outbound.tag == "direct") xrayPerAppTunConfig.outbounds
        );
      in
      assert perAppTunInbound.settings.name == "psperapptun0";
      assert
        perAppTunInbound.settings.gateway == [
          "172.20.0.1/30"
          checkConstants.xrayPerAppTunIPv6Address
        ];
      assert builtins.length perAppTunInbound.settings.dns == 2;
      assert perAppTunInbound.sniffing.destOverride == [ "fakedns" ];
      assert perAppTunInbound.sniffing.metadataOnly == true;
      assert xrayPerAppTunConfig.routing.domainStrategy == "IPIfNonMatch";
      assert (builtins.head xrayPerAppTunConfig.dns.servers).address == "fakedns";
      assert xrayPerAppTunConfig.dns.tag == "dns-in";
      assert builtins.length xrayPerAppTunConfig.fakedns == 2;
      assert perAppTunDirectOutbound.streamSettings.sockopt.mark == 2;
      assert pkgs.lib.hasInfix "XRAY_SINGLE_PROXY_TAG=" xrayPerAppTunStartScript;
      assert pkgs.lib.hasInfix "ip -4 route get 1.1.1.1" xrayPerAppTunStartScript;
      assert pkgs.lib.hasInfix "ip -4 route get 1.1.1.1 mark 2" xrayPerAppTunStartScript;
      assert pkgs.lib.hasInfix "BACKEND_JQ_FILTER=" xrayPerAppTunStartScript;
      assert pkgs.lib.hasInfix ''-f "$BACKEND_JQ_FILTER"'' xrayPerAppTunStartScript;
      assert pkgs.lib.hasInfix "--routing-mark 2" xrayPerAppTunStartScript;
      assert pkgs.lib.hasInfix "xray_tun_dns_runtime" xrayPerAppTunStartScript;
      assert pkgs.lib.hasInfix ''tun_route_prefix="$(cidr_network "$tun_cidr")"'' xrayPerAppTunUpScript;
      assert pkgs.lib.hasInfix checkConstants.xrayPerAppTunIPv6Address xrayPerAppTunUpScript;
      assert pkgs.lib.hasInfix ''uplink_addr="$('' xrayPerAppTunUpScript;
      assert pkgs.lib.hasInfix ''addr replace "$tun_cidr" dev psperapptun0'' xrayPerAppTunUpScript;
      assert pkgs.lib.hasInfix ''-6 addr replace "$tun6_cidr" dev psperapptun0'' xrayPerAppTunUpScript;
      assert pkgs.lib.hasInfix
        ''route replace "$tun_route_prefix" dev psperapptun0 src "$tun_addr" table 101''
        xrayPerAppTunUpScript;
      assert pkgs.lib.hasInfix ''route replace default dev psperapptun0 src "$uplink_addr" table 101''
        xrayPerAppTunUpScript;
      assert pkgs.lib.hasInfix ''-6 route replace "$tun6_route_prefix" dev psperapptun0 table 101''
        xrayPerAppTunUpScript;
      assert pkgs.lib.hasInfix "-6 route replace default dev psperapptun0 table 101"
        xrayPerAppTunUpScript;
      assert pkgs.lib.hasInfix "-6 rule add fwmark 16 table 101" xrayPerAppTunUpScript;
      assert pkgs.lib.hasInfix "-4 route flush table 101" xrayPerAppTunCleanupScript;
      assert pkgs.lib.hasInfix "-6 route flush table 101" xrayPerAppTunCleanupScript;
      assert pkgs.lib.hasInfix "resolvectl flush-caches" xrayPerAppTunCleanupScript;
      true
    )
  ];
}
