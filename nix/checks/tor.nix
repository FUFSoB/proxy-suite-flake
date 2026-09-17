{
  pkgs,
  evalProxySuite,
  mkBadProxySuiteFixture,
  mkFailingAssertions,
  mkRouting,
  mkTunConfig,
  mkTProxyConfig,
  mkInboundsSpec,
  mkInboundsConfig,
  mkProxyCtlDerived,
}:

let
  generated = import ./read-generated.nix;
  inherit (pkgs) lib;
  inherit (lib) hasInfix;

  listener = {
    type = "vless";
    port = 10443;
    users = [ { uuidFile = "/run/secrets/uuid"; } ];
  };

  mkFixture =
    backend: settings:
    evalProxySuite [
      {
        system.stateVersion = "26.05";
        services.proxy-suite = lib.recursiveUpdate {
          enable = true;
          tor = {
            enable = true;
            asOutbound = true;
          };
          proxy = {
            enable = true;
            inherit backend;
            tun.enable = true;
            outbounds = [
              {
                tag = "vps";
                url = "http://vps.example.com:8080";
              }
            ];
          };
        } settings;
      }
    ];
  # Only proxy-suite's: these fixtures are not bootable systems.
  failedAssertions =
    fixture:
    map (a: a.message) (
      builtins.filter (a: !a.assertion && lib.hasPrefix "proxy-suite" a.message) fixture.config.assertions
    );
  services = fixture: fixture.config.systemd.services;
  socksStartOf = fixture: generated.readDerivation (services fixture).proxy-suite-socks.serviceConfig.ExecStart;
  torStartOf = fixture: generated.readDerivation (services fixture).proxy-suite-tor.serviceConfig.ExecStart;
  dnsOut = config: (lib.head (builtins.filter (o: o.tag == "dns-out") config.outbounds)).settings.rules;

  singBox = mkFixture "sing-box" { };
  singBoxStart = socksStartOf singBox;
  singBoxTorStart = torStartOf singBox;
  singBoxTun = mkTunConfig singBox;
  singBoxModes = (mkRouting singBox).singBoxRouteModeRules;
  singBoxTorUnit = (services singBox).proxy-suite-tor;
  singBoxTProxy = mkTProxyConfig (mkFixture "sing-box" {
    proxy.tun.enable = false;
    proxy.tproxy.enable = true;
  });

  xray = mkFixture "xray" { proxy.tproxy.enable = true; };
  xrayStart = socksStartOf xray;
  xrayRouting = mkRouting xray;

  hybrid = mkFixture "hybrid" { };
  hybridStart = socksStartOf hybrid;

  controlled = mkFixture "sing-box" { userControl.enable = true; };

  relayTorStart = torStartOf (mkFixture "sing-box" { tor.clientOnly = false; });

  noOnion = mkFixture "sing-box" { tor.routeOnion = false; };
  noOnionTun = mkTunConfig noOnion;

  bridges = mkFixture "sing-box" {
    tor = {
      bridges.lines = [ "obfs4 192.0.2.1:443 0123456789ABCDEF0123456789ABCDEF01234567 cert=x iat-mode=0" ];
      bridges.file = "/run/secrets/tor-bridges";
    };
  };
  bridgesStart = torStartOf bridges;

  viaProxy = mkFixture "sing-box" {
    tor.upstream = "proxy";
    proxy.listener.auth = {
      username = "local-user";
      passwordFile = "/run/secrets/local-proxy-password";
    };
  };
  viaProxyStart = torStartOf viaProxy;
  viaProxyTor = (services viaProxy).proxy-suite-tor;

  onion = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        tor = {
          enable = true;
          onionService = {
            enable = true;
            secretKeyFile = "/run/secrets/hs_ed25519_secret_key";
          };
        };
        inbounds = {
          enable = true;
          serverAddress = "vpn.example.com";
          routing.via = "direct";
          listeners.plain = listener;
          listeners.shared = listener // {
            port = 10444;
            address = "127.0.0.1";
            sharePort = 443;
          };
        };
      };
    }
  ];
  # An exit node: its clients' .onion names still reach Tor, through the local proxy.
  exitInbounds = {
    inbounds = {
      enable = true;
      serverAddress = "vpn.example.com";
      routing.via = "direct";
      listeners.plain = listener;
      listeners.closed = listener // {
        port = 10445;
        via = "block";
      };
    };
  };
  exitNode = mkFixture "sing-box" exitInbounds;
  exitNodeConfig = mkInboundsConfig exitNode;
  exitNodeRules = exitNodeConfig.routing.rules;
  exitNodeNoOnion = mkInboundsConfig (mkFixture "sing-box" (exitInbounds // { tor.routeOnion = false; }));

  # inbounds.routing.blockPrivate's resolve guard must come after the .onion rule: resolving
  # a .onion name fails, and the connection with it. autoProxy's probe pins sit first.
  guardFilter = pkgs.writeText "proxy-suite-tor-guard-check.jq" (
    import ../../modules/proxy-suite/service/script-blocks/backend-jq-filter.nix {
      inherit lib;
      pureXrayEnabled = false;
      proxyInboundsGuardPrivate = true;
      selectionMode = "selector";
    }
  );
  guardRouteRules = pkgs.writeText "proxy-suite-tor-guard-rules.json" (
    builtins.toJSON (
      (mkRouting exitNode).singBoxRouteModeRules.common
      ++ [
        {
          domain_suffix = [ "ru" ];
          outbound = "direct";
        }
      ]
    )
  );
  guardRuntime =
    pkgs.runCommand "proxy-suite-tor-guard-check" { nativeBuildInputs = [ pkgs.jq ]; }
      ''
        echo '{"inbounds":[],"outbounds":[],"dns":{"rules":[]},"route":{"rules":[]}}' |
          jq --argjson obs '[]' --argjson auth_enabled false --arg user "" --arg password "" \
            --argjson route_enabled true --argjson route_rules "$(cat ${guardRouteRules})" \
            --arg route_final proxy --arg dns_final remote --argjson clear_dns_rules false \
            --argjson probe_inbounds '[]' --argjson autoproxy_rule_sets '[]' --argjson autoproxy_rules '[]' \
            --argjson probe_pin_rules '[{"inbound":["probe-in-0"],"outbound":"direct"}]' \
            -f ${guardFilter} > rules.json
        jq -e '
          .route.rules as $r
          | ($r | map(.domain_suffix? == ["onion"]) | index(true)) as $onion
          | ($r | map(.action? == "resolve") | index(true)) as $guard
          | ($r | map(.domain_suffix? == ["ru"]) | index(true)) as $ru
          | $onion != null and $guard > $onion and $guard < $ru
        ' rules.json
        touch $out
      '';

  onionStart = torStartOf onion;
  onionSpec = mkInboundsSpec onion;
  onionInbounds = (services onion).proxy-suite-inbounds;

  invalidAssertions = mkFailingAssertions mkBadProxySuiteFixture (
    map (case: { enable = true; } // case) [
    # Enabled but used for nothing.
    { tor.enable = true; }
    # An outbound without a backend.
    {
      tor = {
        enable = true;
        asOutbound = true;
      };
    }
    # "tor" is taken.
    {
      tor = {
        enable = true;
        asOutbound = true;
      };
      proxy = {
        enable = true;
        outbounds = [
          {
            tag = "tor";
            url = "http://proxy.example.com:8080";
          }
        ];
      };
    }
    # Snowflake ignores Socks5Proxy.
    {
      tor = {
        enable = true;
        asOutbound = true;
        upstream = "proxy";
        bridges.lines = [ "snowflake 192.0.2.3:80 2B280B23E1107BB62ABFC40DDCC8824814F80A72" ];
      };
      proxy.enable = true;
    }
    # The SOCKS port on the proxy's own.
    {
      tor = {
        enable = true;
        asOutbound = true;
        socksPort = 1080;
      };
      proxy = {
        enable = true;
        listener.port = 1080;
      };
    }
    # An onion service without inbounds, and one naming a listener that is not there.
    {
      tor = {
        enable = true;
        onionService.enable = true;
      };
    }
    {
      tor = {
        enable = true;
        onionService = {
          enable = true;
          listeners = [ "missing" ];
        };
      };
      inbounds = {
        enable = true;
        routing.via = "direct";
        listeners.plain = listener;
      };
    }
    # Two listeners on one onion port.
    {
      tor = {
        enable = true;
        onionService.enable = true;
      };
      inbounds = {
        enable = true;
        routing.via = "direct";
        listeners.a = listener // {
          sharePort = 443;
        };
        listeners.b = listener // {
          port = 10444;
          sharePort = 443;
        };
      };
    }
  ]);
