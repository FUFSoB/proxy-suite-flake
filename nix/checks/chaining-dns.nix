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
    fixture:
    generated.readDerivation
      fixture.config.systemd.services."proxy-suite-socks".serviceConfig.ExecStart;

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
    # Detours are resolved at start, once subscription and runtime entries exist.
    (
      assert pkgs.lib.hasInfix ''{"outbounds":{"exit":"primary"},"subscriptions":{"sub":"primary"}}'' (
        startScript chained
      );
      assert pkgs.lib.hasInfix "proxy-suite-outbound-detours" (startScript chained);
      assert pkgs.lib.hasInfix "/var/lib/proxy-suite/outbounds.d/$RUNTIME_OB_TAG.detour" (
        startScript chained
      );
      true
    )

    # Selection leaves proxy.selectionExclude alone; the inventory says so.
    (
      let
        script = startScript (evalProxySuite [
          baseModule
          { services.proxy-suite.proxy.selectionExclude = [ "primary" ]; }
        ]);
      in
      assert pkgs.lib.hasInfix ''--argjson ex '["primary"]' '' script;
      assert pkgs.lib.hasInfix "excluded: ($tags - $selectable)" script;
      true
    )

    # An inbound pinned to a chained outbound gets the whole chain.
    (
      let
        script =
          generated.readDerivation
            (evalProxySuite [
              {
                system.stateVersion = "26.05";
                services.proxy-suite = {
                  enable = true;
                  proxy = {
                    enable = true;
                    outbounds = [
                      {
                        tag = "hop";
                        url = "http://hop.example.com:8080";
                      }
                      {
                        tag = "exit";
                        url = "http://exit.example.com:8080";
                        detour = "hop";
                      }
                    ];
                  };
                  inbounds = {
                    enable = true;
                    serverAddress = "203.0.113.1";
                    listeners.main = {
                      type = "socks";
                      port = 1081;
                      via = "exit";
                      users = [
                        {
                          name = "a";
                          password = "b";
                        }
                      ];
                    };
                  };
                };
              }
            ]).config.systemd.services."proxy-suite-inbounds".serviceConfig.ExecStart;
      in
      assert pkgs.lib.hasInfix "# via outbound: hop" script;
      assert pkgs.lib.hasInfix "--arg hop hop '.streamSettings.sockopt.dialerProxy = $hop'" script;
      true
    )

    # User rules first, fake IP last and only for what comes through the TUN.
    (
      assert
        builtins.head tunDns.rules == {
          domain_suffix = [ "corp.example" ];
          server = "corp";
        };
      assert
        pkgs.lib.last tunDns.rules == {
          inbound = [ "tun-in" ];
          query_type = [
            "A"
            "AAAA"
          ];
          server = "fakeip";
        };
      assert builtins.any (s: s.tag == "fakeip") tunDns.servers;
      assert builtins.any (s: s.tag == "corp") tunDns.servers;
      assert tunDns.strategy == "ipv4_only";
      true
    )
    # Fake addresses survive a restart, one cache per TUN config.
    (
      assert
        (mkTunConfig dnsFixture).experimental.cache_file.path == "/var/lib/proxy-suite/fakeip/tun.db";
      assert (mkTunConfig dnsFixture).experimental.cache_file.store_fakeip;
      true
    )
    # DNS follows the routing: proxied names through remote, direct ones local, in its order.
    (
      let
        routed = evalProxySuite [
          baseModule
          {
            services.proxy-suite.proxy.routing = {
              proxy = {
                domains = [ "blocked.example" ];
                geosites = [ "google" ];
              };
              rules = [
                {
                  outbound = "direct";
                  domains = [ "bank.example" ];
                }
                {
                  outbound = "block";
                  domains = [ "ads.example" ];
                }
              ];
            };
          }
        ];
        rules = map (r: {
          inherit (r) server;
          match = r.domain_suffix or r.rule_set;
        }) (mkTProxyConfig routed).dns.rules;
      in
      assert
        rules == [
          {
            server = "local";
            match = [ "bank.example" ];
          }
          {
            server = "remote";
            match = [ "blocked.example" ];
          }
          {
            server = "local";
            match = [ "geosite-category-ru" ];
          }
          {
            server = "remote";
            match = [ "geosite-google" ];
          }
        ];
      true
    )
    # TProxy has no TUN to hand fake addresses to.
    (
      assert !(builtins.any (s: s.tag == "fakeip") tproxyDns.servers);
      assert !((mkTProxyConfig dnsFixture).experimental ? cache_file);
      assert
        builtins.head tproxyDns.rules == {
          domain_suffix = [ "corp.example" ];
          server = "corp";
        };
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
    # An inbound cannot chain through what the inbound service does not run.
    {
      enable = true;
      proxy = {
        enable = true;
        outbounds = [
          {
            tag = "exit";
            url = "http://exit.example.com:8080";
            detour = "warp";
          }
        ];
      };
      inbounds = {
        enable = true;
        serverAddress = "203.0.113.1";
        listeners.main = {
          type = "socks";
          port = 1081;
          via = "exit";
          users = [
            {
              name = "a";
              password = "b";
            }
          ];
        };
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
