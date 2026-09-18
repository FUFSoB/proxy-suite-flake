{
  checkLib,
  pkgs,
  evalProxySuite,
  mkBadProxySuiteFixture,
  mkFailingAssertions,
  mkProxyCtlDerived,
  mkTProxyConfig,
  dnsServerByTag,
}:

let
  inherit (checkLib) mkProxySuite;
  generated = import ./read-generated.nix;
  inherit (pkgs.lib) hasInfix;

  mkFixture =
    backend:
    evalProxySuite [
      {
        system.stateVersion = "26.05";
        services.proxy-suite = {
          enable = true;
          proxy = {
            enable = true;
            inherit backend;
            tproxy.enable = true;
          };
          amneziaWg = {
            enable = true;
            kernelModulePackage = null;
            profiles = {
              de = {
                asOutbound = "interface";
                configFile = "/run/secrets/de.conf";
              };
              plain = {
                asOutbound = "singBox";
                configFile = "/run/secrets/plain.conf";
              };
              home.configFile = "/run/secrets/home.conf";
            };
          };
        };
      }
    ];
  singBox = mkFixture "sing-box";
  xray = mkFixture "xray";
  hybrid = mkFixture "hybrid";
  services = singBox.config.systemd.services;
  startOf =
    fixture:
    generated.readDerivation fixture.config.systemd.services.proxy-suite-socks.serviceConfig.ExecStart;
  singBoxStart = startOf singBox;

  de = services.proxy-suite-awg-de;
  dePrepare = generated.readDerivation (builtins.head de.serviceConfig.ExecStartPre);
  deStart = generated.readDerivation de.serviceConfig.ExecStart;
  plainTunnel = generated.readDerivation services.proxy-suite-awg-plain.serviceConfig.ExecStart;
  dnsServer = dnsServerByTag (mkTProxyConfig singBox) "awg-dns-de";

  warpInterface = mkProxySuite {
    enable = true;
    proxy.enable = true;
    amneziaWg.enable = true;
    warp = {
      enable = true;
      configFile = "/run/secrets/wgcf-profile.conf";
      asOutbound = "interface";
    };
  };
in
{
  assertions = [
    # "interface": the backend binds to the device and resolves through it.
    (
      assert hasInfix
        ''"bind_interface":"awg-de","domain_resolver":"awg-dns-de","routing_mark":2,"tag":"de","type":"direct"''
        singBoxStart;
      assert hasInfix "_proxy_suite_record_tag_source de awg" singBoxStart;
      assert
        dnsServer == {
          tag = "awg-dns-de";
          type = "udp";
          server = "1.1.1.1";
          server_port = 53;
          bind_interface = "awg-de";
          routing_mark = 2;
        };
      assert hasInfix
        ''"protocol":"freedom","streamSettings":{"sockopt":{"interface":"awg-de","mark":2}},"tag":"de"''
        (startOf xray);
      assert
        hasInfix "_proxy_suite_add_sing_box_ob" (startOf hybrid)
        && hasInfix ''"bind_interface":"awg-de"'' (startOf hybrid);
      true
    )
    # "interface": no routes, no bypass rule, no conflicts, always running.
    (
      assert hasInfix "--outbound-fwmark 2" dePrepare;
      assert builtins.length de.serviceConfig.ExecStartPre == 1;
      assert !(de.serviceConfig ? ExecStopPost);
      assert (de.conflicts or [ ]) == [ ];
      assert builtins.elem "multi-user.target" de.wantedBy;
      assert de.serviceConfig.Restart == "on-failure";
      assert hasInfix "ping -n -c 1 -I awg-de" deStart;
      assert !(builtins.elem "proxy-suite-awg-de.service" services.proxy-suite-tproxy.conflicts);
      assert builtins.elem "proxy-suite-awg-home.service" services.proxy-suite-tproxy.conflicts;
      assert !(builtins.elem "proxy-suite-awg-de.service" services.proxy-suite-awg-home.conflicts);
      assert hasInfix ''iifname "awg-de" accept''
        singBox.config.networking.firewall.extraReversePathFilterRules;
      assert (mkProxyCtlDerived singBox).awgProfiles == [ "home" ];
      true
    )
    # "singBox": a tunnel unit behind a loopback SOCKS hop, fed the prepared profile.
    (
      assert hasInfix ''"server":"127.0.0.1","server_port":18602,"tag":"plain","type":"socks"''
        singBoxStart;
      assert hasInfix "_proxy_suite_record_tag_source plain awg" singBoxStart;
      assert hasInfix "--output \"$profile\"" plainTunnel && !(hasInfix "--outbound-fwmark" plainTunnel);
      assert hasInfix "warp_outbound.py --tag plain --routing-mark 2" plainTunnel;
      assert hasInfix "listen_port: 18602" plainTunnel;
      assert hasInfix ''detour: "plain"'' plainTunnel;
      assert !(services ? proxy-suite-awg-plain-watchdog);
      true
    )
    # warp.asOutbound = "interface" is the AmneziaWG profile, not the sing-box tunnel.
    (
      assert warpInterface.config.services.proxy-suite.amneziaWg.profiles.warp.asOutbound == "interface";
      assert !(warpInterface.config.systemd.services ? proxy-suite-warp-tunnel);
      assert hasInfix ''"bind_interface":"awg-warp"'' (startOf warpInterface);
      true
    )
  ]
  ++ mkFailingAssertions mkBadProxySuiteFixture [
    # An outbound profile without a backend.
    {
      enable = true;
      amneziaWg = {
        enable = true;
        profiles.de = {
          asOutbound = "interface";
          configFile = "/run/de.conf";
        };
      };
    }
    # An outbound profile always runs.
    {
      enable = true;
      proxy.enable = true;
      amneziaWg = {
        enable = true;
        profiles.de = {
          asOutbound = "singBox";
          autostart = true;
          configFile = "/run/de.conf";
        };
      };
    }
    # Routes for an interface that must have none.
    {
      enable = true;
      proxy.enable = true;
      amneziaWg = {
        enable = true;
        profiles.de = {
          asOutbound = "interface";
          settings = {
            addresses = [ "10.0.0.2/32" ];
            privateKey = "private";
            table = "auto";
            peers = [
              {
                publicKey = "public";
                allowedIPs = [ "0.0.0.0/0" ];
              }
            ];
          };
        };
      };
    }
    # warp.asOutbound = "interface" without AmneziaWG.
    {
      enable = true;
      proxy.enable = true;
      warp = {
        enable = true;
        configFile = "/run/wgcf.conf";
        asOutbound = "interface";
      };
    }
    # A profile tag colliding with a declared outbound.
    {
      enable = true;
      proxy = {
        enable = true;
        outbounds = [
          {
            tag = "de";
            url = "http://proxy.example.com:8080";
          }
        ];
      };
      amneziaWg = {
        enable = true;
        profiles.de = {
          asOutbound = "singBox";
          configFile = "/run/de.conf";
        };
      };
    }
  ];
}
