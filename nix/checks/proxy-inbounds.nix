{
  checkLib,
  pkgs,
  evalProxySuite,
  baseModule,
  mkInboundsConfig,
  mkInboundsSpec,
}:

let
  inherit (checkLib) ok;
  inherit (pkgs) lib;

  # The users every fixture's listeners name, by what they hold.
  usersModule = {
    services.proxy-suite.inbounds.users = {
      user.uuidFile = "/run/secrets/uuid";
      ws.uuidFile = "/run/secrets/ws";
      h3.uuidFile = "/run/secrets/h3";
      hy2.passwordFile = "/run/secrets/hy2";
      ss.passwordFile = "/run/secrets/ss";
      a.passwordFile = "/run/secrets/a";
      b.passwordFile = "/run/secrets/b";
      second = { };
      phone = { };
      laptop = { };
      far.address = "10.66.1.2";
    };
  };
  evalWithUsers = modules: evalProxySuite (modules ++ [ usersModule ]);

  realityListener = {
    type = "vless";
    port = 443;
    users = [ "user" ];
    flow = "xtls-rprx-vision";
    reality = {
      enable = true;
      serverNames = [ "www.microsoft.com" ];
      privateKeyFile = "/run/secrets/reality-key";
      publicKey = "public-key";
      shortIds = [ "0123abcd" ];
    };
  };

  mkInbounds =
    inbounds:
    evalWithUsers [
      baseModule
      {
        services.proxy-suite.inbounds = {
          enable = true;
        }
        // inbounds;
      }
    ];

  relayFixture = mkInbounds { listeners.vless-in = realityListener; };
  relayConfig = mkInboundsConfig relayFixture;
  relaySpec = mkInboundsSpec relayFixture;

  exitFixture = mkInbounds {
    routing.via = "direct";
    listeners.vless-in = realityListener;
  };
  exitConfig = mkInboundsConfig exitFixture;

  mixedFixture = mkInbounds {
    listeners.relayed = realityListener;
    listeners.local-exit = realityListener // {
      port = 8443;
      via = "direct";
    };
  };
  mixedConfig = mkInboundsConfig mixedFixture;

  # A blocked listener gets neither the proxy exceptions nor serverAddress.
  blockedFixture = mkInbounds {
    serverAddress = "vpn.example.com";
    routing.proxy.domains = [ "telegram.org" ];
    listeners.open = realityListener;
    listeners.shut = realityListener // {
      port = 8443;
      via = "block";
    };
  };
  blockedConfig = mkInboundsConfig blockedFixture;

  # Two listeners, two different servers.
  pinnedFixture = evalWithUsers [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        proxy = {
          enable = true;
          backend = "sing-box";
          outbounds = [
            {
              tag = "nl-vps";
              url = "http://nl.example.com:8080";
            }
            {
              tag = "de-vps";
              url = "http://de.example.com:8080";
            }
            {
              tag = "unused";
              singBoxJson = {
                type = "tuic";
              };
            }
          ];
        };
        inbounds = {
          enable = true;
          routing.via = "nl-vps";
          listeners.through-nl = realityListener;
          listeners.through-de = realityListener // {
            port = 8443;
            via = "de-vps";
          };
        };
      };
    }
  ];
  pinnedConfig = mkInboundsConfig pinnedFixture;

  # A .ru serverAddress is exactly what blockRu would otherwise blackhole.
  namedFixture = mkInbounds {
    serverAddress = "vpn.example.ru";
    listeners.vless-in = realityListener;
  };
  namedConfig = mkInboundsConfig namedFixture;

  # The same trap in its literal-IP form.
  ipNamedFixture = mkInbounds {
    serverAddress = "82.146.44.102";
    listeners.vless-in = realityListener;
  };
  ipNamedConfig = mkInboundsConfig ipNamedFixture;

  # Other names and IPs of this host, beside the one in share links.
  aliasedFixture = mkInbounds {
    serverAddress = "vpn.example.com";
    serverAliases = [
      "turn.example.com"
      "domain:example.net"
      "203.0.113.10"
      "2001:db8::10"
      "vpn.example.com"
    ];
    serverPorts = [
      993
      "7882-7885"
      443
    ];
    listeners.vless-in = realityListener;
  };
  aliasedConfig = mkInboundsConfig aliasedFixture;

  # Connections to this host from each user's own address: an order is the user's number,
  # and users without one follow the highest, by name.
  selfSourceInbounds = {
    serverAddress = "vpn.example.com";
    serverAliases = [
      "203.0.113.10"
      "2001:db8::10"
    ];
    routing.serverSource = {
      ipv4 = "10.78.0.0/24";
      ipv6 = "fd78:78:78::/64";
    };
    users = {
      # One user, two secrets: each listener takes its protocol's.
      bob = {
        order = 1;
        uuidFile = "/run/secrets/bob";
        passwordFile = "/run/secrets/bob";
      };
      alice = {
        order = 5;
        passwordFile = "/run/secrets/alice";
      };
      anon.uuidFile = "/run/secrets/anon";
    };
    listeners.vless-in = realityListener // {
      users = [
        "bob"
        "anon"
      ];
    };
    listeners.hy-in = {
      type = "hysteria2";
      port = 8443;
      users = [
        "alice"
        "bob"
      ];
      tls = {
        enable = true;
        certificateFile = "/run/secrets/cert";
        keyFile = "/run/secrets/key";
      };
    };
  };
  selfSourceFixture = mkInbounds selfSourceInbounds;
  selfSourceConfig = mkInboundsConfig selfSourceFixture;
  selfSourceService = selfSourceFixture.config.systemd.services.proxy-suite-inbounds.serviceConfig;
  badSelfSourceFixture = mkInbounds (
    lib.recursiveUpdate selfSourceInbounds { routing.serverSource.ipv4 = "10.78.0.5/24"; }
  );

  # inbounds.runtime: the rules runtime listeners join are marked, the runtime users'
  # serverSource rules have their anchors, and the rest of the system is ready for them.
  runtimeInbounds = selfSourceInbounds // {
    runtime = {
      enable = true;
      ports = [
        9443
        "20000-20010"
      ];
      vias = [ "direct" ];
    };
  };
  runtimeFixture = mkInbounds runtimeInbounds;
  runtimeConfig = mkInboundsConfig runtimeFixture;
  runtimeSpec = mkInboundsSpec runtimeFixture;
  hasFailed =
    fixture: message:
    builtins.any (a: !a.assertion && lib.hasInfix message a.message) fixture.config.assertions;
  # Only this module's: a fixture has no root file system or boot loader.
  failedMessages =
    fixture:
    builtins.filter (lib.hasPrefix "proxy-suite:") (
      map (a: a.message) (builtins.filter (a: !a.assertion) fixture.config.assertions)
    );
  # A listener meant only for runtime users, and nothing but runtime listeners.
  runtimeOnlyFixture = mkInbounds {
    serverAddress = "vpn.example.com";
    runtime = {
      enable = true;
      ports = [ "20000-20010" ];
    };
    listeners.waiting = realityListener // {
      users = [ ];
    };
  };
  runtimeClashFixture = mkInbounds (
    lib.recursiveUpdate runtimeInbounds { runtime.ports = [ "400-500" ]; }
  );
  runtimeNoPortsFixture = mkInbounds (runtimeInbounds // { runtime.enable = true; });

  unguardedFixture = mkInbounds {
    routing = {
      blockRu = false;
      blockPrivate = false;
    };
    listeners.vless-in = realityListener;
  };
  unguardedConfig = mkInboundsConfig unguardedFixture;

  firewallFixture = mkInbounds {
    listeners.vless-in = realityListener;
    listeners.ss-in = {
      type = "shadowsocks";
      port = 8388;
      users = [ "ss" ];
    };
    # Loopback-bound: the port stays closed though the link advertises the public one.
    listeners.ws-in = {
      type = "vless";
      port = 10002;
      sharePort = 443;
      address = "127.0.0.53";
      users = [ "ws" ];
      transport = {
        type = "ws";
        path = "/vpnjantit";
      };
      tls = {
        enable = true;
        certificateFile = "/run/acme/fullchain.pem";
        keyFile = "/run/acme/key.pem";
      };
    };
    # h3 only: UDP is opened, the TCP port stays free.
    listeners.h3-in = {
      type = "vless";
      port = 8443;
      users = [ "h3" ];
      transport = {
        type = "xhttp";
        path = "/h3";
      };
      tls = {
        enable = true;
        certificateFile = "/run/acme/fullchain.pem";
        keyFile = "/run/acme/key.pem";
        alpn = [ "h3" ];
      };
    };
    # hysteria2 is QUIC: UDP only.
    listeners.hy2-in = {
      type = "hysteria2";
      port = 8444;
      users = [ "hy2" ];
      tls = {
        certificateFile = "/run/acme/fullchain.pem";
        keyFile = "/run/acme/key.pem";
      };
      hysteria.masquerade = "https://www.example.com";
    };
  };
  firewallSpec = mkInboundsSpec firewallFixture;
  firewallNft = firewallFixture.config.networking.nftables.tables;

  hopFixture = mkInbounds {
    listeners.hy2-in = {
      type = "hysteria2";
      port = 443;
      users = [ "hy2" ];
      tls = {
        certificateFile = "/c";
        keyFile = "/k";
      };
      hysteria.salamander.enable = true;
      hysteria.portHopping = "20000-30000";
    };
  };
  hopSpec = lib.head (mkInboundsSpec hopFixture).listeners;
  hopTable = hopFixture.config.networking.nftables.tables.proxy-suite-hysteria-hop;
  wsListener = lib.head (builtins.filter (l: l.tag == "ws-in") firewallSpec.listeners);

  # A ws listener behind a TLS front's fallback, and a decoy web server.
  fallbackTarget = {
    type = "vless";
    port = 10002;
    address = "127.0.0.1";
    users = [ "ws" ];
    transport = {
      type = "ws";
      path = "/ws";
    };
  };
  fallbackListeners = {
    front-in = {
      type = "vless";
      port = 443;
      users = [ "user" ];
      tls = {
        enable = true;
        certificateFile = "/run/acme/fullchain.pem";
        keyFile = "/run/acme/key.pem";
      };
      fallbacks = [
        {
          path = "/ws";
          listener = "ws-in";
        }
        { dest = 8080; }
      ];
    };
    ws-in = fallbackTarget;
  };
  fallbackFixture = mkInbounds { listeners = fallbackListeners; };
  fallbackSpec = mkInboundsSpec fallbackFixture;
  fallbackSpecListener = tag: lib.head (builtins.filter (l: l.tag == tag) fallbackSpec.listeners);
  mkRejectsFallback =
    listeners:
    mkRejects (
      baseProxy
      // {
        inbounds = {
          enable = true;
          inherit listeners;
        };
      }
    );

  noFirewallFixture = mkInbounds {
    openFirewall = false;
    listeners.vless-in = realityListener;
  };

  awgListener = {
    type = "amneziawg";
    port = 51820;
    users = [
      "phone"
      "laptop"
    ];
  };
  awgFixture = mkInbounds {
    listeners.vless-in = realityListener;
    listeners.home = awgListener // {
      amneziaWg = {
        mode = "lan";
        subnet6 = "fd66:66::/64";
      };
    };
    listeners.roam = awgListener // {
      port = 51821;
      amneziaWg.subnet = "10.67.0.0/24";
    };
  };
  awgSpec = mkInboundsSpec awgFixture;
  awgSpecListener = tag: lib.head (builtins.filter (l: l.tag == tag) awgSpec.listeners);
  awgProxyFixture = mkInbounds {
    listeners.roam = awgListener;
  };
  readInboundsStart =
    fixture: (import ./read-generated.nix).readDerivation (service fixture).serviceConfig.ExecStart;
  awgService = fixture: fixture.config.systemd.services."proxy-suite-inbounds-awg";
  awgStartScript =
    fixture: (import ./read-generated.nix).readDerivation (awgService fixture).serviceConfig.ExecStart;
  # The nft rules file is a writeText the start script names; a writeText that returns its text
  # puts the rules into the script itself, readable without import-from-derivation.
  awgRules =
    fixture:
    let
      cfg = fixture.config.services.proxy-suite;
      nftr = import ../../modules/proxy-suite/nftables.nix { inherit lib pkgs cfg; };
      module = import ../../modules/proxy-suite/amnezia-wg-inbounds.nix {
        inherit lib cfg;
        pkgs = pkgs // {
          writeText = _: text: text;
        };
        derived = import ../../modules/proxy-suite/derived.nix { inherit lib cfg; };
        proxyInboundsSpecFile = "/spec.json";
        inherit (nftr) reservedIpBlock;
        ip = "ip";
        nft = "nft";
      };
    in
    (import ./read-generated.nix).readDerivation
      module.services.proxy-suite.internal.services."proxy-suite-inbounds-awg".serviceConfig.ExecStart;

  ruleTags = config: map (rule: rule.ruleTag) config.routing.rules;
  ruleByTag =
    config: tag: builtins.head (builtins.filter (rule: rule.ruleTag == tag) config.routing.rules);
  outboundTags = config: map (ob: ob.tag) config.outbounds;
  hasOutbound = config: tag: builtins.elem tag (outboundTags config);

  service = fixture: fixture.config.systemd.services."proxy-suite-inbounds";

  # `proxy-ctl inbounds stats` reads the collected file, so userControl members need it.
  statsScript =
    fixture:
    (import ./read-generated.nix).readDerivation
      fixture.config.systemd.services."proxy-suite-inbound-stats".serviceConfig.ExecStart;
  controlFixture = evalWithUsers [
    baseModule
    {
      services.proxy-suite = {
        inbounds.enable = true;
        inbounds.listeners.vless-in = realityListener;
        userControl.enable = true;
      };
    }
  ];

  # Checked against config.assertions directly: cheaper than toplevel, and names the
  # assertion.
  baseProxy = {
    enable = true;
    proxy.enable = true;
    proxy.backend = "sing-box";
    proxy.outbounds = [
      {
        tag = "primary";
        url = "http://proxy.example.com:8080";
      }
    ];
  };

  mkRejects =
    proxySuiteConfig: fragment:
    let
      fixture = evalWithUsers [
        {
          system.stateVersion = "26.05";
          services.proxy-suite = proxySuiteConfig;
        }
      ];
      failed = builtins.filter (a: !a.assertion) fixture.config.assertions;
    in
    if lib.any (a: lib.hasInfix fragment a.message) failed then
      true
    else
      throw "proxy-inbounds check: expected an assertion matching '${fragment}', got: ${
        builtins.toJSON (map (a: a.message) failed)
      }";

  mkRejectsListener =
    listener:
    mkRejects (
      baseProxy
      // {
        inbounds = {
          enable = true;
          listeners.bad = listener;
        };
      }
    );

  ssUsers = [
    "a"
    "b"
  ];

  failing = [
    (mkRejectsListener (
      realityListener
      // {
        transport.type = "xhttp";
        fallbacks = [ { dest = 8080; } ];
      }
    ) "fallbacks run only on a vless or trojan listener")
    (mkRejectsListener (
      realityListener // { fallbacks = [ { } ]; }
    ) "fallbacks each need exactly one of dest or listener")
    (mkRejectsFallback (
      fallbackListeners
      // {
        ws-in = fallbackTarget // {
          address = "::";
        };
      }
    ) "fallback listener 'ws-in' must be another vless listener")
    (mkRejectsFallback (
      fallbackListeners
      // {
        ws-in = fallbackTarget // {
          tls.enable = true;
        };
      }
    ) "fallback listener 'ws-in' must be another vless listener")
    (mkRejectsFallback (
      fallbackListeners
      // {
        front-in = fallbackListeners.front-in // {
          fallbacks = [ { listener = "missing"; } ];
        };
      }
    ) "fallback listener 'missing' must be another vless listener")
    (mkRejectsFallback (
      fallbackListeners
      // {
        front-in = fallbackListeners.front-in // {
          fallbacks = [
            {
              path = "/other";
              listener = "ws-in";
            }
          ];
        };
      }
    ) "fallback path matches only a ws or httpupgrade listener 'ws-in'")
    (mkRejectsFallback (
      fallbackListeners
      // {
        front-in = fallbackListeners.front-in // {
          fallbacks = [ { listener = "ws-in"; } ];
          reality.enable = true;
        };
        ws-in = fallbackTarget // {
          transport.type = "ws";
        };
      }
    ) "a REALITY listener's fallback listener 'ws-in' must use the xhttp or grpc transport")
    (mkRejectsFallback (
      fallbackListeners
      // {
        second-in = realityListener // {
          port = 8443;
          fallbacks = [ { listener = "ws-in"; } ];
        };
      }
    ) "can be the fallback listener of only one other")
    (mkRejectsListener (
      realityListener // { port = 18533; }
    ) "collides with a port proxy-suite uses internally")
    # An order is an address: two users cannot share one.
    (mkRejects (
      baseProxy
      // {
        inbounds = {
          enable = true;
          users.a.order = 3;
          users.b.order = 3;
          listeners.bad = realityListener;
        };
      }
    ) "inbounds.users must each have a distinct order")
    # Every user is checked, not only the first.
    (mkRejectsListener (
      realityListener // { users = realityListener.users ++ [ "second" ]; }
    ) "users each need exactly one of uuid or uuidFile")
    (mkRejectsListener {
      type = "shadowsocks";
      users = ssUsers;
    } "needs exactly one of serverPassword or serverPasswordFile")
    (mkRejectsListener {
      type = "trojan";
      users = [
        "a"
        "a"
      ];
      tls = {
        certificateFile = "/c";
        keyFile = "/k";
      };
    } "users must each have a distinct name")
    (mkRejectsListener {
      type = "shadowsocks";
      method = "2022-blake3-chacha20-poly1305";
      serverPasswordFile = "/run/secrets/server";
      users = ssUsers;
    } "needs a 2022-blake3-aes-* method")
    (mkRejectsListener (
      realityListener
      // {
        flow = null;
        transport.type = "ws";
      }
    ) "reality only runs over the raw, xhttp and grpc transports")
    (mkRejectsListener {
      xrayJson = {
        protocol = "dokodemo-door";
        port = 8080;
      };
    } "xrayJson.port and port differ")
    (mkRejectsListener (
      realityListener
      // {
        type = "vmess";
        flow = null;
      }
    ) "share links carry reality only for vless and trojan")

    (mkRejects (
      baseProxy
      // {
        inbounds = {
          enable = true;
          listeners.bad = {
            type = "vless";
            xrayJson.protocol = "vless";
          };
        };
      }
    ) "set exactly one of type, xrayJson, or jsonFile")

    (mkRejects (
      baseProxy
      // {
        inbounds = {
          enable = true;
          listeners.a = realityListener;
          listeners.b = realityListener;
        };
      }
    ) "must each use a distinct port")

    (mkRejects {
      enable = true;
      proxy.enable = false;
      inbounds = {
        enable = true;
        routing.via = "proxy";
        listeners.vless-in = realityListener;
      };
    } "requires proxy.enable = true")

    (mkRejects (
      baseProxy
      // {
        inbounds = {
          enable = true;
          listeners.vless-in = realityListener // {
            reality = realityListener.reality // {
              publicKey = null;
            };
          };
        };
      }
    ) "reality.publicKey is required")

    (mkRejects (
      baseProxy
      // {
        inbounds = {
          enable = true;
          listeners.tls-in = {
            type = "vless";
            port = 8443;
            users = [ "user" ];
            tls.enable = true;
          };
        };
      }
    ) "needs both tls.certificateFile and tls.keyFile")

    (mkRejects (
      baseProxy
      // {
        inbounds = {
          enable = true;
          listeners.ws-in = realityListener // {
            transport.type = "ws";
          };
        };
      }
    ) "flow is only valid on a vless listener")

    (mkRejects (
      baseProxy
      // {
        inbounds = {
          enable = true;
          listeners.hy2-in = {
            type = "hysteria2";
            port = 8444;
            users = [ "hy2" ];
            transport.type = "ws";
            tls = {
              certificateFile = "/c";
              keyFile = "/k";
            };
          };
        };
      }
    ) "hysteria2 takes no reality or transport")

    (mkRejects (
      baseProxy
      // {
        inbounds = {
          enable = true;
          listeners.hy2-in = {
            type = "hysteria2";
            port = 8444;
            users = [ "hy2" ];
          };
        };
      }
    ) "needs both tls.certificateFile and tls.keyFile")

    # A PROXY header opens a TCP stream; QUIC has none to open.
    (mkRejects (
      baseProxy
      // {
        inbounds = {
          enable = true;
          listeners.hy2-in = {
            type = "hysteria2";
            port = 8444;
            users = [ "hy2" ];
            acceptProxyProtocol = true;
            tls = {
              certificateFile = "/c";
              keyFile = "/k";
            };
          };
        };
      }
    ) "acceptProxyProtocol is for TCP listeners")

    (mkRejects (
      baseProxy
      // {
        inbounds = {
          enable = true;
          listeners.vless-in = realityListener // {
            hysteria.salamander.enable = true;
          };
        };
      }
    ) "hysteria.salamander and hysteria.portHopping are for hysteria2 listeners only")

    (mkRejects (
      baseProxy
      // {
        inbounds = {
          enable = true;
          listeners.hy2-in = {
            type = "hysteria2";
            port = 443;
            users = [ "hy2" ];
            hysteria.portHopping = "30000-20000";
            tls = {
              certificateFile = "/c";
              keyFile = "/k";
            };
          };
        };
      }
    ) "hysteria.portHopping must be a range")

    (mkRejects (
      baseProxy
      // {
        inbounds = {
          enable = true;
          routing.via = "no-such-outbound";
          listeners.vless-in = realityListener;
        };
      }
    ) "are not defined in proxy.outbounds")

    (mkRejects {
      enable = true;
      proxy.enable = true;
      proxy.backend = "sing-box";
      proxy.outbounds = [
        {
          tag = "sb-only";
          singBoxJson.type = "tuic";
        }
      ];
      inbounds = {
        enable = true;
        routing.via = "sb-only";
        listeners.vless-in = realityListener;
      };
    } "targets a sing-box-only outbound")

    (mkRejects (
      baseProxy // { inbounds.enable = true; }
    ) "requires at least one entry in inbounds.listeners")

    # recursiveUpdate, not //: this one nests into proxy, which baseProxy sets.
    (mkRejects (lib.recursiveUpdate baseProxy {
      proxy.listener.port = 1080;
      inbounds = {
        enable = true;
        listeners.clash = realityListener // {
          port = 1080;
        };
      };
    }) "collides with proxy.listener.port")

    # AmneziaWG listeners.
    (mkRejectsListener (awgListener // { tls.enable = true; }) "AmneziaWG takes no tls")
    # A long tag makes a long default name.
    (mkRejects (
      baseProxy
      // {
        inbounds = {
          enable = true;
          listeners.far-too-long = awgListener;
        };
      }
    ) "is longer than the kernel's 15 characters")
    (mkRejectsListener (
      awgListener
      // {
        users = [ "far" ];
      }
    ) "must be a host address inside amneziaWg.subnet")
    (mkRejects (
      baseProxy
      // {
        inbounds = {
          enable = true;
          listeners.one = awgListener;
          listeners.two = awgListener // {
            port = 51821;
          };
        };
      }
    ) "must each use a subnet of their own")
  ];

  assertions = [
    # Listeners are rendered at start time; only the stats API's is fixed.
    (ok (map (ib: ib.tag) relayConfig.inbounds == [ "api-in" ]))

    # AsIs when relayed through sing-box; IPOnDemand when XRay dials (see the template).
    (ok (relayConfig.routing.domainStrategy == "AsIs"))
    (ok (exitConfig.routing.domainStrategy == "IPOnDemand"))

    (ok (hasOutbound relayConfig "proxy"))
    (ok ((ruleByTag relayConfig "inbound-final").outboundTag == "proxy"))
    (
      assert
        (builtins.head (builtins.filter (ob: ob.tag == "proxy") relayConfig.outbounds)).protocol == "socks";
      true
    )
    (
      assert
        (builtins.head (builtins.filter (ob: ob.tag == "proxy") relayConfig.outbounds)).settings.servers
        == [
          {
            address = "127.0.0.1";
            port = 1080;
          }
        ];
      true
    )

    # A pure exit node needs no proxy outbound at all.
    (ok (!hasOutbound exitConfig "proxy"))
    (ok ((ruleByTag exitConfig "inbound-final").outboundTag == "direct"))

    # Safety rules come first.
    (ok (
      lib.take 2 (ruleTags relayConfig) == [
        "inbound-stats-api"
        "inbound-block-private"
      ]
    ))
    (ok ((ruleByTag relayConfig "inbound-block-private").outboundTag == "block"))
    (ok ((ruleByTag relayConfig "inbound-block-ru-domain").domain == [ "geosite:category-ru" ]))
    (ok ((ruleByTag relayConfig "inbound-block-ru-ip").ip == [ "geoip:ru" ]))
    (ok (!builtins.elem "inbound-block-private" (ruleTags unguardedConfig)))
    # serverAddress is exempt after blockPrivate, before the country blocks. Sniffing is
    # routeOnly, so a connection to another IP naming this host in its handshake would match
    # the name: the guard before it sends those the listener's way.
    (
      assert
        lib.take 5 (ruleTags namedConfig) == [
          "inbound-stats-api"
          "inbound-block-private"
          "inbound-server-address-sniffed-proxy"
          "inbound-server-address-direct"
          "inbound-block-ru-domain"
        ];
      true
    )
    (
      let
        guard = ruleByTag aliasedConfig "inbound-server-address-sniffed-proxy";
        tags = ruleTags aliasedConfig;
        at = tag: lib.lists.findFirstIndex (t: t == tag) null tags;
      in
      assert
        guard.ip == [
          "0.0.0.0/0"
          "::/0"
        ];
      assert guard.outboundTag == "proxy";
      assert guard.domain == (ruleByTag aliasedConfig "inbound-server-address-direct").domain;
      assert guard.port == (ruleByTag aliasedConfig "inbound-server-address-direct").port;
      # This host's IPs first: a client that resolved the name itself still gets here.
      assert at "inbound-server-address-direct-ip" < at "inbound-server-address-sniffed-proxy";
      assert at "inbound-server-address-sniffed-proxy" < at "inbound-server-address-direct";
      true
    )
    (ok ((ruleByTag namedConfig "inbound-server-address-direct").domain == [ "full:vpn.example.ru" ]))
    # Names that resolve private are refused where XRay dials them itself. This host's own
    # addresses only on its public ports: "direct" dials them over lo, past the firewall.
    # The start script adds the interfaces' addresses to the marked rules. XRay's own resolvers
    # stay reachable on their port, should one be on this host.
    (
      let
        hostAddresses = [
          "127.0.0.0/8"
          "::1/128"
          "0.0.0.0/32"
          "::/128"
        ];
      in
      assert
        (lib.findFirst (ob: ob.tag == "direct") null relayConfig.outbounds).settings.finalRules == [
          {
            action = "block";
            ip = [ "geoip:private" ];
          }
          {
            action = "allow";
            ip = [ "1.1.1.1" ];
            port = "53";
          }
          {
            action = "allow";
            ip = hostAddresses;
            port = "443";
            _hostAddresses = true;
          }
          {
            action = "block";
            ip = hostAddresses;
            _hostAddresses = true;
          }
        ];
      true
    )
    # blockPrivate = false opens the LAN, not the rest of this host.
    (
      let
        rules = (lib.findFirst (ob: ob.tag == "direct") null unguardedConfig.outbounds).settings.finalRules;
      in
      assert
        map (rule: rule.action) rules == [
          "block"
          "allow"
          "allow"
          "block"
          "allow"
        ];
      # Nor cloud metadata.
      assert builtins.elem "169.254.169.254" (builtins.elemAt rules 0).ip;
      assert (builtins.elemAt rules 1).ip == [ "1.1.1.1" ];
      assert (builtins.elemAt rules 2) ? _hostAddresses && (builtins.elemAt rules 2).port == "443";
      assert (builtins.elemAt rules 3) ? _hostAddresses && !((builtins.elemAt rules 3) ? port);
      assert lib.last rules == { action = "allow"; };
      true
    )
    # The serverSource ranges and the IPs of serverAddress and serverAliases are this host's
    # too; the fence takes the share ports the routing rules do.
    (
      let
        fence =
          builtins.elemAt
            (lib.findFirst (ob: ob.tag == "direct") null selfSourceConfig.outbounds).settings.finalRules
            2;
      in
      assert
        lib.drop 4 fence.ip == [
          "10.78.0.0/24"
          "fd78:78:78::/64"
          "203.0.113.10"
          "2001:db8::10"
        ];
      assert fence.port == (ruleByTag selfSourceConfig "inbound-server-address-direct-ip").port;
      true
    )
    (
      let
        startScript = readInboundsStart relayFixture;
      in
      assert lib.hasInfix "addr show | " startScript;
      assert lib.hasInfix "--argjson host_addresses \"$HOST_ADDRESSES\"" startScript;
      assert lib.hasInfix "select(._hostAddresses)" startScript;
      true
    )
    # Only the listener ports, not every service on this host.
    (ok ((ruleByTag namedConfig "inbound-server-address-direct").port == "443"))
    (ok ((ruleByTag blockedConfig "inbound-proxy-domain").inboundTag == [ "open" ]))
    (ok ((ruleByTag blockedConfig "inbound-server-address-direct").inboundTag == [ "open" ]))
    # No address to exempt when it is detected at runtime instead.
    (ok (!builtins.elem "inbound-server-address-direct" (ruleTags relayConfig)))
    (ok ((ruleByTag ipNamedConfig "inbound-server-address-direct-ip").ip == [ "82.146.44.102" ]))
    (ok (!builtins.elem "inbound-server-address-direct" (ruleTags ipNamedConfig)))
    (ok (!builtins.elem "inbound-server-address-direct-ip" (ruleTags namedConfig)))
    # Aliases join serverAddress, names and IPs apart, as XRay ANDs one rule's fields.
    (
      assert
        (ruleByTag aliasedConfig "inbound-server-address-direct").domain == [
          "full:vpn.example.com"
          "full:turn.example.com"
          "domain:example.net"
        ];
      true
    )
    (
      assert
        (ruleByTag aliasedConfig "inbound-server-address-direct-ip").ip == [
          "203.0.113.10"
          "2001:db8::10"
        ];
      true
    )
    # serverPorts join the listener's, ranges as they are.
    # inbounds.routing.serverSource: bob 1 and alice 5 by their orders, anon after them (6);
    # each family its outbound.
    (
      let
        out = tag: builtins.head (builtins.filter (ob: ob.tag == tag) selfSourceConfig.outbounds);
        tags = ruleTags selfSourceConfig;
        at = tag: lib.lists.findFirstIndex (t: t == tag) null tags;
        startScript = (import ./read-generated.nix).readDerivation selfSourceService.ExecStart;
      in
      assert (out "direct-self4-1").sendThrough == "10.78.0.1";
      assert (out "direct-self6-5").sendThrough == "fd78:78:78::5";
      assert (out "direct-self4-6").sendThrough == "10.78.0.6";
      assert (out "direct-self4-1").settings.domainStrategy == "UseIPv4";
      # Only ever this host.
      assert
        (out "direct-self4-1").settings.finalRules == [
          {
            action = "allow";
            ip = [
              "203.0.113.10"
              "2001:db8::10"
            ];
          }
          { action = "block"; }
        ];
      assert (ruleByTag selfSourceConfig "inbound-server-address-self-ip4-1").user == [ "bob" ];
      assert (ruleByTag selfSourceConfig "inbound-server-address-self-ip4-5").user == [ "alice" ];
      assert (ruleByTag selfSourceConfig "inbound-server-address-self-ip4-5").ip == [ "203.0.113.10" ];
      assert
        (ruleByTag selfSourceConfig "inbound-server-address-self-ip6-5").outboundTag == "direct-self6-5";
      assert (ruleByTag selfSourceConfig "inbound-server-address-self-6").user == [ "anon" ];
      assert
        (ruleByTag selfSourceConfig "inbound-server-address-self-6").domain == [ "full:vpn.example.com" ];
      # Users' own rules before the host's, and the names behind the sniffing guard.
      assert at "inbound-server-address-self-ip4-1" < at "inbound-server-address-direct-ip";
      assert at "inbound-server-address-sniffed-proxy" < at "inbound-server-address-self-1";
      assert at "inbound-server-address-self-1" < at "inbound-server-address-direct";
      assert lib.hasInfix "link add ps-self type dummy" startScript;
      assert lib.hasInfix "addr add 10.78.0.5/32 dev ps-self" startScript;
      assert lib.hasInfix "-6 addr add fd78:78:78::6/128 dev ps-self nodad" startScript;
      assert selfSourceService ? ExecStopPost;
      assert !(relayFixture.config.systemd.services.proxy-suite-inbounds.serviceConfig ? ExecStopPost);
      assert builtins.any (
        a: !a.assertion && lib.hasInfix "serverSource.ipv4 must be a network address" a.message
      ) badSelfSourceFixture.config.assertions;
      true
    )
    # The declared users are in the spec without inbounds.runtime too, for `inbounds users`.
    (
      let
        spec = mkInboundsSpec selfSourceFixture;
      in
      assert spec.runtime == null;
      assert
        builtins.attrNames spec.users == [
          "a"
          "alice"
          "anon"
          "b"
          "bob"
          "far"
          "h3"
          "hy2"
          "laptop"
          "phone"
          "second"
          "ss"
          "user"
          "ws"
        ];
      assert
        (builtins.head spec.serverSource.declared) == {
          name = "bob";
          number = 1;
        };
      true
    )
    # Without inbounds.runtime nothing is marked for it.
    (ok (!builtins.any (rule: rule ? _members || rule ? _anchor) selfSourceConfig.routing.rules))
    (
      let
        rules = runtimeConfig.routing.rules;
        anchors = builtins.filter (rule: rule ? _anchor) rules;
        tags = ruleTags runtimeConfig;
        at = tag: lib.lists.findFirstIndex (t: t == tag) null tags;
        anchorAt = name: lib.lists.findFirstIndex (rule: (rule._anchor or null) == name) null rules;
        startScript = (import ./read-generated.nix).readDerivation (service runtimeFixture)
          .serviceConfig.ExecStart;
        fw = runtimeFixture.config.networking.firewall;
      in
      assert
        map (rule: rule._anchor) anchors == [
          "selfIp"
          "selfName"
        ];
      # Each after the declared users' own, before the host's.
      assert anchorAt "selfIp" > at "inbound-server-address-self-ip4-6";
      assert anchorAt "selfIp" < at "inbound-server-address-direct-ip";
      assert anchorAt "selfName" > at "inbound-server-address-self-6";
      assert anchorAt "selfName" < at "inbound-server-address-direct";
      assert (builtins.head anchors).ip4 == [ "203.0.113.10" ];
      assert (builtins.head anchors).port == "8443,443,9443,20000-20010";
      assert
        (ruleByTag runtimeConfig "inbound-server-address-direct")._members == { notVia = [ "block" ]; };
      # A guard for every exit a runtime listener may take, even with nobody on it yet.
      assert (ruleByTag runtimeConfig "inbound-server-address-sniffed-direct").inboundTag == [ ];
      assert
        (ruleByTag runtimeConfig "inbound-server-address-sniffed-direct")._members == {
          via = [ "direct" ];
        };
      assert !builtins.elem "inbound-server-address-sniffed-block" tags;
      assert
        runtimeSpec.runtime.vias == [
          "proxy"
          "direct"
          "block"
        ];
      assert
        runtimeSpec.serverSource.declared == [
          {
            name = "bob";
            number = 1;
          }
          {
            name = "alice";
            number = 5;
          }
          {
            name = "anon";
            number = 6;
          }
        ];
      assert runtimeSpec.runtime.spool == "/var/lib/proxy-suite/inbounds.d";
      assert !(runtimeSpec.runtime.listenerDefaults ? users);
      assert runtimeSpec.runtime.listenerDefaults.port == 443;
      assert
        runtimeSpec.runtime.selfFinalRules
        == (builtins.head (builtins.filter (ob: ob.tag == "direct-self4-1") runtimeConfig.outbounds))
        .settings.finalRules;
      assert builtins.elem 9443 fw.allowedTCPPorts && builtins.elem 9443 fw.allowedUDPPorts;
      assert
        fw.allowedTCPPortRanges == [
          {
            from = 20000;
            to = 20010;
          }
        ];
      assert lib.hasInfix "--template" startScript;
      assert runtimeFixture.config.systemd.services ? proxy-suite-inbounds-reload;
      assert builtins.elem "d /var/lib/proxy-suite/inbounds.d 0700 root root -"
        runtimeFixture.config.systemd.tmpfiles.rules;
      assert !(selfSourceFixture.config.systemd.services ? proxy-suite-inbounds-reload);
      true
    )
    (ok (failedMessages runtimeOnlyFixture == [ ]))
    (ok (
      hasFailed runtimeClashFixture "inbounds.runtime.ports cover a port a declared listener or proxy-suite itself uses (443)"
    ))
    (ok (hasFailed runtimeNoPortsFixture "inbounds.runtime.enable needs inbounds.runtime.ports"))
    (ok ((ruleByTag aliasedConfig "inbound-server-address-direct").port == "443,993,7882-7885"))
    (ok ((ruleByTag aliasedConfig "inbound-server-address-direct-ip").port == "443,993,7882-7885"))
    # One allowed UDP packet would carry its whole session direct (XRay routes it once): an
    # address goes to an outbound dialing those alone, a name over TCP alone.
    (ok ((ruleByTag aliasedConfig "inbound-server-address-direct-ip").outboundTag == "direct-server"))
    (ok ((ruleByTag aliasedConfig "inbound-server-address-direct").network == "tcp"))
    (ok (
      (lib.findFirst (ob: ob.tag == "direct-server") null aliasedConfig.outbounds).settings.finalRules
      == [
        {
          action = "allow";
          ip = (ruleByTag aliasedConfig "inbound-server-address-direct-ip").ip;
          port = "443,993,7882-7885";
        }
        { action = "block"; }
      ]
    ))
    (ok (!builtins.elem "inbound-block-ru-domain" (ruleTags unguardedConfig)))

    # A per-listener via becomes its own rule; listeners on the default do not.
    (ok (builtins.elem "inbound-via-local-exit" (ruleTags mixedConfig)))
    (ok (!builtins.elem "inbound-via-relayed" (ruleTags mixedConfig)))
    (ok ((ruleByTag mixedConfig "inbound-via-local-exit").inboundTag == [ "local-exit" ]))
    (ok ((ruleByTag mixedConfig "inbound-via-local-exit").outboundTag == "direct"))

    # The pinned listener gets its own rule; the default one rides the final rule.
    (ok ((ruleByTag pinnedConfig "inbound-via-through-de").outboundTag == "de-vps"))
    (ok ((ruleByTag pinnedConfig "inbound-final").outboundTag == "nl-vps"))
    # Pinned outbounds are injected at start and need no local proxy.
    (ok (!hasOutbound pinnedConfig "proxy"))
    (
      assert
        outboundTags pinnedConfig == [
          "direct"
          "block"
        ];
      true
    )
    # Only referenced outbounds are rendered, so the sing-box-only one is fine.
    (
      assert
        map (ob: ob.tag) pinnedFixture.config.services.proxy-suite.proxy.outbounds == [
          "nl-vps"
          "de-vps"
          "unused"
        ];
      true
    )

    # The final rule always comes last.
    (ok (lib.last (ruleTags relayConfig) == "inbound-final"))
    (ok (lib.last (ruleTags mixedConfig) == "inbound-final"))

    # Without zapret running there is nothing to route around it.
    (ok (!builtins.elem "inbound-zapret-direct-domain" (ruleTags relayConfig)))

    # The spec carries secret paths, never their contents.
    (ok (builtins.length relaySpec.listeners == 1))
    (ok ((builtins.head relaySpec.listeners).tag == "vless-in"))
    (ok ((builtins.head relaySpec.listeners).listen == "::"))
    (ok ((builtins.head (builtins.head relaySpec.listeners).users).uuidFile == "/run/secrets/uuid"))
    (ok ((builtins.head relaySpec.listeners).reality.privateKeyFile == "/run/secrets/reality-key"))
    (ok (relaySpec.shareLinks))

    # Firewall: TCP for every listener, UDP only where the protocol uses it.
    (
      assert
        lib.sort lib.lessThan firewallFixture.config.networking.firewall.allowedTCPPorts == [
          443
          8388
        ];
      true
    )
    (
      assert
        lib.sort lib.lessThan firewallFixture.config.networking.firewall.allowedUDPPorts == [
          8388
          8443
          8444
        ];
      true
    )
    (ok (wsListener.port == 10002 && wsListener.sharePort == 443))
    # hysteria2 port hopping: the range is redirected to the listener's port, which alone
    # stays open; nothing is installed without it.
    (ok (
      hopTable.family == "inet"
      && lib.hasInfix "udp dport 20000-30000 redirect to :443" hopTable.content
      && lib.hasInfix "type nat hook prerouting" hopTable.content
    ))
    (ok (!(firewallNft ? proxy-suite-hysteria-hop)))
    (ok (hopSpec.hysteria.salamander.enable && hopSpec.hysteria.portHopping == "20000-30000"))
    (ok (lib.hasSuffix "/inbounds/hy2-in/salamander-password" hopSpec.salamanderStateFile))
    # Lowest order first, then tags alphabetically: links and subscriptions follow the spec.
    (ok (
      map (l: l.tag)
        (mkInboundsSpec (mkInbounds {
          listeners = {
            a-in = realityListener // {
              port = 8441;
            };
            b-in = realityListener // {
              port = 8442;
              order = 0;
            };
            c-in = realityListener // {
              port = 8443;
            };
          };
        })).listeners == [
        "b-in"
        "a-in"
        "c-in"
      ]
    ))
    # Off unless asked for, and handed to the script with REALITY's xver.
    (ok (!wsListener.acceptProxyProtocol))
    (ok (
      let
        spec =
          lib.head
            (mkInboundsSpec (mkInbounds {
              listeners.vless-in = lib.recursiveUpdate realityListener {
                address = "127.0.0.1";
                acceptProxyProtocol = true;
                reality.xver = 2;
              };
            })).listeners;
      in
      spec.acceptProxyProtocol && spec.reality.xver == 2
    ))
    # A fallback to a listener is resolved to its address, in PROXY protocol; a dest is kept as is.
    (ok (
      (fallbackSpecListener "front-in").fallbacks == [
        {
          name = null;
          alpn = null;
          path = "/ws";
          dest = "127.0.0.1:10002";
          xver = 2;
        }
        {
          name = null;
          alpn = null;
          path = null;
          dest = 8080;
          xver = 0;
        }
      ]
    ))
    (ok ((fallbackSpecListener "ws-in").front.tag == "front-in"))
    (ok ((fallbackSpecListener "ws-in").front.tls.enable))
    (ok ((fallbackSpecListener "front-in").front == null))
    (ok (
      !lib.any (a: !a.assertion && lib.hasInfix "fallback" a.message) fallbackFixture.config.assertions
    ))
    (ok (
      (lib.head (builtins.filter (l: l.tag == "hy2-in") firewallSpec.listeners)).hysteria.masquerade
      == "https://www.example.com"
    ))
    (ok (noFirewallFixture.config.networking.firewall.allowedTCPPorts == [ ]))

    # The unit exists, and only waits on the client stack when it relays.
    (ok ((service relayFixture).wantedBy == [ "multi-user.target" ]))
    (ok (builtins.elem "proxy-suite-socks.service" (service relayFixture).after))
    (ok (!builtins.elem "proxy-suite-socks.service" (service exitFixture).after))
    # Not `requires`: direct-routed listeners keep serving if the client is down.
    (ok ((service relayFixture).requires == [ ]))
    # A stop collects what XRay counted since the last timer run.
    (
      assert
        (service relayFixture).serviceConfig.ExecStop
        == relayFixture.config.systemd.services."proxy-suite-inbound-stats".serviceConfig.ExecStart;
      true
    )

    # The collected stats are group-readable with userControl, root-only without.
    (
      assert lib.hasInfix "chgrp proxy-suite \"$tmp\"" (statsScript controlFixture);
      assert lib.hasInfix "chmod 640 \"$tmp\"" (statsScript controlFixture);
      assert !lib.hasInfix "chgrp" (statsScript relayFixture);
      assert lib.hasInfix "chmod 600 \"$tmp\"" (statsScript relayFixture);
      # Who is online goes in it too: the API, which can reset the counters, is root's.
      assert lib.hasInfix ".online = (\\$online.users // [])" (statsScript controlFixture);
      true
    )
    (
      let
        startScript = readInboundsStart controlFixture;
      in
      assert lib.hasSuffix ",0600" (builtins.head relayConfig.inbounds).listen;
      assert lib.hasInfix "install -d -m 0700 -o proxy-suite-daemon -g proxy-suite-daemon \"$API_DIR\""
        startScript;
      assert !lib.hasInfix "setfacl" startScript;
      true
    )

    # AmneziaWG: the spec carries each listener's loopback inbound, in listener order.
    (ok ((awgSpecListener "home").amneziaWg.internalPort == 18700))
    (ok ((awgSpecListener "roam").amneziaWg.internalPort == 18701))
    (ok ((awgSpecListener "home").amneziaWg.internalListen == "::"))
    (ok ((awgSpecListener "roam").amneziaWg.internalListen == "127.0.0.1"))
    (ok ((awgSpecListener "home").amneziaWg.fwmark == 2))
    (ok ((awgSpecListener "home").amneziaWg.interfaceName == "awgi-home"))
    (
      assert
        (awgSpecListener "roam").amneziaWg.stateFile == "/var/lib/proxy-suite/awg-inbounds/roam/state.json";
      true
    )
    (ok (!((awgSpecListener "vless-in") ? amneziaWg)))
    # UDP only, and the interfaces past the host firewall.
    (ok (awgFixture.config.networking.firewall.allowedTCPPorts == [ 443 ]))
    (
      assert
        lib.sort lib.lessThan awgFixture.config.networking.firewall.allowedUDPPorts == [
          51820
          51821
        ];
      true
    )
    (
      assert builtins.elem "awgi-home" awgFixture.config.networking.firewall.trustedInterfaces;
      assert builtins.elem "awgi-roam" awgFixture.config.networking.firewall.trustedInterfaces;
      true
    )
    (ok (
      lib.hasInfix ''iifname "awgi-home" accept'' awgFixture.config.networking.firewall.extraReversePathFilterRules
    ))
    # The interfaces come up before XRay renders their links.
    (ok (builtins.elem "proxy-suite-inbounds-awg.service" (service awgFixture).after))
    (ok (builtins.elem "proxy-suite-inbounds-awg.service" (service awgFixture).wants))
    (ok (!(relayFixture.config.systemd.services ? "proxy-suite-inbounds-awg")))
    (
      # Scoped to the listener's interface, so src_valid_mark cannot make clients martians.
      assert lib.hasInfix "rule add pref 8990 iif awgi-home fwmark 20 table 103" (
        awgStartScript awgFixture
      );
      assert !(lib.hasInfix "rule add pref 8990 fwmark 20" (awgStartScript awgFixture));
      assert lib.hasInfix "awg_inbound.py prepare" (awgStartScript awgFixture);
      true
    )
    # IPv6 routing only where a listener has IPv6.
    (ok (lib.hasInfix "-6 rule add pref 8990" (awgStartScript awgFixture)))
    (ok (!lib.hasInfix "-6 rule add pref 8990" (awgStartScript awgProxyFixture)))
    # Transparent sockets only where there is something to divert.
    (
      assert lib.hasInfix "net_admin" (readInboundsStart awgFixture);
      assert !lib.hasInfix "net_admin" (readInboundsStart relayFixture);
      true
    )
    # Forwarding only for "lan" listeners.
    (ok (awgFixture.config.boot.kernel.sysctl."net.ipv4.ip_forward" == 1))
    (ok (awgFixture.config.boot.kernel.sysctl."net.ipv6.conf.all.forwarding" == 1))
    (ok (!(awgProxyFixture.config.services.proxy-suite.internal.sysctl ? "net.ipv4.ip_forward")))
    # "lan" clients reach private networks and each other natively, "proxy" clients nothing but via.
    (
      let
        rules = awgRules awgFixture;
      in
      assert lib.hasInfix "ip daddr $RESERVED_IP return" rules;
      assert lib.hasInfix "ip daddr 192.168.0.0/16 return" rules;
      assert lib.hasInfix "ip daddr 192.168.0.0/16 drop" rules;
      assert lib.hasInfix "ip daddr 10.67.0.0/24 drop" rules;
      assert lib.hasInfix "ip6 daddr fd66:66::/64 return" rules;
      assert lib.hasInfix "tproxy ip to 127.0.0.1:18700 meta mark set 20 accept" rules;
      assert lib.hasInfix "tproxy ip6 to [::1]:18700 meta mark set 20 accept" rules;
      assert !lib.hasInfix "tproxy ip6 to [::1]:18701" rules;
      assert lib.hasInfix ''iifname "awgi-roam" jump listener_1'' rules;
      assert lib.hasInfix "th dport { 18700, 18701 } fib daddr type local drop" rules;
      assert lib.hasInfix ''ip saddr 10.66.0.0/24 oifname != "awgi-home" masquerade'' rules;
      assert !lib.hasInfix "10.67.0.0/24 oifname" rules;
      true
    )
    (ok (!lib.hasInfix "masquerade" (awgRules awgProxyFixture)))

  ]
  ++ failing;
in
{
  inherit assertions;
}
