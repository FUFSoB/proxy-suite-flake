{
  pkgs,
  evalProxySuite,
  mkBadProxySuiteFixture,
  mkFailingAssertions,
  mkProxyCtlDerived,
}:

let
  generated = import ./read-generated.nix;
  defaultPackages = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        amneziaWg = {
          enable = true;
          profiles.home.configFile = "/run/secrets/awg.conf";
        };
      };
    }
  ];
  awgOnly = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        amneziaWg = {
          enable = true;
          kernelModulePackage = null;
          profiles = {
            home = {
              autostart = true;
              settings = {
                addresses = [ "10.8.0.2/32" ];
                privateKeyFile = "/run/secrets/awg-private";
                obfuscationFile = "/run/secrets/awg-obfuscation.json";
                obfuscation = {
                  s1 = 12;
                  s2 = 12;
                  s3 = 12;
                  s4 = 12;
                  h1 = "100-200";
                  headerProtectionKeyFile = "/run/secrets/awg-header";
                  rekeyAfterTime = "120-180";
                };
                peers = [
                  {
                    publicKey = "public";
                    presharedKeyFile = "/run/secrets/awg-psk";
                    allowedIPs = [
                      "0.0.0.0/0"
                      "::/0"
                    ];
                    endpoint = "vpn.example.com:51820";
                    persistentKeepalive = "20-30";
                    advancedSecurity = true;
                  }
                ];
              };
            };
            work = {
              configFile = "/run/secrets/work-awg.conf";
            };
          };
        };
      };
    }
  ];
  homeService = awgOnly.config.systemd.services.proxy-suite-awg-home;
  workService = awgOnly.config.systemd.services.proxy-suite-awg-work;
  ctl = mkProxyCtlDerived awgOnly;

  sourceFixture = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        amneziaWg = {
          enable = true;
          kernelModulePackage = null;
          profiles = {
            conf.configFile = "/run/secrets/client.conf";
            file.vpnFile = "/run/secrets/client.vpn";
            inline.vpn = "vpn://ZW1iZWRkZWQ";
            nix.settings = {
              addresses = [ "10.0.0.2/32" ];
              privateKey = "inline-private";
              peers = [
                {
                  publicKey = "public";
                  allowedIPs = [ "10.0.0.1/32" ];
                }
              ];
            };
          };
        };
      };
    }
  ];

  fakeTools = pkgs.writeShellScriptBin "awg-quick" "exit 0";
  fakeUserspace = pkgs.writeShellScriptBin "amneziawg-go" "exit 0";
  fakeKernelModule = pkgs.runCommand "fake-amneziawg-module" { } ''
    mkdir -p "$out/lib/modules"
  '';
  overrideFixture = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        amneziaWg = {
          enable = true;
          toolsPackage = fakeTools;
          userspacePackage = fakeUserspace;
          kernelModulePackage = fakeKernelModule;
          profiles.home.configFile = "/run/secrets/client.conf";
        };
      };
    }
  ];

  withGlobalTun = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        proxy = {
          enable = true;
          singBox.enable = true;
          outbounds = [
            {
              tag = "primary";
              url = "http://proxy.example.com:8080";
            }
          ];
          tun.enable = true;
          tproxy.enable = true;
        };
        zapret = {
          enable = true;
          perApp.enable = true;
        };
        amneziaWg = {
          enable = true;
          kernelModulePackage = null;
          profiles.home.configFile = "/run/secrets/awg.conf";
        };
      };
    }
  ];
  withGlobalAwgService = withGlobalTun.config.systemd.services.proxy-suite-awg-home;
  withGlobalAwgStartPre = withGlobalAwgService.serviceConfig.ExecStartPre;
  withGlobalAwgBypassUp = generated.readDerivation (builtins.elemAt withGlobalAwgStartPre 1);
  withGlobalAwgBypassDown = generated.readDerivation withGlobalAwgService.serviceConfig.ExecStopPost;
