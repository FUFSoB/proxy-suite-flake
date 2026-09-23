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

  realityListener = {
    type = "vless";
    port = 443;
    users = [ { uuidFile = "/run/secrets/uuid"; } ];
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
    evalProxySuite [
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
  pinnedFixture = evalProxySuite [
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
      users = [ { passwordFile = "/run/secrets/ss"; } ];
    };
    # Loopback-bound: the port stays closed though the link advertises the public one.
    listeners.ws-in = {
      type = "vless";
      port = 10002;
      sharePort = 443;
      address = "127.0.0.53";
      users = [ { uuidFile = "/run/secrets/ws"; } ];
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
      users = [ { uuidFile = "/run/secrets/h3"; } ];
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
      users = [ { passwordFile = "/run/secrets/hy2"; } ];
      tls = {
        certificateFile = "/run/acme/fullchain.pem";
        keyFile = "/run/acme/key.pem";
      };
      hysteria.masquerade = "https://www.example.com";
    };
  };
  firewallSpec = mkInboundsSpec firewallFixture;
  wsListener = lib.head (builtins.filter (l: l.tag == "ws-in") firewallSpec.listeners);

  noFirewallFixture = mkInbounds {
    openFirewall = false;
    listeners.vless-in = realityListener;
  };

  awgListener = {
    type = "amneziawg";
    port = 51820;
    users = [
      { name = "phone"; }
      { name = "laptop"; }
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
  controlFixture = evalProxySuite [
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
      fixture = evalProxySuite [
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
    {
      name = "a";
      passwordFile = "/run/secrets/a";
    }
    {
      name = "b";
      passwordFile = "/run/secrets/b";
    }
  ];

  failing = [
    (mkRejectsListener (
      realityListener // { port = 18533; }
    ) "collides with a port proxy-suite uses internally")
    # Every user is checked, not only the first.
    (mkRejectsListener (
      realityListener // { users = realityListener.users ++ [ { name = "second"; } ]; }
    ) "users each need exactly one of uuid or uuidFile")
    (mkRejectsListener {
      type = "shadowsocks";
      users = ssUsers;
    } "needs exactly one of serverPassword or serverPasswordFile")
    (mkRejectsListener {
      type = "trojan";
      users = map (u: u // { name = "same"; }) ssUsers;
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
            users = [ { uuidFile = "/run/secrets/uuid"; } ];
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
            users = [ { passwordFile = "/run/secrets/hy2"; } ];
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
            users = [ { passwordFile = "/run/secrets/hy2"; } ];
          };
        };
      }
    ) "needs both tls.certificateFile and tls.keyFile")

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
    (mkRejectsListener (awgListener // { users = [ { } ]; }) "users each need a name")
    (mkRejectsListener (
      awgListener
      // {
        users = [
          {
            name = "a";
            address = "10.66.1.2";
          }
        ];
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
    # serverAddress is exempt after blockPrivate, before the country blocks.
    (
      assert
        lib.take 4 (ruleTags namedConfig) == [
          "inbound-stats-api"
          "inbound-block-private"
          "inbound-server-address-direct"
          "inbound-block-ru-domain"
        ];
      true
    )
    (ok ((ruleByTag namedConfig "inbound-server-address-direct").domain == [ "full:vpn.example.ru" ]))
    # Names that resolve private are refused where XRay dials them itself.
    (
      assert
        (lib.findFirst (ob: ob.tag == "direct") null relayConfig.outbounds).settings.finalRules == [
          {
            action = "block";
            ip = [ "geoip:private" ];
          }
        ];
      true
    )
    # Only the listener ports, not every service on this host.
    (ok ((ruleByTag namedConfig "inbound-server-address-direct").port == "443"))
    (ok ((ruleByTag blockedConfig "inbound-proxy-domain").inboundTag == [ "open" ]))
    (ok ((ruleByTag blockedConfig "inbound-server-address-direct").inboundTag == [ "open" ]))
    # No address to exempt when it is detected at runtime instead.
    (ok (!builtins.elem "inbound-server-address-direct" (ruleTags relayConfig)))
    (ok ((ruleByTag ipNamedConfig "inbound-server-address-direct").ip == [ "82.146.44.102" ]))
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
      assert lib.hasInfix "rule add pref 8990 fwmark 20 table 103" (awgStartScript awgFixture);
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