in
{
  runtime = guardRuntime;

  assertions = [
    (
      assert failedAssertions exitNode == [ ];
      assert
        lib.head exitNodeRules == {
          type = "field";
          ruleTag = "inbound-tor-onion";
          domain = [ "domain:onion" ];
          inboundTag = [ "plain" ];
          outboundTag = "proxy";
        };
      assert lib.any (o: o.tag == "proxy") exitNodeConfig.outbounds;
      assert builtins.elem "proxy-suite-socks.service" (services exitNode).proxy-suite-inbounds.wants;
      assert !(lib.any (r: r.ruleTag or "" == "inbound-tor-onion") exitNodeNoOnion.routing.rules);
      assert !(lib.any (r: r.ruleTag or "" == "inbound-tor-onion") (mkInboundsConfig onion).routing.rules);
      true
    )
    (
      assert lib.all (f: failedAssertions f == [ ]) [
        singBox
        xray
        hybrid
        noOnion
        bridges
        viaProxy
        onion
      ];
      true
    )

    # Every backend dials Tor's SOCKS listener as the "tor" outbound.
    (
      assert hasInfix ''{"server":"127.0.0.1","server_port":18530,"tag":"tor","type":"socks"}'' singBoxStart;
      true
    )
    (
      assert
        hasInfix ''{"protocol":"socks","settings":{"address":"127.0.0.1","port":18530},"tag":"tor"}'' xrayStart;
      true
    )
    (
      assert hasInfix ''"tag":"tor","type":"socks"'' hybridStart;
      true
    )
    # Only rules and detours reach it: never selected, tested, or used as an autoProxy exit.
    (
      assert
        hasInfix ''(if length > 1 then ["tor"] else [] end) as $tor'' singBoxStart
        && hasInfix ''(.tag | ltrimstr("proxy-suite-ob-")) != "tor"'' singBoxStart;
      true
    )
    # Not after Tor: with upstream = "proxy" that would be a cycle.
    (
      assert
        builtins.elem "proxy-suite-tor.service" (services singBox).proxy-suite-socks.wants
        && !(builtins.elem "proxy-suite-tor.service" (services singBox).proxy-suite-socks.after)
        && builtins.elem "proxy-suite-socks.service" viaProxyTor.after;
      true
    )

    # .onion goes to Tor in every route mode, after DNS hijack and sniffing.
    (
      assert
        builtins.elemAt singBoxModes.common 2 == {
          domain_suffix = [ "onion" ];
          outbound = "tor";
        };
      true
    )
    (
      assert
        xrayRouting.xrayRouteModeRules.common == [
          {
            type = "field";
            ruleTag = "tor-onion";
            domain = [ "domain:onion" ];
            outboundTag = "tor";
          }
        ]
        && lib.head xrayRouting.xrayRoutingRules == lib.head xrayRouting.xrayRouteModeRules.common;
      true
    )
    (
      assert
        !(lib.any (r: r ? domain_suffix) (mkRouting noOnion).singBoxRouteModeRules.common)
        && !(lib.any (r: r ? domain_suffix) noOnionTun.dns.rules);
      true
    )
    # Onion names never reach a resolver: a fake address where traffic is captured, NXDOMAIN elsewhere.
    (
      assert
        lib.take 2 singBoxTun.dns.rules == [
          {
            inbound = [ "tun-in" ];
            domain_suffix = [ "onion" ];
            query_type = [
              "A"
              "AAAA"
            ];
            server = "fakeip";
          }
          {
            domain_suffix = [ "onion" ];
            action = "predefined";
            rcode = "NXDOMAIN";
          }
        ]
        && lib.any (s: s.tag == "fakeip") singBoxTun.dns.servers;
      true
    )
    (
      assert
        (lib.head singBoxTProxy.dns.rules).inbound == [
          "tproxy-in"
          "tproxy-in6"
        ]
        && lib.any (s: s.tag == "fakeip") singBoxTProxy.dns.servers;
      true
    )
    (
      assert
        lib.take 2 (dnsOut (mkTunConfig xray)) == [
          {
            action = "hijack";
            qType = "1,28";
            domain = [ "domain:onion" ];
          }
          {
            action = "return";
            rCode = 3;
            domain = [ "domain:onion" ];
          }
        ]
        && (lib.head (dnsOut (mkTProxyConfig xray))).action == "return";
      true
    )

    # Tor runs as the service user, which TUN and TProxy let through, and keeps its keys private.
    (
      assert
        singBoxTorUnit.serviceConfig.User == "proxy-suite-daemon"
        && singBoxTorUnit.serviceConfig.StateDirectory == "proxy-suite/tor"
        && singBoxTorUnit.serviceConfig.StateDirectoryMode == "0700";
      true
    )
    (
      assert
        hasInfix "SocksPort 127.0.0.1:18530" singBoxTorStart
        && hasInfix "DNSPort 0" singBoxTorStart
        && hasInfix "ClientOnly 1" singBoxTorStart
        && !(hasInfix "ClientOnly" relayTorStart)
        && hasInfix "ControlSocket unix:$RUNTIME_DIRECTORY/control/socket" singBoxTorStart
        && !(hasInfix "UseBridges" singBoxTorStart)
        && !(hasInfix "Socks5Proxy" singBoxTorStart)
        && !(hasInfix "HiddenService" singBoxTorStart);
      true
    )
    # userControl's group can use the control socket: that is `proxy-ctl tor status|newnym`.
    (
      assert
        hasInfix "proxy-suite-tor-control-dir" (toString (services controlled).proxy-suite-tor.serviceConfig.ExecStartPre)
        && !(singBoxTorUnit.serviceConfig ? ExecStartPre)
        && (mkProxyCtlDerived singBox).wrapperEnv.TOR_CONTROL_SOCKET == "/run/proxy-suite-tor/control/socket";
      true
    )
    (
      assert
        hasInfix "UseBridges 1" bridgesStart
        && hasInfix "/bin/lyrebird" bridgesStart
        && hasInfix "ClientTransportPlugin snowflake exec" bridgesStart
        && hasInfix "Bridge obfs4 192.0.2.1:443 " bridgesStart
        && hasInfix ''"$CREDENTIALS_DIRECTORY/bridges"'' bridgesStart
        && builtins.elem "bridges:/run/secrets/tor-bridges" (services bridges).proxy-suite-tor.serviceConfig.LoadCredential;
      true
    )
    # Through the local proxy, with its password read at start, never written to the store.
    (
      assert
        hasInfix "Socks5Proxy 127.0.0.1:1080" viaProxyStart
        && hasInfix ''echo "Socks5ProxyUsername "local-user'' viaProxyStart
        && hasInfix ''"$CREDENTIALS_DIRECTORY/proxy-password"'' viaProxyStart
        && builtins.elem "proxy-password:/run/secrets/local-proxy-password" viaProxyTor.serviceConfig.LoadCredential;
      true
    )

    # The onion service forwards each listener's share port to where it listens.
    (
      assert
        hasInfix "HiddenServiceDir $STATE_DIRECTORY/onion" onionStart
        && hasInfix "HiddenServicePort 10443 127.0.0.1:10443" onionStart
        && hasInfix "HiddenServicePort 443 127.0.0.1:10444" onionStart
        && hasInfix "SocksPort 0" onionStart
        && hasInfix "hs_ed25519_secret_key" onionStart;
      true
    )
    (
      assert
        lib.sort (a: b: a < b) onionSpec.onionListeners == [
          "plain"
          "shared"
        ]
        && builtins.elem "proxy-suite-tor.service" onionInbounds.after
        && builtins.elem "proxy-suite-tor.service" onionInbounds.wants;
      true
    )
    (
      assert !(onion.config.systemd.services ? proxy-suite-socks);
      true
    )
  ]
  ++ invalidAssertions;
}