in
{
  manifest = pkgs.runCommand "amneziawg-secret-manifest-check" { } ''
    ${pkgs.python3}/bin/python3 - <<'PY'
    import json
    import shlex
    from pathlib import Path

    prepare = Path("${builtins.head homeService.serviceConfig.ExecStartPre}").read_text()
    args = shlex.split(prepare)
    manifest = json.loads(Path(args[args.index("--manifest") + 1]).read_text())
    assert manifest["kind"] == "settings"
    assert manifest["settings"]["obfuscationFile"] == "/run/secrets/awg-obfuscation.json"
    assert manifest["settings"]["obfuscation"]["s1"] == 12
    assert manifest["settings"]["obfuscation"]["i1"] is None
    PY
    touch "$out"
  '';

  assertions = [
    (
      assert !awgOnly.config.services.proxy-suite.proxy.enable;
      assert homeService.serviceConfig.RuntimeDirectoryMode == "0700";
      assert homeService.serviceConfig.UMask == "0077";
      assert
        awgOnly.config.services.proxy-suite.amneziaWg.profiles.home.settings.obfuscationFile
        == "/run/secrets/awg-obfuscation.json";
      assert
        sourceFixture.config.services.proxy-suite.amneziaWg.profiles.nix.settings.obfuscationFile == null;
      assert builtins.elem "multi-user.target" homeService.wantedBy;
      assert builtins.elem "proxy-suite-awg-work.service" homeService.conflicts;
      assert builtins.elem "proxy-suite-tun.service" homeService.conflicts;
      assert builtins.elem "proxy-suite-tproxy.service" homeService.conflicts;
      assert builtins.elem "zapret-discord-youtube.service" homeService.conflicts;
      assert builtins.elem "proxy-suite-per-app-zapret.service" homeService.conflicts;
      assert workService.wantedBy == [ ];
      assert homeService.serviceConfig.NoNewPrivileges;
      assert builtins.length homeService.serviceConfig.ExecStartPre == 1;
      assert !(homeService.serviceConfig ? ExecStopPost);
      true
    )
    (
      assert builtins.elem awgOnly.config.services.proxy-suite.amneziaWg.toolsPackage
        awgOnly.config.environment.systemPackages;
      assert builtins.elem awgOnly.config.services.proxy-suite.amneziaWg.userspacePackage
        awgOnly.config.environment.systemPackages;
      assert awgOnly.config.services.proxy-suite.amneziaWg.toolsPackage.version == "3.1.20260812";
      assert awgOnly.config.services.proxy-suite.amneziaWg.userspacePackage.version == "3.1.20260828";
      assert pkgs.lib.hasInfix "cmd_awg" ctl.script;
      assert
        ctl.awgProfiles == [
          "home"
          "work"
        ];
      true
    )
    (
      assert defaultPackages.config.services.proxy-suite.amneziaWg.toolsPackage.version == "3.1.20260812";
      assert
        defaultPackages.config.services.proxy-suite.amneziaWg.userspacePackage.version == "3.1.20260828";
      assert
        defaultPackages.config.services.proxy-suite.amneziaWg.kernelModulePackage.version == "3.1.20260812";
      true
    )
    (
      assert
        sourceFixture.config.services.proxy-suite.amneziaWg.profiles.conf.configFile
        == "/run/secrets/client.conf";
      assert
        sourceFixture.config.services.proxy-suite.amneziaWg.profiles.file.vpnFile
        == "/run/secrets/client.vpn";
      assert
        sourceFixture.config.services.proxy-suite.amneziaWg.profiles.inline.vpn == "vpn://ZW1iZWRkZWQ";
      assert
        sourceFixture.config.services.proxy-suite.amneziaWg.profiles.nix.settings.privateKey
        == "inline-private";
      assert builtins.elem fakeTools overrideFixture.config.environment.systemPackages;
      assert builtins.elem fakeUserspace overrideFixture.config.environment.systemPackages;
      assert builtins.elem fakeKernelModule overrideFixture.config.boot.extraModulePackages;
      assert pkgs.lib.hasInfix "unit.indexOf(\"proxy-suite-\") === 0"
        awgOnly.config.security.polkit.extraConfig;
      true
    )
    (
      assert builtins.elem "proxy-suite-awg-home.service"
        withGlobalTun.config.systemd.services.proxy-suite-tun.conflicts;
      assert builtins.elem "proxy-suite-awg-home.service"
        withGlobalTun.config.systemd.services.proxy-suite-tproxy.conflicts;
      assert builtins.elem "proxy-suite-awg-home.service"
        withGlobalTun.config.systemd.services.zapret-discord-youtube.conflicts;
      assert builtins.elem "proxy-suite-awg-home.service"
        withGlobalTun.config.systemd.services.proxy-suite-per-app-zapret.conflicts;
      assert builtins.elem "proxy-suite-socks.service" withGlobalAwgService.after;
      assert builtins.elem "proxy-suite-socks.service" withGlobalAwgService.wants;
      assert builtins.length withGlobalAwgStartPre == 2;
      assert pkgs.lib.hasInfix "rule add" withGlobalAwgBypassUp;
      assert pkgs.lib.hasInfix "pref 8998" withGlobalAwgBypassUp;
      assert pkgs.lib.hasInfix "fwmark 2 lookup main" withGlobalAwgBypassUp;
      assert pkgs.lib.hasInfix "unable to install the AWG proxy-backend bypass rule"
        withGlobalAwgBypassUp;
      assert pkgs.lib.hasInfix "rule del" withGlobalAwgBypassDown;
      assert pkgs.lib.hasInfix "pref 8998" withGlobalAwgBypassDown;
      assert pkgs.lib.hasInfix "fwmark 2 lookup main" withGlobalAwgBypassDown;
      true
    )
  ]
  ++ mkFailingAssertions mkBadProxySuiteFixture [
    {
      enable = true;
      amneziaWg.enable = true;
    }
    {
      enable = true;
      amneziaWg = {
        enable = true;
        kernelModulePackage = null;
        profiles.home = {
          configFile = "/run/a.conf";
          vpnFile = "/run/a.vpn";
        };
      };
    }
    {
      enable = true;
      amneziaWg = {
        enable = true;
        kernelModulePackage = null;
        profiles = {
          one = {
            autostart = true;
            configFile = "/run/one.conf";
          };
          two = {
            autostart = true;
            configFile = "/run/two.conf";
          };
        };
      };
    }
    {
      enable = true;
      amneziaWg = {
        enable = true;
        kernelModulePackage = null;
        profiles = {
          one = {
            interfaceName = "awg-shared";
            configFile = "/run/one.conf";
          };
          two = {
            interfaceName = "awg-shared";
            configFile = "/run/two.conf";
          };
        };
      };
    }
    {
      enable = true;
      amneziaWg = {
        enable = true;
        kernelModulePackage = null;
        profiles.home.settings = {
          addresses = [ "10.8.0.2/32" ];
          peers = [
            {
              publicKey = "public";
              allowedIPs = [ "0.0.0.0/0" ];
            }
          ];
        };
      };
    }
    {
      enable = true;
      proxy = {
        enable = true;
        singBox.enable = true;
        outbounds = [
          {
            tag = "primary";
            url = "http://proxy.example.com:8080";
          }
        ];
        tun = {
          enable = true;
          autostart = true;
        };
      };
      amneziaWg = {
        enable = true;
        kernelModulePackage = null;
        profiles.home = {
          autostart = true;
          configFile = "/run/home.conf";
        };
      };
    }
  ];
}
