{
  checkLib,
  pkgs,
  evalProxySuite,
  mkRouting,
  mkTunConfig,
  mkTProxyConfig,
}:

let
  inherit (checkLib) ok;
  generated = import ./read-generated.nix;
  inherit (pkgs) lib;
  inherit (lib) hasInfix;

  mkFixture = mkFixtureWith { };
  mkFixtureWith =
    host: settings:
    evalProxySuite [
      host
      {
        system.stateVersion = "26.05";
        services.proxy-suite = lib.recursiveUpdate {
          enable = true;
          mitm.enable = true;
          proxy = {
            enable = true;
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
  # Without the proxy: mitmproxy alone.
  mkAlone =
    settings:
    evalProxySuite [
      {
        system.stateVersion = "26.05";
        services.proxy-suite = lib.recursiveUpdate {
          enable = true;
          mitm.enable = true;
        } settings;
      }
    ];
  # Only proxy-suite's: these fixtures are not bootable systems.
  failedAssertions =
    fixture:
    map (a: a.message) (
      builtins.filter (a: !a.assertion && lib.hasPrefix "proxy-suite" a.message) fixture.config.assertions
    );
  warningsOf =
    fixture:
    builtins.filter (w: lib.hasPrefix "proxy-suite" w && hasInfix "mitm" w) fixture.config.warnings;
  rejects = fixture: needle: lib.any (hasInfix needle) (failedAssertions fixture);
  services = fixture: fixture.config.systemd.services;
  unit = fixture: (services fixture).proxy-suite-mitm;
  startOf = fixture: generated.readDerivation (unit fixture).serviceConfig.ExecStart;
  # The second of ExecStartPre: the first runs as root ("+"), a string with no text to read.
  caOf =
    fixture: generated.readDerivation (builtins.elemAt (unit fixture).serviceConfig.ExecStartPre 1);
  stageOf = fixture: toString (builtins.head (unit fixture).serviceConfig.ExecStartPre);
  socksStartOf =
    fixture: generated.readDerivation (services fixture).proxy-suite-socks.serviceConfig.ExecStart;
  byTag = list: tag: lib.findFirst (x: x.tag == tag) null list;
  tags = list: map (x: x.tag) list;

  plain = mkFixture { };
  plainConfig = mkTProxyConfig plain;
  plainRules = (mkRouting plain).singBoxRouteModeRules.common;
  plainStart = startOf plain;
  plainSocks = socksStartOf plain;

  full = mkFixtureWith { networking.nftables.enable = true; } {
    proxy.tun.enable = true;
    proxy.tproxy.enable = true;
    mitm = {
      upstream = "vps";
      hosts = [ "example.com" ];
      ignoreHosts = [ "pinned.example" ];
      interfaces = [ "waydroid0" ];
      web.enable = true;
      listener = {
        address = "0.0.0.0";
        openFirewall = true;
        auth = {
          username = "phone";
          passwordFile = "/run/secrets/mitm-listener";
        };
      };
      ca = {
        certFile = "/run/secrets/mitm-ca.crt";
        keyFile = "/run/secrets/mitm-ca.key";
      };
    };
  };
  fullConfig = mkTProxyConfig full;
  fullTun = mkTunConfig full;
  fullRules = (mkRouting full).singBoxRouteModeRules.common;
  fullCustom = (mkRouting full).routingRules;
  fullSocks = socksStartOf full;

  alone = mkAlone { };
  aloneStart = startOf alone;
  aloneAuth = mkAlone {
    mitm.listener.auth = {
      username = "u";
      passwordFile = "/run/secrets/mitm-listener";
    };
  };

  indexOf = pred: list: lib.lists.findFirstIndex pred null list;

  # mitm.udp, with the guests' and without.
  udp = mkFixtureWith { networking.nftables.enable = true; } {
    proxy.tproxy.enable = true;
    mitm = {
      udp.enable = true;
      interfaces = [ "waydroid0" ];
    };
  };
  udpConfig = mkTProxyConfig udp;
  udpRules = (mkRouting udp).singBoxRouteModeRules.common;
  udpStart = startOf udp;
  udpSocks = socksStartOf udp;
  udpNft = checkLib.mkNftRules udp "mitmInterfacesRulesFile";
  udpAlone = mkFixtureWith { networking.nftables.enable = true; } { mitm.udp.enable = true; };
  udpAloneNft = checkLib.mkNftRules udpAlone "mitmInterfacesRulesFile";
  # With pin slots of both routes and the global TUN: the TUN backends reach the tunnel by
  # the local proxy's relay.
  udpPins = mkFixtureWith { networking.nftables.enable = true; } {
    proxy.tun.enable = true;
    perAppRouting = {
      enable = true;
      tun.enable = true;
      tproxy.enable = true;
    };
    mitm.udp.enable = true;
  };
  udpPinsConfig = mkTProxyConfig udpPins;
in
{
  assertions = [
    (ok (failedAssertions plain == [ ]))
    (ok (failedAssertions full == [ ]))
    (ok (failedAssertions alone == [ ]))
    (ok (failedAssertions aloneAuth == [ ]))
    # Hybrid runs sing-box's templates: the same outbound and listeners.
    (
      let
        hybrid = mkFixture { proxy.backend = "hybrid"; };
        config = mkTProxyConfig hybrid;
      in
      ok (
        failedAssertions hybrid == [ ]
        && byTag config.outbounds "mitm" != null
        && byTag config.inbounds "mitm-return" != null
      )
    )

    # Its own user, which alone reads the CA's key; the certificate is for everyone.
    (ok (
      (unit plain).serviceConfig.User == "proxy-suite-mitm"
      && (unit plain).serviceConfig.StateDirectory == "proxy-suite/mitm"
      && (unit plain).serviceConfig.StateDirectoryMode == "0700"
      && (unit plain).serviceConfig.RuntimeDirectory == "proxy-suite-mitm"
      && (unit plain).serviceConfig.RuntimeDirectoryMode == "0755"
    ))
    (ok (builtins.elem "proxy-suite-mitm" (builtins.attrNames plain.config.users.users)))
    # Not proxy-suite's own traffic: TUN, TProxy and the kill switch treat it as any program.
    (ok (!(hasInfix "proxy-suite-mitm" (checkLib.mkTProxyNftRules full))))

    # With the proxy: upstream mode on loopback, back into the backend with the hop login.
    (ok (
      hasInfix "upstream:http://127.0.0.1:18532@127.0.0.1:18531" plainStart
      && hasInfix ".upstream_auth = \"hop:\" + ($hop" plainStart
      && hasInfix "secrets+=(--rawfile hop \"$state/hop-login\")" plainStart
      && hasInfix "/bin/mitmdump --set confdir=" plainStart
      && hasInfix "/bin/mitmweb --set confdir=" plainStart
      && !(hasInfix "proxyauth" plainStart)
    ))
    # mitm.requestLog: its addon from the scripts, there for proxy-ctl to switch on, and the
    # scripts of extraOptions after it.
    (
      let
        logged = startOf (mkFixture {
          mitm.requestLog = {
            enable = true;
            headers = true;
          };
          mitm.extraOptions.scripts = [ "/etc/mine.py" ];
        });
      in
      ok (
        hasInfix "--argjson log true" logged
        && hasInfix "--argjson logHeaders true" logged
        && hasInfix "-proxy-suite-scripts/mitm_request_log.py" logged
        && hasInfix "\"scripts\":[\"/etc/mine.py\"]" logged
        && hasInfix "chosen(\"requestLog\"; $log)" logged
        && hasInfix "--argjson log false" plainStart
        && hasInfix "-proxy-suite-scripts/mitm_request_log.py" plainStart
      )
    )
    # Not kept by default: in memory, rotated at 64 MiB; kept beside the state, never in it
    # (the CA's key is there). Readable by the mitm scope's groups, as mitmweb is theirs.
    (
      let
        kept = startOf (mkFixture {
          mitm.requestLog = {
            persist = true;
            maxSizeMiB = 0.5;
          };
        });
        shared = mkFixture { userControl.enable = true; };
        notMitm = mkFixture {
          userControl = {
            enable = true;
            scopes = [ "routing" ];
          };
        };
      in
      ok (
        hasInfix "log_file=/run/proxy-suite-mitm/requests/requests.jsonl" plainStart
        && hasInfix "--argjson logMax 67108864" plainStart
        && hasInfix "log_file=/var/lib/proxy-suite/mitm-requests/requests.jsonl" kept
        && hasInfix "--argjson logMax 524288" kept
        && hasInfix "--argjson logShared false" plainStart
        && hasInfix "--argjson logShared true" (startOf shared)
        && hasInfix "--argjson logShared false" (startOf notMitm)
        # The whole requests, beside the lines, for an addon of the user's own.
        && hasInfix "flows_file=/run/proxy-suite-mitm/requests/requests.mitm" plainStart
        && hasInfix "--argjson bodies false" plainStart
        && hasInfix "--argjson bodies true" (
          startOf (mkFixture {
            mitm.requestLog.bodies = true;
          })
        )
        && hasInfix "chosen(\"requestBodies\"; $bodies)" plainStart
      )
    )
    # No secret is an argument.
    (ok (!(hasInfix "--set upstream_auth" plainStart) && !(hasInfix "--set web_password" plainStart)))
    # Without it: its own listener, the one way in.
    (ok (
      hasInfix "regular@127.0.0.1:1088" aloneStart
      && !(hasInfix "upstream" aloneStart)
      && hasInfix ".proxyauth = \"u\"" (startOf aloneAuth)
      &&
        (unit aloneAuth).serviceConfig.LoadCredential == [
          "listener-password:/run/secrets/mitm-listener"
        ]
    ))
    (ok (!(services alone ? proxy-suite-socks)))

    # The CA: generated once, or the one given, never through the store.
    (ok (
      hasInfix "openssl req -x509" (caOf plain)
      && !(hasInfix "openssl req -x509" (caOf full))
      &&
        (unit full).serviceConfig.LoadCredential == [
          "ca-cert:/run/secrets/mitm-ca.crt"
          "ca-key:/run/secrets/mitm-ca.key"
        ]
      && hasInfix "$public/ca-bundle.pem" (caOf plain)
      && hasInfix "subject_hash_old" (caOf plain)
    ))
    # Root hands mitmproxy the hop login and the settings: neither is its user's to read
    # where they lie.
    (ok (
      lib.hasPrefix "+" (stageOf plain)
      && lib.hasSuffix "proxy-suite-mitm-stage" (builtins.unsafeDiscardStringContext (stageOf plain))
    ))

    # The outbound and the selector its traffic leaves by, in every config; the listeners
    # in the local proxy's alone.
    (ok (
      byTag plainConfig.outbounds "mitm" == {
        type = "http";
        tag = "mitm";
        server = "127.0.0.1";
        server_port = 18531;
      }
      && (byTag plainConfig.outbounds "proxy-suite-mitm-upstream").type == "selector"
      && byTag fullTun.outbounds "mitm" != null
      && byTag fullTun.outbounds "proxy-suite-mitm-upstream" != null
    ))
    (ok (
      (byTag plainConfig.inbounds "mitm-return").listen == "127.0.0.1"
      && (byTag plainConfig.inbounds "mitm-return").listen_port == 18532
      && (byTag plainConfig.inbounds "mitm-in").listen == "127.0.0.1"
      && (byTag plainConfig.inbounds "mitm-in").listen_port == 1088
      && byTag plainConfig.inbounds "mitm-tproxy-in" == null
      && (byTag fullConfig.inbounds "mitm-in").listen == "0.0.0.0"
      && (byTag fullConfig.inbounds "mitm-tproxy-in").listen_port == 18529
      && lib.all (t: !(lib.hasPrefix "mitm-" t)) (tags fullTun.inbounds)
    ))

    # What comes back leaves by the selector, ahead of every rule that could send it to
    # mitmproxy again, and behind the hop guard.
    (
      let
        back = indexOf (r: (r.inbound or [ ]) == [ "mitm-return" ]) fullRules;
        guard = indexOf (r: (r.action or "") == "reject" && r ? port && !(r ? inbound)) fullRules;
        toMitm = indexOf (r: (r.outbound or "") == "mitm") fullRules;
      in
      ok (
        back != null
        && guard != null
        && guard < back
        && back < toMitm
        && (builtins.elemAt fullRules back).outbound == "proxy-suite-mitm-upstream"
      )
    )
    # mitm.hosts is a rule like any other, after the common ones, so its names are looked
    # up as a proxied one's.
    (ok (
      lib.any (r: (r.domain_suffix or [ ]) == [ "example.com" ] && r.outbound == "mitm") fullCustom
      && !(lib.any (r: r ? domain_suffix && (r.outbound or "") == "mitm") fullRules)
    ))
    # The listener takes everything, UDP refused; one others reach cannot ask for loopback.
    (ok (
      lib.any (
        r: (r.inbound or [ ]) == [ "mitm-in" ] && (r.network or [ ]) == [ "udp" ] && r.action == "reject"
      ) plainRules
      && lib.any (r: (r.inbound or [ ]) == [ "mitm-in" ] && (r.outbound or "") == "mitm") plainRules
      && !(lib.any (r: (r.action or "") == "resolve" && (r.type or "") == "logical") plainRules)
      && lib.any (r: (r.action or "") == "resolve" && (r.type or "") == "logical") fullRules
    ))
    # mitm.interfaces: TCP to mitmproxy, QUIC refused, the rest left to the rules.
    (ok (
      lib.any (
        r:
        lib.elem "mitm-tproxy-in" (r.inbound or [ ])
        && (r.network or [ ]) == [ "tcp" ]
        && (r.outbound or "") == "mitm"
      ) fullRules
      && lib.any (
        r:
        lib.elem "mitm-tproxy-in" (r.inbound or [ ]) && (r.port or [ ]) == [ 443 ] && r.action == "reject"
      ) fullRules
    ))

    # Their divert: the guests' TCP and QUIC alone, with a mark of its own, ahead of TProxy's
    # chain; brought up with mitmproxy and the backend, and gone with either.
    (
      let
        nft = checkLib.mkNftRules full "mitmInterfacesRulesFile";
        divert = (services full).proxy-suite-mitm-interfaces;
        up = generated.readDerivation divert.serviceConfig.ExecStart;
      in
      ok (
        hasInfix "table inet proxy_suite_mitm" nft
        && hasInfix "priority mangle - 1" nft
        && hasInfix "iifname != { \"waydroid0\" } return" nft
        && hasInfix "meta nfproto ipv4 meta l4proto tcp meta mark set 23296 tproxy ip to 127.0.0.1:18529" nft
        && hasInfix "meta nfproto ipv4 udp dport 443 meta mark set 23296 tproxy ip to 127.0.0.1:18529" nft
        && !(hasInfix "l4proto { tcp, udp }" nft)
        && hasInfix "ip daddr 192.168.0.0/16 return" nft
        && hasInfix "rule add fwmark 23296 table 104" up
        && hasInfix "sysctl -q -w net.ipv4.ip_forward=1" up
        && builtins.elem "proxy-suite-mitm.service" divert.bindsTo
        && builtins.elem "proxy-suite-socks.service" divert.bindsTo
        && divert.wantedBy == [ "proxy-suite-mitm.service" ]
        && full.config.boot.kernel.sysctl."net.ipv4.ip_forward" == 1
        && hasInfix "iifname \"waydroid0\" meta mark 23296 socket transparent 1 accept" full.config.networking.firewall.extraInputRules
        && !((services plain) ? proxy-suite-mitm-interfaces)
      )
    )
    (ok (
      rejects (mkFixture {
        proxy.tproxy = {
          enable = true;
          lanInterfaces = [ "br0" ];
        };
        mitm.interfaces = [ "br0" ];
      }) "in both mitm.interfaces and proxy.tproxy.lanInterfaces"
    ))

    # The start script: the chosen upstream, the logins by file, and the name kept from
    # runtime outbounds and groups.
    (ok (
      hasInfix "MITM_UPSTREAM=proxy" plainSocks
      && hasInfix "MITM_UPSTREAM=vps" fullSocks
      && hasInfix "--rawfile mitm_hop /run/proxy-suite-hop-login" plainSocks
      && hasInfix "--rawfile mitm_listener_password /run/secrets/mitm-listener" fullSocks
      && !(hasInfix "mitm_listener_password" plainSocks)
      && hasInfix "| tor | mitm" (
        lib.replaceStrings [ "proxy-suite-* | mitm" ] [ "| tor | mitm" ] plainSocks
      )
    ))
    (ok (
      builtins.elem "proxy-suite-mitm.service" (services plain).proxy-suite-socks.wants
      && !(builtins.elem "proxy-suite-mitm.service" (services plain).proxy-suite-socks.after)
    ))
    (ok (builtins.elem 1088 full.config.networking.firewall.allowedTCPPorts))
    (ok (!(builtins.elem 1088 plain.config.networking.firewall.allowedTCPPorts)))

    # A listener others reach, with no login.
    (ok (
      warningsOf (mkFixture {
        mitm.listener.address = "0.0.0.0";
      }) != [ ]
      && warningsOf full == [ ]
    ))

    (ok (rejects (mkFixture { proxy.backend = "xray"; }) "mitm needs proxy.backend"))
    (ok (rejects (mkFixture { mitm.upstream = "nowhere"; }) "mitm.upstream"))
    (ok (rejects (mkFixture { mitm.upstream = "mitm"; }) "mitm.upstream"))
    (ok (rejects (mkFixture { mitm.upstream = "block"; }) "mitm.upstream"))
    (ok (rejects (mkAlone { mitm.upstream = "proxy"; }) "requires proxy.enable"))
    (ok (rejects (mkAlone { mitm.hosts = [ "example.com" ]; }) "mitm.hosts requires"))
    (ok (rejects (mkAlone { mitm.listener.enable = false; }) "needs mitm.listener.enable"))
    (ok (rejects (mkAlone { mitm.interfaces = [ "br0" ]; }) "mitm.interfaces requires"))
    (ok (
      rejects (mkFixture {
        proxy.outbounds = [
          {
            tag = "mitm";
            url = "http://vps.example.com:8080";
          }
        ];
      }) "\"mitm\""
    ))
    (ok (
      rejects (mkFixture {
        proxy.outbounds = [
          {
            tag = "vps";
            url = "http://vps.example.com:8080";
            detour = "mitm";
          }
        ];
      }) "detour cannot name \"mitm\""
    ))
    (ok (rejects (mkFixture { mitm.ca.certFile = "/run/secrets/ca.crt"; }) "go together"))
    (ok (rejects (mkFixture { mitm.listener.auth.username = "u"; }) "go together"))
    (ok (rejects (mkFixture { mitm.listener.openFirewall = true; }) "openFirewall"))
    (ok (rejects (mkFixture { mitm.returnPort = 18531; }) "must differ"))
    (ok (rejects (mkFixture { mitm.listener.port = 1080; }) "mitm.listener.port"))

    # mitm.udp: mitmproxy's WireGuard listener beside its upstream mode, the backend's endpoint
    # into it, and its listener for what mitmproxy sends on.
    (ok (failedAssertions udp == [ ] && failedAssertions udpAlone == [ ]))
    (ok (
      hasInfix "wireguard:/var/lib/proxy-suite/mitm/wireguard.json@127.0.0.1:18527" udpStart
      && hasInfix "upstream:http://127.0.0.1:18532@127.0.0.1:18531" udpStart
      && !(hasInfix "wireguard:" plainStart)
    ))
    (
      let
        endpoint = byTag (udpConfig.endpoints or [ ]) "mitm-udp";
        back = byTag udpConfig.inbounds "mitm-udp-return";
      in
      ok (
        endpoint.type == "wireguard"
        && endpoint.mtu == 1500
        && (builtins.head endpoint.peers).address == "127.0.0.1"
        && (builtins.head endpoint.peers).port == 18527
        && back.type == "tproxy"
        && back.listen == "127.0.0.1"
        && back.listen_port == 18528
        && back.network == "udp"
        && !(plainConfig ? endpoints)
        && !(mkTunConfig udp ? endpoints)
      )
    )
    # Its keys are root's, drawn once, handed to the backend by file, never through argv.
    (ok (
      hasInfix "proxy-suite-mitm-wireguard-keys" udpSocks
      && hasInfix "--rawfile mitm_wireguard /var/lib/proxy-suite/mitm-wireguard.json" udpSocks
      && !(hasInfix "mitm_wireguard" plainSocks)
    ))
    # What comes back on UDP leaves by the upstream, as mitm-return's TCP; sent to it straight,
    # refused.
    (
      let
        guard = indexOf (
          r: lib.elem "mitm-udp-return" (r.inbound or [ ]) && (r.action or "") == "reject" && r ? ip_cidr
        ) udpRules;
        back = indexOf (
          r:
          lib.elem "mitm-udp-return" (r.inbound or [ ]) && (r.outbound or "") == "proxy-suite-mitm-upstream"
        ) udpRules;
      in
      ok (guard != null && back != null && guard < back)
    )
    # The guests' UDP and SOCKS5's to it, QUIC still refused first.
    (
      let
        quic = indexOf (
          r:
          lib.elem "mitm-tproxy-in" (r.inbound or [ ]) && (r.port or [ ]) == [ 443 ] && r.action == "reject"
        ) udpRules;
        guests = indexOf (
          r:
          lib.elem "mitm-tproxy-in" (r.inbound or [ ])
          && (r.network or [ ]) == [ "udp" ]
          && (r.outbound or "") == "mitm-udp"
        ) udpRules;
      in
      ok (
        quic != null
        && guests != null
        && quic < guests
        && lib.any (
          r:
          (r.inbound or [ ]) == [ "mitm-in" ]
          && (r.network or [ ]) == [ "udp" ]
          && (r.outbound or "") == "mitm-udp"
        ) udpRules
        && lib.any (r: (r.inbound or [ ]) == [ "mitm-in" ] && (r.port or [ ]) == [ 443 ]) udpRules
      )
    )
    # Its table: the guests' UDP whole; mitmproxy's own marked as it leaves, back on lo to the
    # backend, and dropped if its rule is gone. The global TProxy chain leaves that mark alone.
    (
      let
        up = generated.readDerivation (services udp).proxy-suite-mitm-interfaces.serviceConfig.ExecStart;
      in
      ok (
        hasInfix "meta nfproto ipv4 meta l4proto udp meta mark set 23296 tproxy ip to 127.0.0.1:18529" udpNft
        && hasInfix "iifname \"lo\" meta mark 23296 meta nfproto ipv4 meta l4proto udp tproxy ip to 127.0.0.1:18528" udpNft
        && hasInfix "type route hook output priority mangle - 1" udpNft
        && hasInfix "meta skuid != \"proxy-suite-mitm\" return" udpNft
        && hasInfix "meta mark 23296 oifname != \"lo\" drop" udpNft
        && hasInfix "meta mark 23296 return" (checkLib.mkTProxyNftRules udp)
        && !(hasInfix "meta mark 23296 return" (checkLib.mkTProxyNftRules full))
        && hasInfix "rule add fwmark 23296 table 104 pref 8987" up
      )
    )
    # Without the guests: the return alone, in the same unit.
    (ok (
      (services udpAlone) ? proxy-suite-mitm-interfaces
      && !(hasInfix "iifname !=" udpAloneNft)
      && hasInfix "tproxy ip to 127.0.0.1:18528" udpAloneNft
      && !(udpAlone.config.boot.kernel.sysctl ? "net.ipv4.ip_forward")
    ))
    # The backend filter's UDP twins: to mitmproxy with mitm.udp, QUIC refused; refused whole
    # without. The keys are set there.
    (
      let
        filter =
          udpTag:
          import ../../modules/proxy-suite/service/script-blocks/backend-jq-filter.nix {
            inherit lib;
            pureXrayEnabled = false;
            proxyInboundsGuardPrivate = false;
            selectionMode = "manual";
            mitm = {
              tag = "mitm";
              selector = "proxy-suite-mitm-upstream";
              hopUser = "hop";
              relayInbound = "mitm-udp-in";
              inherit udpTag;
            };
          };
        withUdp = filter "mitm-udp";
        without = filter null;
      in
      ok (
        hasInfix "outbound: \"mitm-udp\"}" withUdp
        && hasInfix "{network: [\"udp\"], port: [443]}" withUdp
        && hasInfix "no keys for the mitm-udp tunnel" withUdp
        && !(hasInfix "outbound: \"mitm-udp\"" without)
        && !(hasInfix "mitm_wireguard" without)
        && hasInfix "action: \"reject\"}, ." without
      )
    )
    (ok (rejects (mkAlone { mitm.udp.enable = true; }) "mitm.udp.enable requires proxy.enable"))
    # The relay: a SOCKS5 listener of the local proxy's, and in each TUN backend an outbound to
    # it under the tunnel's tag, which the filter gives the hop login.
    (
      let
        relay = byTag udpPinsConfig.inbounds "mitm-udp-in";
        socksTo = config: byTag config.outbounds "mitm-udp";
        relayed =
          config:
          (socksTo config).type == "socks"
          && (socksTo config).server_port == 18526
          && (socksTo config).network == "udp";
        relayRules = builtins.filter (r: (r.inbound or [ ]) == [ "mitm-udp-in" ]) udpRules;
      in
      ok (
        failedAssertions udpPins == [ ]
        && relay.type == "socks"
        && relay.listen == "127.0.0.1"
        && relay.listen_port == 18526
        && socksTo udpPinsConfig == null
        && relayed (mkTunConfig udpPins)
        && relayed (checkLib.mkPerAppTunConfig udpPins)
        &&
          map (r: r.action or r.outbound) relayRules == [
            "reject"
            "mitm-udp"
            "reject"
          ]
      )
    )
    # proxy.tproxy.bridgeNetfilter: kept, the divert says so for a bridge; off, a unit Docker's
    # start pulls in turns it off, and so does the divert as it comes up; off with nothing
    # diverted, nothing is touched.
    (
      let
        off = mkFixtureWith { networking.nftables.enable = true; } {
          proxy.tproxy.bridgeNetfilter = "off";
          mitm.interfaces = [ "waydroid0" ];
        };
        offUndiverted = mkFixture { proxy.tproxy.bridgeNetfilter = "off"; };
        upOf =
          fixture:
          generated.readDerivation (services fixture).proxy-suite-mitm-interfaces.serviceConfig.ExecStart;
        unitOff = (services off).proxy-suite-bridge-netfilter;
      in
      ok (
        failedAssertions off == [ ]
        && hasInfix "is a bridge and net.bridge.bridge-nf-call-iptables is on" (upOf full)
        && !(hasInfix "echo 0 >" (upOf full))
        && hasInfix "echo 0 >" (upOf off)
        && !(hasInfix "is a bridge" (upOf off))
        && builtins.elem "docker.service" unitOff.wantedBy
        && builtins.elem "docker.service" unitOff.after
        && unitOff.serviceConfig.RemainAfterExit == false
        && !((services full) ? proxy-suite-bridge-netfilter)
        && !((services offUndiverted) ? proxy-suite-bridge-netfilter)
      )
    )
    # TProxy's marks for this host's own programs pass the reverse path check on lo, as
    # mitm.udp's does: the pin slots' among them.
    (
      let
        rules = udpPins.config.networking.firewall.extraReversePathFilterRules;
        line = builtins.head (
          builtins.filter (hasInfix "iifname \"lo\" meta mark {") (lib.splitString "\n" rules)
        );
      in
      ok (hasInfix "23168" line && hasInfix "23175" line && !(hasInfix "23176" line))
    )
    # Pin slots: a UDP selector and a QUIC one each, whose rules come before the slot's own.
    (
      let
        check =
          config: route:
          let
            names = tags config.outbounds;
            slot = "proxy-suite-pin-${route}-0";
            at = outbound: indexOf (r: (r.outbound or "") == outbound) config.route.rules;
          in
          builtins.elem "${slot}-udp" names
          && builtins.elem "${slot}-quic" names
          && at "${slot}-quic" < at "${slot}-udp"
          && at "${slot}-udp" < at slot
          && (builtins.elemAt config.route.rules (at "${slot}-quic")).port == [ 443 ];
      in
      ok (
        check udpPinsConfig "tproxy"
        && check (checkLib.mkPerAppTunConfig udpPins) "tun"
        && !(builtins.elem "proxy-suite-pin-tproxy-0-udp" (
          tags
            (mkTProxyConfig (mkFixture {
              perAppRouting = {
                enable = true;
                tproxy.enable = true;
              };
            })).outbounds
        ))
      )
    )
    # What comes back on lo passes the reverse path check, which the iptables firewall's cannot
    # be told.
    (ok (
      hasInfix "iifname \"lo\" meta mark 23296 accept" udpAlone.config.networking.firewall.extraReversePathFilterRules
      && rejects (mkFixture { mitm.udp.enable = true; }) "mitm.udp.enable needs the nftables firewall"
    ))
    (ok (
      rejects (mkFixture {
        mitm.udp = {
          enable = true;
          port = 18531;
        };
      }) "must differ"
    ))

    # mitm.attach: its addon ahead of the request log's, its socket in a directory of its own.
    (ok (
      hasInfix "-proxy-suite-scripts/mitm_attach.py" plainStart
      && hasInfix "\"attach_socket\":\"/run/proxy-suite-mitm/attach/attach.sock\"" plainStart
      && hasInfix "\"attach_timeout\":5" plainStart
      && !(hasInfix "mitm_attach.py" (
        startOf (mkFixture {
          mitm.attach.enable = false;
        })
      ))
    ))
    # mitm.addons: their spool root's alone, unless the mitm scope is given it; what they
    # write beside the request log.
    (
      let
        tmpfiles = fixture: fixture.config.systemd.tmpfiles.rules;
        given = mkFixture {
          userControl.enable = true;
          mitm.addons.userControl = true;
        };
      in
      ok (
        builtins.elem "d /var/lib/proxy-suite/mitm-addons.d 0700 root root -" (tmpfiles plain)
        && builtins.elem "d /var/lib/proxy-suite/mitm-addons.d 2770 root proxy-suite -" (tmpfiles given)
        && builtins.elem "PROXY_SUITE_MITM_OUTPUT=/run/proxy-suite-mitm/requests/addons" (unit plain)
        .serviceConfig.Environment
      )
    )
    # mitm.pythonPackages: on the path of mitmproxy's own addons, only when there are some.
    (ok (
      lib.any (lib.hasPrefix "PYTHONPATH=")
        (unit (mkFixture {
          mitm.pythonPackages = ps: [ ps.six ];
        })).serviceConfig.Environment
      && !(lib.any (lib.hasPrefix "PYTHONPATH=") (unit plain).serviceConfig.Environment)
    ))
  ];
}
