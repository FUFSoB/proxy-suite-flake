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
      # A route mode keeps mixed-in's onion rule ahead of the guard whose lookup it spares.
      assert pkgs.lib.hasInfix ''. == "inbounds-tor-onion" or . == "inbounds-private-guard"''
        xrayBackendJqFilter;
      assert pkgs.lib.hasInfix "dns-upstream-direct" xrayBackendJqFilter;
      assert pkgs.lib.hasInfix "dns-upstream-remote" xrayBackendJqFilter;
      assert pkgs.lib.hasInfix "xray_pin_server_names" xrayBackendJqFilter;
      assert pkgs.lib.hasInfix "xray_dns_server_order" xrayBackendJqFilter;
      assert pkgs.lib.hasInfix "dns-hijack" xrayBackendJqFilter;
      assert pkgs.lib.hasInfix "del(.routing.balancers)" xrayBackendJqFilter;
      assert pkgs.lib.hasInfix "del(.observatory)" xrayBackendJqFilter;
      assert pkgs.lib.hasInfix "xray_rewrite_proxy_rule" xrayBackendJqFilter;
      true
    )
  ];
}
