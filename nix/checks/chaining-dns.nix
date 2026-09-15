{
  pkgs,
  evalProxySuite,
  baseModule,
  mkTunConfig,
  mkTProxyConfig,
  mkBadProxySuiteFixture,
  mkFailingAssertions,
}:

let
  generated = import ./read-generated.nix;
  startScript =
    fixture: generated.readDerivation fixture.config.systemd.services."proxy-suite-socks".serviceConfig.ExecStart;

  chained = evalProxySuite [
    baseModule
    {
      services.proxy-suite.proxy = {
        outbounds = [
          {
            tag = "exit";
            url = "http://exit.example.com:8080";
            detour = "primary";
          }
        ];
        subscriptions = [
          {
            tag = "sub";
            url = "https://example.com/sub";
            detour = "primary";
          }
        ];
      };
    }
  ];

  dnsModule = {
    services.proxy-suite.proxy = {
      tun.enable = true;
      dns = {
        strategy = "ipv4_only";
        fakeIp.enable = true;
        singBox = {
          servers = [
            {
              tag = "corp";
              type = "udp";
              server = "10.0.0.53";
            }
          ];
          rules = [
            {
              domain_suffix = [ "corp.example" ];
              server = "corp";
            }
          ];
        };
      };
    };
  };
  dnsFixture = evalProxySuite [
    baseModule
    dnsModule
  ];
  tunDns = (mkTunConfig dnsFixture).dns;
  tproxyDns = (mkTProxyConfig dnsFixture).dns;
in
{
  assertions = [
    # Detours are resolved at start, once subscription entries exist; without any, nothing is added.
    (
      assert pkgs.lib.hasInfix ''{"outbounds":{"exit":"primary"},"subscriptions":{"sub":"primary"}}'' (startScript chained);
      assert pkgs.lib.hasInfix "proxy-suite-outbound-detours" (startScript chained);
      assert !(pkgs.lib.hasInfix "outbound chaining" (startScript (evalProxySuite [ baseModule ])));
      true
    )

    # User rules first, fake IP last and only for what comes through the TUN.
    (
      assert builtins.head tunDns.rules == { domain_suffix = [ "corp.example" ]; server = "corp"; };
      assert pkgs.lib.last tunDns.rules == {
        inbound = [ "tun-in" ];
        query_type = [ "A" "AAAA" ];
        server = "fakeip";
      };
      assert builtins.any (s: s.tag == "fakeip") tunDns.servers;
      assert builtins.any (s: s.tag == "corp") tunDns.servers;
      assert tunDns.strategy == "ipv4_only";
      true
    )
    # TProxy has no TUN to hand fake addresses to.
    (
      assert !(builtins.any (s: s.tag == "fakeip") tproxyDns.servers);
      assert builtins.head tproxyDns.rules == { domain_suffix = [ "corp.example" ]; server = "corp"; };
      true
    )
  ]
  ++ mkFailingAssertions mkBadProxySuiteFixture [
    # An outbound cannot chain through itself...
    {
      enable = true;
      proxy = {
        enable = true;
        outbounds = [
          {
            tag = "loop";
            url = "http://proxy.example.com:8080";
            detour = "loop";
          }
        ];
      };
    }
    # ...nor through the selector it belongs to.
    {
      enable = true;
      proxy = {
        enable = true;
        subscriptions = [
          {
            tag = "sub";
            url = "https://example.com/sub";
            detour = "proxy";
          }
        ];
      };
    }
    # The sing-box DNS options need sing-box.
    {
      enable = true;
      proxy = {
        enable = true;
        backend = "xray";
        outbounds = [
          {
            tag = "primary";
            url = "http://proxy.example.com:8080";
          }
        ];
        dns.fakeIp.enable = true;
      };
    }
  ];
}
