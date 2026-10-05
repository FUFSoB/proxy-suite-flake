{
  checkLib,
  pkgs,
  evalProxySuite,
  mkBadProxySuiteFixture,
  mkFailingAssertions,
}:

let
  inherit (checkLib) mkProxySuite;
  generated = import ./read-generated.nix;
  inherit (pkgs.lib) hasInfix escapeShellArg;

  profile = "/run/secrets/wgcf-profile.conf";
  markOf = fixture: toString fixture.config.services.proxy-suite.proxy.tproxy.proxyMark;

  mkFixture =
    backend: warp:
    evalProxySuite [
      {
        system.stateVersion = "26.05";
        services.proxy-suite = {
          enable = true;
          warp = {
            enable = true;
            configFile = profile;
          }
          // warp;
          proxy = {
            enable = true;
            inherit backend;
          };
        };
      }
    ];
  startOf =
    fixture:
    generated.readDerivation
      fixture.config.systemd.services."proxy-suite-socks".serviceConfig.ExecStart;
  tunnelOf =
    fixture:
    generated.readDerivation
      fixture.config.systemd.services."proxy-suite-warp-tunnel".serviceConfig.ExecStart;
  convertCall =
    fixture: "warp_outbound.py --tag \"$TUNNEL_TAG\" --routing-mark ${markOf fixture} < \"$profile\"";
  singBoxHop = ''"server":"127.0.0.1","server_port":18538,"tag":"warp","type":"socks"'';
  xrayHop = ''"protocol":"socks","settings":{"address":"127.0.0.1","port":18538},"tag":"warp"'';

  singBox = mkFixture "sing-box" { asOutbound = "singBox"; };
  singBoxStart = startOf singBox;
  singBoxTunnel = tunnelOf singBox;
  xray = mkFixture "xray" { asOutbound = "singBox"; };
  xrayStart = startOf xray;
  hybrid = mkFixture "hybrid" { asOutbound = "singBox"; };
  hybridStart = startOf hybrid;
  auto = mkFixture "sing-box" {
    asOutbound = "singBox";
    configFile = null;
  };
  autoTunnel = tunnelOf auto;
  generator = mkFixture "sing-box" {
    asOutbound = "singBox";
    configFile = null;
    generatorUrl = "https://gen.example.com/api/warp?mode=awg2";
  };
  registerOf =
    fixture:
    generated.readDerivation fixture.config.systemd.services."proxy-suite-warp".serviceConfig.ExecStart;
  autoRegister = registerOf auto;
  endpointed = mkFixture "sing-box" {
    asOutbound = "singBox";
    endpoint = "[2606:4700:d0::a29f:c001]:500";
  };
  generatorRegister = registerOf generator;

  amneziaWg = mkProxySuite {
    enable = true;
    amneziaWg.enable = true;
    warp = {
      enable = true;
      configFile = profile;
      asAmneziaWg = true;
    };
  };

  amneziaWgAutostart = mkProxySuite {
    enable = true;
    amneziaWg.enable = true;
    warp = {
      enable = true;
      configFile = profile;
      asAmneziaWg = true;
      autostart = true;
    };
  };

  amneziaWgEndpoint = mkProxySuite {
    enable = true;
    amneziaWg.enable = true;
    warp = {
      enable = true;
      configFile = profile;
      asAmneziaWg = true;
      endpoint = "162.159.192.1:500";
    };
  };

  # Several devices: one registration and one profile each, and "warp" is their group.
  instances = mkProxySuite {
    enable = true;
    amneziaWg.enable = true;
    proxy.enable = true;
    warp = {
      enable = true;
      asOutbound = "interface";
      instances = 2;
    };
  };
  instancesCfg = instances.config.services.proxy-suite;
  devices = mkFixture "sing-box" {
    asOutbound = "singBox";
    devices = {
      a = { };
      b.endpoint = "162.159.193.10:500";
    };
  };
  devicesStart = startOf devices;

  invalidAssertions = mkFailingAssertions mkBadProxySuiteFixture [
    # An IPv6 endpoint without brackets.
    {
      enable = true;
      warp = {
        enable = true;
        configFile = profile;
        asOutbound = "singBox";
        endpoint = "2606:4700:d0::a29f:c001:500";
      };
      proxy.enable = true;
    }
    # instances is devices' shorthand, not an addition.
    {
      enable = true;
      amneziaWg.enable = true;
      proxy.enable = true;
      warp = {
        enable = true;
        asOutbound = "interface";
        instances = 2;
        devices.extra = { };
      };
    }
    # With two devices, "warp" is their group's name.
    {
      enable = true;
      amneziaWg.enable = true;
      proxy.enable = true;
      warp = {
        enable = true;
        asOutbound = "interface";
        devices = {
          warp = { };
          other = { };
        };
      };
    }
    # One global profile, one key.
    {
      enable = true;
      amneziaWg.enable = true;
      warp = {
        enable = true;
        asAmneziaWg = true;
        instances = 2;
      };
    }
    # Enabled but used for nothing.
    {
      enable = true;
      warp = {
        enable = true;
        configFile = profile;
      };
    }
    # asOutbound without a backend.
    {
      enable = true;
      warp = {
        enable = true;
        configFile = profile;
        asOutbound = "singBox";
      };
    }
    # asAmneziaWg without AmneziaWG.
    {
      enable = true;
      warp = {
        enable = true;
        configFile = profile;
        asAmneziaWg = true;
      };
    }
    # Both modes at once: two sessions on one WARP key.
    {
      enable = true;
      amneziaWg.enable = true;
      warp = {
        enable = true;
        configFile = profile;
        asOutbound = "singBox";
        asAmneziaWg = true;
      };
      proxy.enable = true;
    }
    # autostart is the global profile's; an outbound always runs.
    {
      enable = true;
      warp = {
        enable = true;
        configFile = profile;
        asOutbound = "singBox";
        autostart = true;
      };
      proxy.enable = true;
    }
    # Tag collision with a declared outbound.
    {
      enable = true;
      warp = {
        enable = true;
        configFile = profile;
        asOutbound = "singBox";
      };
      proxy = {
        enable = true;
        outbounds = [
          {
            tag = "warp";
            url = "http://proxy.example.com:8080";
          }
        ];
      };
    }
  ];
