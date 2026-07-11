{
  pkgs,
  xrayFixture,
  xrayTproxyConfig,
  xrayStartScript,
}:

{
  assertions = [
    # -- xray backend: same service surface, XRay config shape, and urltest balancer --
    (
      let
        socksInbound = builtins.head (
          builtins.filter (inbound: inbound.tag == "mixed-in") xrayTproxyConfig.inbounds
        );
        tproxyInbound = builtins.head (
          builtins.filter (inbound: inbound.tag == "tproxy-in") xrayTproxyConfig.inbounds
        );
        specificRule = builtins.head (
          builtins.filter (
            rule: (rule ? domain) && builtins.elem "domain:specific.example" rule.domain
          ) xrayTproxyConfig.routing.rules
        );
        balancer = builtins.head xrayTproxyConfig.routing.balancers;
      in
      assert xrayFixture.config.services.proxy-suite.proxy.xray.enable;
      assert xrayFixture.config.systemd.services ? "proxy-suite-socks";
      assert xrayFixture.config.systemd.services ? "proxy-suite-tproxy";
      assert xrayFixture.config.systemd.services ? "proxy-suite-tun";
      assert xrayFixture.config.systemd.services ? "proxy-suite-per-app-tun";
      assert pkgs.lib.hasInfix "/bin/xray run -c" xrayStartScript;
      assert pkgs.lib.hasInfix "--backend xray" xrayStartScript;
      assert socksInbound.protocol == "socks";
      assert socksInbound.settings.auth == "noauth";
      assert socksInbound.settings.udp == true;
      assert tproxyInbound.protocol == "tunnel";
      assert tproxyInbound.settings.followRedirect == true;
      assert tproxyInbound.streamSettings.sockopt.tproxy == "tproxy";
      assert specificRule.outboundTag == "proxy-suite-ob-primary";
      assert specificRule.ruleTag == "custom-proxy-domain";
      assert balancer.tag == "proxy";
      assert balancer.selector == [ "proxy-suite-ob-" ];
      assert balancer.strategy.type == "leastPing";
      assert xrayTproxyConfig.observatory.subjectSelector == [ "proxy-suite-ob-" ];
      assert xrayTproxyConfig.observatory.probeUrl == "https://www.gstatic.com/generate_204";
      true
    )
  ];
}
