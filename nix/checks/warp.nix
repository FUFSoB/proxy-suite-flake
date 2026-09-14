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

  singBox = mkFixture "sing-box" { asOutbound = true; };
  singBoxStart = startOf singBox;
  singBoxTunnel = tunnelOf singBox;
  xray = mkFixture "xray" { asOutbound = true; };
  xrayStart = startOf xray;
  hybrid = mkFixture "hybrid" { asOutbound = true; };
  hybridStart = startOf hybrid;
  auto = mkFixture "sing-box" {
    asOutbound = true;
    configFile = null;
  };
  autoTunnel = tunnelOf auto;

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
        asOutbound = true;
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
    # Tag collision with a declared outbound.
    {
      enable = true;
      warp = {
        enable = true;
        configFile = profile;
        asOutbound = true;
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
      assert hasInfix singBoxHop hybridStart && hasInfix "_proxy_suite_add_sing_box_ob \"$OB_JSON\"" hybridStart;
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
