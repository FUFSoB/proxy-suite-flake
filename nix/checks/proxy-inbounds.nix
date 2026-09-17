{
  pkgs,
  evalProxySuite,
  baseModule,
  mkInboundsConfig,
  mkInboundsSpec,
}:

let
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
      realityListener // { port = 18536; }
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
    # Listeners are rendered at start time.
    (
      assert relayConfig.inbounds == [ ];
      true
    )

    # AsIs when relayed through sing-box; IPOnDemand when XRay dials (see the template).
    (
      assert relayConfig.routing.domainStrategy == "AsIs";
      true
    )
    (
      assert exitConfig.routing.domainStrategy == "IPOnDemand";
      true
    )

    (
      assert hasOutbound relayConfig "proxy";
      true
    )
    (
      assert (ruleByTag relayConfig "inbound-final").outboundTag == "proxy";
      true
    )
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
    (
      assert !hasOutbound exitConfig "proxy";
      true
    )
    (
      assert (ruleByTag exitConfig "inbound-final").outboundTag == "direct";
      true
    )

    # Safety rules come first.
    (
      assert builtins.head (ruleTags relayConfig) == "inbound-block-private";
      true
    )
    (
      assert (ruleByTag relayConfig "inbound-block-private").outboundTag == "block";
      true
    )
    (
      assert (ruleByTag relayConfig "inbound-block-ru-domain").domain == [ "geosite:category-ru" ];
      true
    )
    (
      assert (ruleByTag relayConfig "inbound-block-ru-ip").ip == [ "geoip:ru" ];
      true
    )
    (
      assert !builtins.elem "inbound-block-private" (ruleTags unguardedConfig);
      true
    )
    # serverAddress is exempt after blockPrivate, before the country blocks.
    (
      assert
        lib.take 3 (ruleTags namedConfig) == [
          "inbound-block-private"
          "inbound-server-address-direct"
          "inbound-block-ru-domain"
        ];
      true
    )
    (
      assert (ruleByTag namedConfig "inbound-server-address-direct").domain == [ "full:vpn.example.ru" ];
      true
    )
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
    (
      assert (ruleByTag namedConfig "inbound-server-address-direct").port == "443";
      true
    )
    (
      assert (ruleByTag blockedConfig "inbound-proxy-domain").inboundTag == [ "open" ];
      true
    )
    (
      assert (ruleByTag blockedConfig "inbound-server-address-direct").inboundTag == [ "open" ];
      true
    )
    # No address to exempt when it is detected at runtime instead.
    (
      assert !builtins.elem "inbound-server-address-direct" (ruleTags relayConfig);
      true
    )
    (
      assert (ruleByTag ipNamedConfig "inbound-server-address-direct").ip == [ "82.146.44.102" ];
      true
    )
    (
      assert !builtins.elem "inbound-block-ru-domain" (ruleTags unguardedConfig);
      true
    )

    # A per-listener via becomes its own rule; listeners on the default do not.
    (
      assert builtins.elem "inbound-via-local-exit" (ruleTags mixedConfig);
      true
    )
    (
      assert !builtins.elem "inbound-via-relayed" (ruleTags mixedConfig);
      true
    )
    (
      assert (ruleByTag mixedConfig "inbound-via-local-exit").inboundTag == [ "local-exit" ];
      true
    )
    (
      assert (ruleByTag mixedConfig "inbound-via-local-exit").outboundTag == "direct";
      true
    )

    # The pinned listener gets its own rule; the default one rides the final rule.
    (
      assert (ruleByTag pinnedConfig "inbound-via-through-de").outboundTag == "de-vps";
      true
    )
    (
      assert (ruleByTag pinnedConfig "inbound-final").outboundTag == "nl-vps";
      true
    )
    # Pinned outbounds are injected at start and need no local proxy.
    (
      assert !hasOutbound pinnedConfig "proxy";
      true
    )
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
    (
      assert lib.last (ruleTags relayConfig) == "inbound-final";
      true
    )
    (
      assert lib.last (ruleTags mixedConfig) == "inbound-final";
      true
    )

    # Without zapret running there is nothing to route around it.
    (
      assert !builtins.elem "inbound-zapret-direct-domain" (ruleTags relayConfig);
      true
    )

    # The spec carries secret paths, never their contents.
    (
      assert builtins.length relaySpec.listeners == 1;
      true
    )
    (
      assert (builtins.head relaySpec.listeners).tag == "vless-in";
      true
    )
    (
      assert (builtins.head relaySpec.listeners).listen == "::";
      true
    )
    (
      assert (builtins.head (builtins.head relaySpec.listeners).users).uuidFile == "/run/secrets/uuid";
      true
    )
    (
      assert (builtins.head relaySpec.listeners).reality.privateKeyFile == "/run/secrets/reality-key";
      true
    )
    (
      assert relaySpec.shareLinks;
      true
    )

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
        ];
      true
    )
    (
      assert wsListener.port == 10002 && wsListener.sharePort == 443;
      true
    )
    (
      assert noFirewallFixture.config.networking.firewall.allowedTCPPorts == [ ];
      true
    )

    # The unit exists, and only waits on the client stack when it relays.
    (
      assert (service relayFixture).wantedBy == [ "multi-user.target" ];
      true
    )
    (
      assert builtins.elem "proxy-suite-socks.service" (service relayFixture).after;
      true
    )
    (
      assert !builtins.elem "proxy-suite-socks.service" (service exitFixture).after;
      true
    )
    # Not `requires`: direct-routed listeners keep serving if the client is down.
    (
      assert (service relayFixture).requires == [ ];
      true
    )
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
    (
      assert (awgSpecListener "home").amneziaWg.internalPort == 18700;
      true
    )
    (
      assert (awgSpecListener "roam").amneziaWg.internalPort == 18701;
      true
    )
    (
      assert (awgSpecListener "home").amneziaWg.internalListen == "::";
      true
    )
    (
      assert (awgSpecListener "roam").amneziaWg.internalListen == "127.0.0.1";
      true
    )
    (
      assert (awgSpecListener "home").amneziaWg.fwmark == 2;
      true
    )
    (
      assert (awgSpecListener "home").amneziaWg.interfaceName == "awgi-home";
      true
    )
    (
      assert
        (awgSpecListener "roam").amneziaWg.stateFile == "/var/lib/proxy-suite/awg-inbounds/roam/state.json";
      true
    )
    (
      assert !((awgSpecListener "vless-in") ? amneziaWg);
      true
    )
    # UDP only, and the interfaces past the host firewall.
    (
      assert awgFixture.config.networking.firewall.allowedTCPPorts == [ 443 ];
      true
    )
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
    (
      assert lib.hasInfix ''iifname "awgi-home" accept''
        awgFixture.config.networking.firewall.extraReversePathFilterRules;
      true
    )
    # The interfaces come up before XRay renders their links.
    (
      assert builtins.elem "proxy-suite-inbounds-awg.service" (service awgFixture).after;
      true
    )
    (
      assert builtins.elem "proxy-suite-inbounds-awg.service" (service awgFixture).wants;
      true
    )
    (
      assert !(relayFixture.config.systemd.services ? "proxy-suite-inbounds-awg");
      true
    )
    (
      assert lib.hasInfix "rule add pref 8990 fwmark 20 table 103" (awgStartScript awgFixture);
      assert lib.hasInfix "awg_inbound.py prepare" (awgStartScript awgFixture);
      true
    )
    # IPv6 routing only where a listener has IPv6.
    (
      assert lib.hasInfix "-6 rule add pref 8990" (awgStartScript awgFixture);
      true
    )
    (
      assert !lib.hasInfix "-6 rule add pref 8990" (awgStartScript awgProxyFixture);
      true
    )
    # Transparent sockets only where there is something to divert.
    (
      assert lib.hasInfix "net_admin" (readInboundsStart awgFixture);
      assert !lib.hasInfix "net_admin" (readInboundsStart relayFixture);
      true
    )
    # Forwarding only for "lan" listeners.
    (
      assert awgFixture.config.boot.kernel.sysctl."net.ipv4.ip_forward" == 1;
      true
    )
    (
      assert awgFixture.config.boot.kernel.sysctl."net.ipv6.conf.all.forwarding" == 1;
      true
    )
    (
      assert !(awgProxyFixture.config.services.proxy-suite.internal.sysctl ? "net.ipv4.ip_forward");
      true
    )
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
    (
      assert !lib.hasInfix "masquerade" (awgRules awgProxyFixture);
      true
    )

  ]
  ++ failing;
in
{
  inherit assertions;
}
