{
  pkgs,
  evalProxySuite,
  mkBadProxySuiteFixture,
  mkFailingAssertions,
}:

let
  generated = import ./read-generated.nix;
  inherit (pkgs.lib) hasInfix;

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
  convertCall =
    fixture: flag:
    "warp_outbound.py --backend ${flag} --tag warp --routing-mark ${markOf fixture} < ${pkgs.lib.escapeShellArg profile}";

  singBox = mkFixture "sing-box" { asOutbound = true; };
  singBoxStart = startOf singBox;
  xray = mkFixture "xray" { asOutbound = true; };
  xrayStart = startOf xray;
  hybrid = mkFixture "hybrid" { asOutbound = true; };
  hybridStart = startOf hybrid;
  auto = mkFixture "sing-box" {
    asOutbound = true;
    configFile = null;
  };
  autoStart = startOf auto;

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
    (
      assert hasInfix (convertCall singBox "sing-box") singBoxStart;
      true
    )
    (
      assert hasInfix "_proxy_suite_record_tag_source warp warp" singBoxStart;
      true
    )
    # The profile is read at start; the private key never reaches the store.
    (
      assert !(hasInfix "PrivateKey" singBoxStart);
      true
    )
    (
      assert hasInfix (convertCall xray "xray") xrayStart;
      true
    )
    (
      assert hasInfix (convertCall hybrid "sing-box") hybridStart;
      true
    )
    (
      assert hasInfix "_proxy_suite_add_sing_box_ob \"$OB_JSON\"" hybridStart;
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
    (
      assert hasInfix "if [ -s /var/lib/proxy-suite/warp/wgcf-profile.conf ]" autoStart;
      true
    )
    (
      assert hasInfix "OB_JSON='{\"type\":\"block\",\"tag\":\"warp\"}'" autoStart;
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
  ]
  ++ invalidAssertions;
}
