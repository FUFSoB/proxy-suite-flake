{
  pkgs,
  evalProxySuite,
  mkBadProxySuiteFixture,
  mkFailingAssertions,
}:

let
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
    fixture: "warp_outbound.py --tag warp --routing-mark ${markOf fixture} < \"$profile\"";
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
  generatorRegister = registerOf generator;

  amneziaWg = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        amneziaWg.enable = true;
        warp = {
          enable = true;
          configFile = profile;
          asAmneziaWg = true;
        };
      };
    }
  ];

  invalidAssertions = mkFailingAssertions mkBadProxySuiteFixture [
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
        hasInfix ''{"server":"1.1.1.1","server_port":53,"tag":"local","type":"udp"}'' singBoxTunnel
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
        && hasInfix ''{type: "socks", tag: "direct-in", listen: "127.0.0.1", listen_port: 18539}'' singBoxTunnel
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
  ]
  ++ invalidAssertions;
}
