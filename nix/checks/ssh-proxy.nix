{
  pkgs,
  evalProxySuite,
  baseModule,
  mkRoutingRules,
  mkBadProxySuiteFixture,
  mkFailingAssertions,
}:

let
  generated = import ./read-generated.nix;

  sshOnlySingBox = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        sshProxy = {
          enable = true;
          user = "root";
          host = "ssh.example.com";
          asOutbound = true;
          identityFile = "/run/secrets/ssh-key";
          knownHostsFile = "/run/secrets/ssh-known-hosts";
          extraArgs = [
            "-o"
            "ServerAliveInterval=30"
          ];
        };
        proxy = {
          enable = true;
          singBox.enable = true;
        };
      };
    }
  ];
  sshOnlySingBoxStart = generated.readDerivation (
    sshOnlySingBox.config.systemd.services."proxy-suite-socks".serviceConfig.ExecStart
  );
  sshService = sshOnlySingBox.config.systemd.services."proxy-suite-ssh-proxy";
  sshStartScript = generated.readDerivation sshService.serviceConfig.ExecStart;

  unchanged = evalProxySuite [ baseModule ];
  unchangedStart = generated.readDerivation (
    unchanged.config.systemd.services."proxy-suite-socks".serviceConfig.ExecStart
  );

  sshXray = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        sshProxy = {
          enable = true;
          user = "proxy";
          host = "ssh.example.com";
          asOutbound = true;
        };
        proxy = {
          enable = true;
          xray.enable = true;
        };
      };
    }
  ];
  sshXrayStart = generated.readDerivation (
    sshXray.config.systemd.services."proxy-suite-socks".serviceConfig.ExecStart
  );

  sshHybrid = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        sshProxy = {
          enable = true;
          user = "proxy";
          host = "ssh.example.com";
          asOutbound = true;
        };
        proxy = {
          enable = true;
          singBox.enable = true;
          xray.enable = true;
        };
      };
    }
  ];
  sshHybridStart = generated.readDerivation (
    sshHybrid.config.systemd.services."proxy-suite-socks".serviceConfig.ExecStart
  );

  sshSelector = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        sshProxy = {
          enable = true;
          user = "proxy";
          host = "ssh.example.com";
          asOutbound = true;
        };
        proxy = {
          enable = true;
          singBox.enable = true;
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
  sshSelectorStart = generated.readDerivation (
    sshSelector.config.systemd.services."proxy-suite-socks".serviceConfig.ExecStart
  );

  sshUrltest = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        sshProxy = {
          enable = true;
          user = "proxy";
          host = "ssh.example.com";
          asOutbound = true;
        };
        proxy = {
          enable = true;
          xray.enable = true;
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
  sshUrltestStart = generated.readDerivation (
    sshUrltest.config.systemd.services."proxy-suite-socks".serviceConfig.ExecStart
  );

  sshRouting = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        sshProxy = {
          enable = true;
          user = "proxy";
          host = "ssh.example.com";
          asOutbound = true;
        };
        proxy = {
          enable = true;
          singBox.enable = true;
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
        user = "proxy";
        host = "ssh.example.com";
        asOutbound = true;
      };
    }
    {
      enable = true;
      sshProxy = {
        enable = true;
        asOutbound = true;
      };
      proxy = {
        enable = true;
        singBox.enable = true;
      };
    }
    {
      enable = true;
      sshProxy = {
        enable = true;
        user = "proxy";
        host = "ssh.example.com";
        asOutbound = true;
      };
      proxy = {
        enable = true;
        singBox.enable = true;
        outbounds = [
          {
            tag = "ssh-proxy";
            url = "http://proxy.example.com:8080";
          }
        ];
      };
    }
  ];

  assertions = [
    (
      assert sshOnlySingBox.config.services.proxy-suite.proxy.outbounds == [ ];
      true
    )
    (
      assert sshOnlySingBox.config.systemd.services ? "proxy-suite-ssh-proxy";
      true
    )
    (
      assert
        sshOnlySingBox.config.systemd.services."proxy-suite-socks".after == [
          "network-online.target"
          "proxy-suite-ssh-proxy.service"
        ];
      true
    )
    (
      assert pkgs.lib.hasInfix "ssh-proxy" sshOnlySingBoxStart;
      true
    )
    (
      assert pkgs.lib.hasInfix "proxy-suite-ob-ssh-proxy-sing-box.json" sshOnlySingBoxStart;
      true
    )
    (
      assert pkgs.lib.hasInfix "ServerAliveInterval=30" sshStartScript;
      true
    )
    (
      assert !(sshService.serviceConfig ? SocketMark);
      true
    )
    (
      assert !(unchanged.config.systemd.services ? "proxy-suite-ssh-proxy");
      true
    )
    (
      assert !(pkgs.lib.hasInfix "ssh-proxy" unchangedStart);
      true
    )
    (
      assert sshXray.config.systemd.services."proxy-suite-socks".serviceConfig.ExecStart != null;
      true
    )
    (
      assert pkgs.lib.hasInfix "proxy-suite-ob-ssh-proxy-xray.json" sshXrayStart;
      true
    )
    (
      assert pkgs.lib.hasInfix "_proxy_suite_add_sing_box_ob" sshHybridStart;
      true
    )
    (
      assert pkgs.lib.hasInfix "selector" sshSelectorStart;
      true
    )
    (
      assert pkgs.lib.hasInfix "ssh-proxy" sshSelectorStart;
      true
    )
    (
      assert pkgs.lib.hasInfix "proxy-suite-ob-ssh-proxy-xray.json" sshUrltestStart;
      true
    )
    (
      assert builtins.any (rule: (rule.outbound or null) == "ssh-proxy") (mkRoutingRules sshRouting);
      true
    )
  ]
  ++ invalidAssertions;
in
{
  inherit assertions;
}
