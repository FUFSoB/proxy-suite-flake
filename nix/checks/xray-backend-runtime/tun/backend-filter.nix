{
  pkgs,
  xrayStartBackendJqFilterFile,
  xrayTunBackendJqFilterFile,
  xrayPerAppTunBackendJqFilterFile,
  xrayStartScript,
  xrayBackendJqFilter,
}:

{
  assertions = [
    # -- xray backend: shared backend jq filter --
    (
      assert xrayStartBackendJqFilterFile == xrayTunBackendJqFilterFile;
      assert xrayTunBackendJqFilterFile == xrayPerAppTunBackendJqFilterFile;
      assert pkgs.lib.hasInfix "BACKEND_JQ_FILTER=" xrayStartScript;
      assert pkgs.lib.hasInfix ''-f "$BACKEND_JQ_FILTER"'' xrayStartScript;
      assert pkgs.lib.hasInfix
        ''select(.protocol == "socks" and .tag == "mixed-in") | .settings.accounts''
        xrayBackendJqFilter;
      assert
        !(pkgs.lib.hasInfix ''select(.protocol == "socks" and .tag == "mixed-in") | .settings.users'' xrayBackendJqFilter);
      assert pkgs.lib.hasInfix "xray_preserved_rules" xrayBackendJqFilter;
      assert pkgs.lib.hasInfix "dns-upstream-direct" xrayBackendJqFilter;
      assert pkgs.lib.hasInfix "xray_tun_dns_addresses" xrayBackendJqFilter;
      assert pkgs.lib.hasInfix "dns-hijack" xrayBackendJqFilter;
      assert pkgs.lib.hasInfix ".streamSettings.sockopt.interface = $interface" xrayBackendJqFilter;
      assert pkgs.lib.hasInfix "del(.routing.balancers)" xrayBackendJqFilter;
      assert pkgs.lib.hasInfix "del(.observatory)" xrayBackendJqFilter;
      assert pkgs.lib.hasInfix "xray_rewrite_proxy_rule" xrayBackendJqFilter;
      assert pkgs.lib.hasInfix ".protocol == \"dns\"" xrayBackendJqFilter;
      true
    )
  ];
}
