{
  pkgs,
  evalProxySuite,
  mkTProxyConfig,
  mkBadProxySuiteFixture,
  mkFailingAssertions,
  dnsServerByTag,
}:

let
  fixtures = import ./xray-backend-features/fixtures.nix {
    inherit
      pkgs
      evalProxySuite
      mkTProxyConfig
      mkBadProxySuiteFixture
      mkFailingAssertions
      ;
  };
  inherit (fixtures)
    xraySubscriptionStartScript
    xrayRawStreamOutbound
    xrayDnsTcpConfig
    invalidXrayFeatureAssertions
    ;
in
{
  assertions = [
    (
      assert pkgs.lib.hasInfix ''CACHE_FILE="/var/lib/proxy-suite/subscriptions/xray/xray-sub.json"''
        xraySubscriptionStartScript;
      assert pkgs.lib.hasInfix "--backend xray" xraySubscriptionStartScript;
      true
    )

    # -- xray backend: raw stream settings and DNS encoding are preserved --
    (
      let
        localDns = dnsServerByTag xrayDnsTcpConfig "local";
      in
      assert xrayRawStreamOutbound.tag == "proxy";
      assert xrayRawStreamOutbound.streamSettings.network == "ws";
      assert xrayRawStreamOutbound.streamSettings.security == "tls";
      assert xrayRawStreamOutbound.streamSettings.tlsSettings.serverName == "cdn.example.com";
      assert xrayRawStreamOutbound.streamSettings.wsSettings.path == "/ws";
      assert xrayRawStreamOutbound.streamSettings.sockopt.tcpFastOpen == true;
      assert xrayRawStreamOutbound.streamSettings.sockopt.mark == 2;
      assert localDns.address == "tcp://9.9.9.9";
      assert localDns.port == 5353;
      assert localDns.queryStrategy == "UseIP";
      true
    )
  ]
  ++ invalidXrayFeatureAssertions;
}