in
{
  assertions = [
    # Every backend dials the tunnel unit's loopback listener.
    (
      assert hasInfix singBoxHop singBoxStart;
      true
    )
    (
      assert hasInfix "_proxy_suite_record_tag_source warp warp" singBoxStart;
      true
    )
    (
      assert hasInfix xrayHop xrayStart;
      true
    )
    (
      assert
        hasInfix singBoxHop hybridStart && hasInfix "_proxy_suite_add_sing_box_ob \"$OB_JSON\"" hybridStart;
      true
    )
    # Only the tunnel reads the profile, at start; the private key never reaches the store.
    (
      assert !(hasInfix "warp_outbound.py" singBoxStart) && !(hasInfix profile singBoxStart);
      true
    )
    (
      assert hasInfix "profile=${escapeShellArg profile}" singBoxTunnel;
      true
    )
    (
      assert hasInfix (convertCall singBox) singBoxTunnel;
      true
    )
    # The tag reaches the scripts as a variable, never spliced into shell or jq text.
    (
      assert
        hasInfix "TUNNEL_TAG=warp\n" singBoxTunnel
        && hasInfix "export TUNNEL_TAG" singBoxTunnel
        && hasInfix ''jq -n --arg tag "$TUNNEL_TAG"'' singBoxTunnel
        && hasInfix "final: $tag" singBoxTunnel
        && !(hasInfix ''"warp"'' singBoxTunnel);
      true
    )
    # The root conversion step is sandboxed; the runtime directory stays writable for the
    # watchdog's hints.
    (
      let
        sc = singBox.config.systemd.services."proxy-suite-warp-tunnel".serviceConfig;
      in
      assert
        sc.NoNewPrivileges
        && sc.PrivateTmp
        && sc.ProtectSystem == "strict"
        && sc.ReadWritePaths == [ "/run" ]
        && sc.ProtectKernelTunables
        && sc.ProtectControlGroups
        && sc.RestrictSUIDSGID
        && !(sc ? ProtectHome);
      true
    )
    (
      assert !(hasInfix "PrivateKey" singBoxTunnel);
      true
    )
    (
      assert hasInfix "listen_port: 18538" singBoxTunnel;
      true
    )
    # The resolver comes from proxy.dns.local; sing-box's "local" server fails behind resolved.
    (
      assert
        hasInfix ''{"server":"1.1.1.1","server_port":53,"tag":"local","type":"tcp"}'' singBoxTunnel
        && !(hasInfix ''type: "local"'' singBoxTunnel);
      true
    )
    (
      assert xray.config.systemd.services ? "proxy-suite-warp-tunnel";
      true
    )
    (
      assert !(singBox.config.systemd.services ? "proxy-suite-warp");
      true
    )
    (
      assert auto.config.systemd.services ? "proxy-suite-warp";
      true
    )
    # Before wgcf registers, the tunnel waits instead of failing its way through restarts.
    (
      assert
        hasInfix "profile=/var/lib/proxy-suite/warp/wgcf-profile.conf" autoTunnel
        && hasInfix "until [ -s \"$profile\" ]" autoTunnel;
      true
    )
    # A generator only backs up wgcf, fetched directly with the URL quoted.
    (
      assert
        hasInfix "register || register || generate" generatorRegister
        && hasInfix "'https://gen.example.com/api/warp?mode=awg2'" generatorRegister
        && !(hasInfix "generate()" autoRegister);
      true
    )
    # Registration runs as the service user; the generator is tried through the proxy last.
    (
      assert
        auto.config.systemd.services."proxy-suite-warp".serviceConfig.User == "proxy-suite-daemon"
        && hasInfix "register || register || generate || proxied generate" generatorRegister;
      true
    )
    # sing-box runs as the service user with only net_admin, under a watchdog that can tell a
    # dead uplink (the marked direct-in listener) from a silent WARP.
    (
      assert
        hasInfix "--reuid=proxy-suite-daemon" singBoxTunnel
        && hasInfix "--ambient-caps=-all,+net_admin --bounding-set" singBoxTunnel
        && hasInfix ''{type: "socks", tag: "direct-in", listen: "127.0.0.1", listen_port: 18539,'' singBoxTunnel
        # It reaches the uplink past the kill switch: a login drawn per start, never in argv.
        && hasInfix ''users: [{username: "probe", password: $ENV.DIRECT_AUTH}]'' singBoxTunnel
        && hasInfix ''{type: "direct", tag: "direct", routing_mark: ${markOf singBox}}'' singBoxTunnel;
      true
    )
    (
      assert amneziaWg.config.services.proxy-suite.amneziaWg.profiles.warp.configFile == profile;
      true
    )
    (
      assert amneziaWg.config.systemd.services ? "proxy-suite-awg-warp";
      true
    )
    (
      assert !(amneziaWg.config.systemd.services ? "proxy-suite-warp-tunnel");
      true
    )
    # The global profile starts on demand (proxy-ctl awg on warp), or at boot with autostart.
    (
      assert
        amneziaWg.config.systemd.services."proxy-suite-awg-warp".wantedBy == [ ]
        &&
          builtins.elem "multi-user.target"
            amneziaWgAutostart.config.systemd.services."proxy-suite-awg-warp".wantedBy;
      true
    )
    # endpoint replaces the profile's Endpoint at conversion; the sing-box tunnel gets it quoted.
    (
      assert
        hasInfix "--endpoint '[2606:4700:d0::a29f:c001]:500' < \"$profile\"" (tunnelOf endpointed)
        && !(hasInfix "--endpoint" singBoxTunnel);
      true
    )
    (
      assert
        amneziaWgEndpoint.config.services.proxy-suite.amneziaWg.profiles.warp.endpoint
        == "162.159.192.1:500"
        && amneziaWg.config.services.proxy-suite.amneziaWg.profiles.warp.endpoint == null;
      true
    )
    (
      assert
        builtins.attrNames (
          pkgs.lib.filterAttrs (n: _: pkgs.lib.hasPrefix "warp" n) instancesCfg.amneziaWg.profiles
        ) == [
          "warp-1"
          "warp-2"
        ];
      # warp-1 keeps the state dir a single device had; warp-2 gets one of its own.
      assert pkgs.lib.hasSuffix "/warp/wgcf-profile.conf"
        instancesCfg.amneziaWg.profiles.warp-1.configFile;
      assert pkgs.lib.hasSuffix "/warp/warp-2/wgcf-profile.conf"
        instancesCfg.amneziaWg.profiles.warp-2.configFile;
      assert instances.config.systemd.services ? proxy-suite-warp;
      assert
        instances.config.systemd.services.proxy-suite-warp-register-warp-2.serviceConfig.StateDirectory
        == "proxy-suite/warp/warp-2";
      assert builtins.elem "proxy-suite-warp-register-warp-2.service"
        instances.config.systemd.services.proxy-suite-awg-warp-2.wants;
      assert
        instancesCfg.proxy.groups.warp.outbounds == [
          "warp-1"
          "warp-2"
        ];
      assert instancesCfg.proxy.groups.warp.strategy == "failover";
      true
    )
    # sing-box tunnels: the first on the usual ports, the next on its own, with its endpoint.
    (
      assert hasInfix ''"server":"127.0.0.1","server_port":18538,"tag":"a","type":"socks"'' devicesStart;
      assert hasInfix ''"server":"127.0.0.1","server_port":18900,"tag":"b","type":"socks"'' devicesStart;
      assert hasInfix "--endpoint 162.159.193.10:500" (
        generated.readDerivation devices.config.systemd.services.proxy-suite-warp-tunnel-b.serviceConfig.ExecStart
      );
      # a has the configFile, so only b registers.
      assert !(devices.config.systemd.services ? proxy-suite-warp);
      assert devices.config.systemd.services ? proxy-suite-warp-register-b;
      true
    )
  ]
  ++ invalidAssertions;
}
