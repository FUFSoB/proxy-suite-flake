{
  checkLib,
  pkgs,
  evalProxySuite,
  baseModule,
  mkRoutingRules,
  mkBadProxySuiteFixture,
  mkFailingAssertions,
}:

let
  inherit (checkLib) ok mkProxySuite startScript;
  generated = import ./read-generated.nix;

  testHostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

  # Expected outbounds carry proxy.tproxy.proxyMark, as the start script sets it.
  markOf = fixture: fixture.config.services.proxy-suite.proxy.tproxy.proxyMark;

  # writeText paths are content-addressed: finding one in the start script pins the
  # JSON. The context is dropped so the check may mention it.
  expectedOutboundFile =
    value:
    builtins.unsafeDiscardStringContext "${pkgs.writeText "proxy-suite-core" (builtins.toJSON value)}";

  # SingBox dials SSH natively: no unit, no local SOCKS listener.
  sshNativeSingBox = mkProxySuite {
    enable = true;
    sshProxy = {
      enable = true;
      server.user = "root";
      server.host = "ssh.example.com";
      asOutbound = true;
      identityFile = "/run/secrets/ssh-key";
      hostKey = [ testHostKey ];
    };
    proxy = {
      enable = true;
      backend = "sing-box";
    };
  };
  sshNativeSingBoxStart = startScript sshNativeSingBox;
  expectedNativeSingBoxOutbound = expectedOutboundFile {
    type = "ssh";
    tag = "ssh-proxy";
    server = "ssh.example.com";
    server_port = 22;
    user = "root";
    host_key = [ testHostKey ];
    routing_mark = markOf sshNativeSingBox;
  };

  # hostKeyFile keys are injected at start, not baked into the JSON.
  sshHostKeyFile = mkProxySuite {
    enable = true;
    sshProxy = {
      enable = true;
      server.user = "root";
      server.host = "ssh.example.com";
      server.port = 2222;
      asOutbound = true;
      hostKeyFile = "/run/secrets/ssh-known-hosts";
    };
    proxy = {
      enable = true;
      backend = "sing-box";
    };
  };
  sshHostKeyFileStart = startScript sshHostKeyFile;

  # asOutbound = false: a standalone tunnel, so the OpenSSH unit exists even on SingBox.
  sshStandalone = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        sshProxy = {
          enable = true;
          server.user = "root";
          server.host = "ssh.example.com";
          asOutbound = false;
          serviceUser = "proxy";
          identityFile = "/run/secrets/ssh-key";
          knownHostsFile = "/run/secrets/ssh-known-hosts";
          extraArgs = [
            "-o"
            "IPQoS=throughput"
          ];
        };
        proxy = {
          enable = true;
          backend = "sing-box";
          outbounds = [
            {
              tag = "static";
              url = "http://proxy.example.com:8080";
            }
          ];
        };
      };
    }
  ];
  standaloneService = sshStandalone.config.systemd.services."proxy-suite-ssh-proxy";
  standaloneStartScript = generated.readDerivation standaloneService.serviceConfig.ExecStart;
  sshStandaloneStart = startScript sshStandalone;

  unchanged = evalProxySuite [ baseModule ];
  unchangedStart = startScript unchanged;

  # XRay keeps the unit and proxies through its listener, domainStrategy on sockopt.
  sshXray = mkProxySuite {
    enable = true;
    sshProxy = {
      enable = true;
      server.user = "proxy";
      server.host = "ssh.example.com";
      asOutbound = true;
      domainStrategy = "prefer_ipv4";
    };
    proxy = {
      enable = true;
      backend = "xray";
    };
  };
  sshXrayStart = startScript sshXray;
  xrayService = sshXray.config.systemd.services."proxy-suite-ssh-proxy";
  xrayStartScript = generated.readDerivation xrayService.serviceConfig.ExecStart;
  expectedXrayOutbound = expectedOutboundFile {
    protocol = "socks";
    tag = "ssh-proxy";
    settings = {
      address = "127.0.0.1";
      port = 1091;
    };
    streamSettings.sockopt = {
      mark = markOf sshXray;
      domainStrategy = "UseIPv4v6";
    };
  };

  sshHybrid = mkProxySuite {
    enable = true;
    sshProxy = {
      enable = true;
      server.user = "proxy";
      server.host = "ssh.example.com";
      asOutbound = true;
      hostKey = [ testHostKey ];
    };
    proxy = {
      enable = true;
      backend = "hybrid";
    };
  };
  sshHybridStart = startScript sshHybrid;
  expectedHybridOutbound = expectedOutboundFile {
    type = "ssh";
    tag = "ssh-proxy";
    server = "ssh.example.com";
    server_port = 22;
    user = "proxy";
    host_key = [ testHostKey ];
    routing_mark = markOf sshHybrid;
  };

  sshSelector = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        sshProxy = {
          enable = true;
          server.user = "proxy";
          server.host = "ssh.example.com";
          asOutbound = true;
          hostKey = [ testHostKey ];
        };
        proxy = {
          enable = true;
          backend = "sing-box";
          selection = "selector";
          outbounds = [
            {
              tag = "static";
              url = "http://proxy.example.com:8080";
            }
          ];
        };
      };
    }
  ];
  sshSelectorStart = startScript sshSelector;

  sshUrltest = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        sshProxy = {
          enable = true;
          server.user = "proxy";
          server.host = "ssh.example.com";
          asOutbound = true;
        };
        proxy = {
          enable = true;
          backend = "xray";
          selection = "urltest";
          outbounds = [
            {
              tag = "static";
              url = "http://proxy.example.com:8080";
            }
          ];
        };
      };
    }
  ];
  sshUrltestStart = startScript sshUrltest;

  sshRouting = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        sshProxy = {
          enable = true;
          server.user = "proxy";
          server.host = "ssh.example.com";
          asOutbound = true;
          hostKey = [ testHostKey ];
        };
        proxy = {
          enable = true;
          backend = "sing-box";
          selection = "selector";
          routing.rules = [
            {
              outbound = "ssh-proxy";
              domains = [ "ssh-only.example.com" ];
            }
          ];
        };
      };
    }
  ];

  invalidAssertions = mkFailingAssertions mkBadProxySuiteFixture [
    {
      enable = true;
      sshProxy = {
        enable = true;
        server.user = "proxy";
        server.host = "ssh.example.com";
        asOutbound = true;
        hostKey = [ testHostKey ];
      };
    }
    {
      enable = true;
      sshProxy = {
        enable = true;
        asOutbound = true;
        hostKey = [ testHostKey ];
      };
      proxy = {
        enable = true;
        backend = "sing-box";
      };
    }
    {
      enable = true;
      sshProxy = {
        enable = true;
        server.user = "proxy";
        server.host = "ssh.example.com";
        asOutbound = true;
        hostKey = [ testHostKey ];
      };
      proxy = {
        enable = true;
        backend = "sing-box";
        outbounds = [
          {
            tag = "ssh-proxy";
            url = "http://proxy.example.com:8080";
          }
        ];
      };
    }
    # An empty hostKey would accept any key on SingBox.
    {
      enable = true;
      sshProxy = {
        enable = true;
        server.user = "proxy";
        server.host = "ssh.example.com";
        asOutbound = true;
      };
      proxy = {
        enable = true;
        backend = "sing-box";
      };
    }
  ];

  assertions = [
    (ok (sshNativeSingBox.config.services.proxy-suite.proxy.outbounds == [ ]))
    # No OpenSSH unit and no ordering against one: sing-box dials SSH in-process.
    (ok (!(sshNativeSingBox.config.systemd.services ? "proxy-suite-ssh-proxy")))
    (
      assert
        sshNativeSingBox.config.systemd.services."proxy-suite-socks".after == [
          "network-online.target"
        ];
      true
    )
    (
      assert
        sshNativeSingBox.config.systemd.services."proxy-suite-socks".wants == [
          "network-online.target"
        ];
      true
    )
    (
      assert pkgs.lib.hasInfix expectedNativeSingBoxOutbound sshNativeSingBoxStart;
      # The daemon cannot read the key where it lives: it gets a group-readable copy.
      assert pkgs.lib.hasInfix
        "install -m 0640 -g proxy-suite-daemon /run/secrets/ssh-key \"$SSH_IDENTITY\""
        sshNativeSingBoxStart;
      assert pkgs.lib.hasInfix "'.private_key_path = $key'" sshNativeSingBoxStart;
      true
    )
    # The global local-resolve route rule is gone; the native outbound resolves.
    (ok (!(pkgs.lib.hasInfix "\"resolve\"" sshNativeSingBoxStart)))

    # Non-default port has to be looked up as "[host]:port" in known_hosts.
    (ok (pkgs.lib.hasInfix "ssh-keygen -F '[ssh.example.com]:2222'" sshHostKeyFileStart))
    (ok (pkgs.lib.hasInfix "'.host_key = \$hk'" sshHostKeyFileStart))
    (ok (pkgs.lib.hasInfix "/run/secrets/ssh-known-hosts" sshHostKeyFileStart))
    # The keys must not be baked into the store-resident outbound JSON.
    (
      assert
        !(pkgs.lib.hasInfix "host_key" (
          builtins.toJSON sshHostKeyFile.config.services.proxy-suite.sshProxy.hostKey
        ));
      true
    )

    # Standalone tunnel: unit is created, but nothing is wired as an outbound.
    (ok (sshStandalone.config.systemd.services ? "proxy-suite-ssh-proxy"))
    (ok (!(pkgs.lib.hasInfix "ssh-proxy" sshStandaloneStart)))
    (ok (standaloneService.serviceConfig.User == "proxy"))
    (ok (!(standaloneService.serviceConfig ? SocketMark)))
    # Hardening: a half-open tunnel must be detected and always restarted.
    (ok (standaloneService.serviceConfig.Restart == "always"))
    (ok (standaloneService.serviceConfig.LimitNOFILE == 65536))
    (ok (standaloneService.startLimitIntervalSec == 0))
    (ok (pkgs.lib.hasInfix "ServerAliveInterval=15" standaloneStartScript))
    (ok (pkgs.lib.hasInfix "ServerAliveCountMax=3" standaloneStartScript))
    (ok (pkgs.lib.hasInfix "ConnectTimeout=10" standaloneStartScript))
    (ok (pkgs.lib.hasInfix "IPQoS=throughput" standaloneStartScript))
    (ok (
      pkgs.lib.hasInfix ''UserKnownHostsFile="$CREDENTIALS_DIRECTORY/known_hosts"'' standaloneStartScript
    ))
    # Secrets reach the unprivileged user as credentials.
    (
      assert
        standaloneService.serviceConfig.LoadCredential == [
          "identity:/run/secrets/ssh-key"
          "known_hosts:/run/secrets/ssh-known-hosts"
        ];
      true
    )

    (ok (!(unchanged.config.systemd.services ? "proxy-suite-ssh-proxy")))
    (ok (!(pkgs.lib.hasInfix "ssh-proxy" unchangedStart)))

    # XRay keeps the unit and orders the backend behind it.
    (ok (sshXray.config.systemd.services ? "proxy-suite-ssh-proxy"))
    (
      assert
        sshXray.config.systemd.services."proxy-suite-socks".after == [
          "network-online.target"
          "proxy-suite-ssh-proxy.service"
        ];
      true
    )
    (
      assert
        sshXray.config.systemd.services."proxy-suite-socks".wants == [
          "network-online.target"
          "proxy-suite-ssh-proxy.service"
        ];
      true
    )
    (ok (xrayService.serviceConfig.Restart == "always"))
    (ok (pkgs.lib.hasInfix "ServerAliveInterval=15" xrayStartScript))
    # prefer_ipv4 maps onto XRay's "IPv4 first, fall back to IPv6".
    (ok (pkgs.lib.hasInfix expectedXrayOutbound sshXrayStart))

    # Hybrid routes the tunnel through sing-box, so it gets the native shape.
    (ok (!(sshHybrid.config.systemd.services ? "proxy-suite-ssh-proxy")))
    (ok (pkgs.lib.hasInfix "_proxy_suite_add_sing_box_ob" sshHybridStart))
    (ok (pkgs.lib.hasInfix expectedHybridOutbound sshHybridStart))

    (ok (pkgs.lib.hasInfix "selector" sshSelectorStart))
    (ok (pkgs.lib.hasInfix "ssh-proxy" sshSelectorStart))
    (ok (pkgs.lib.hasInfix "# outbound: ssh-proxy (OpenSSH SOCKS5 listener)" sshUrltestStart))
    (ok (builtins.any (rule: (rule.outbound or null) == "ssh-proxy") (mkRoutingRules sshRouting)))
  ]
  ++ invalidAssertions;
in
{
  inherit assertions;
}
