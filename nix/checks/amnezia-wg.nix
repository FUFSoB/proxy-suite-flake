{
  checkLib,
  pkgs,
  evalProxySuite,
  mkBadProxySuiteFixture,
  mkFailingAssertions,
  rejectsProxySuite,
  mkProxyCtlDerived,
}:

let
  inherit (checkLib) mkProxySuite;
  generated = import ./read-generated.nix;
  defaultPackages = mkProxySuite {
    enable = true;
    amneziaWg = {
      enable = true;
      profiles.home.configFile = "/run/secrets/awg.conf";
    };
  };
  awgOnly = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        userControl.enable = true;
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
  awgOnlyNoRuntime = mkProxySuite {
    enable = true;
    amneziaWg = {
      enable = true;
      kernelModulePackage = null;
      runtime.enable = false;
      profiles.home.configFile = "/run/secrets/awg.conf";
    };
  };
  workService = awgOnly.config.systemd.services.proxy-suite-awg-work;
  ctl = mkProxyCtlDerived awgOnly;
  homeWatchdog = awgOnly.config.systemd.services.proxy-suite-awg-home-watchdog;
  homeWatchdogScript = generated.readDerivation homeWatchdog.serviceConfig.ExecStart;
  homeStart = generated.readDerivation homeService.serviceConfig.ExecStart;

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
  overrideFixture = mkProxySuite {
    enable = true;
    amneziaWg = {
      enable = true;
      toolsPackage = fakeTools;
      userspacePackage = fakeUserspace;
      kernelModulePackage = fakeKernelModule;
      profiles.home.configFile = "/run/secrets/client.conf";
    };
  };

  withGlobalTun = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        proxy = {
          enable = true;
          backend = "sing-box";
          outbounds = [
            {
              tag = "primary";
              url = "http://proxy.example.com:8080";
            }
          ];
          tun.enable = true;
          tproxy.enable = true;
        };
        zapret.enable = true;
        perAppRouting.zapret.enable = true;
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
  withGlobalAwgBypassUp = generated.readDerivation (builtins.elemAt withGlobalAwgStartPre 2);

  # Nothing declared: every profile and AmneziaWG outbound comes from proxy-ctl.
  runtimeOnly = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        killSwitch.enable = true;
        userControl = {
          enable = true;
          scopes = [ "amneziaWg" ];
        };
        proxy = {
          enable = true;
          backend = "sing-box";
          outbounds = [
            {
              tag = "primary";
              url = "http://proxy.example.com:8080";
            }
          ];
        };
        amneziaWg = {
          enable = true;
          kernelModulePackage = null;
        };
      };
    }
  ];
  runtimeUnits = runtimeOnly.config.systemd.services;

  # The scripts that list units, run against a systemctl that lists what the check says.
  stubSystemctl = pkgs.writeShellScript "systemctl" ''
    echo "$*" >> "$SYSTEMCTL_LOG"
    if [ "$1" = list-units ]; then cat "$UNITS"; fi
  '';
  stubbed = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        host.systemctl = pkgs.lib.mkForce "${stubSystemctl}";
        proxy = {
          enable = true;
          backend = "sing-box";
          outbounds = [
            {
              tag = "primary";
              url = "http://proxy.example.com:8080";
            }
          ];
        };
        amneziaWg = {
          enable = true;
          kernelModulePackage = null;
          profiles.home.configFile = "/run/secrets/awg.conf";
        };
      };
    }
  ];
  stubbedUnits = stubbed.config.systemd.services;
  runtimeTemplate = runtimeUnits."proxy-suite-awg@";
  runtimeTunnel = runtimeUnits."proxy-suite-awg-tunnel@";
  runtimeSync = generated.readDerivation runtimeUnits.proxy-suite-awg-runtime-sync.serviceConfig.ExecStart;
  runtimeKillSwitchRules = checkLib.mkNftRules runtimeOnly "killSwitchRulesFile";
  runtimeCtl = mkProxyCtlDerived runtimeOnly;
  runtimeOutboundScript = generated.readDerivation runtimeUnits.proxy-suite-socks.serviceConfig.ExecStart;
  withGlobalAwgBypassDown = generated.readDerivation withGlobalAwgService.serviceConfig.ExecStopPost;
in
{
  # Nothing listed is no failure (grep finding nothing, under pipefail, once was); what is
  # listed is stopped, a failed unit's glyph and all, but never the unit itself.
  unitScripts = pkgs.runCommand "amneziawg-unit-scripts-check" { } ''
    export SYSTEMCTL_LOG=$PWD/log UNITS=$PWD/units
    stop=${builtins.elemAt stubbedUnits.proxy-suite-awg-home.serviceConfig.ExecStartPre 1}
    sync=${stubbedUnits.proxy-suite-awg-runtime-sync.serviceConfig.ExecStart}

    : > units
    $stop
    $stop self
    $sync
    ! grep -q '^stop' log

    printf '%s\n' \
      '● proxy-suite-awg@gone.service loaded failed failed x' \
      '  proxy-suite-awg@self.service loaded active exited x' > units
    : > log
    $stop self
    grep -qx 'stop proxy-suite-awg@gone.service' log
    ! grep -q 'stop proxy-suite-awg@self.service' log

    printf '%s\n' '● proxy-suite-awg-tunnel@old.service loaded failed failed x' \
      '  proxy-suite-awg-if@gone.service loaded active exited x' > units
    : > log
    $sync
    grep -qx 'stop --no-block proxy-suite-awg-tunnel@old.service' log
    grep -qx 'stop --no-block proxy-suite-awg-if@gone.service' log
    touch "$out"
  '';

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
      assert builtins.elem "proxy-suite-zapret.service" homeService.conflicts;
      assert builtins.elem "proxy-suite-per-app-zapret.service" homeService.conflicts;
      assert workService.wantedBy == [ ];
      assert homeService.serviceConfig.NoNewPrivileges;
      # Rendering, then stopping any profile added at runtime: they share an interface.
      assert builtins.length homeService.serviceConfig.ExecStartPre == 2;
      assert pkgs.lib.hasInfix "proxy-suite-awg@*.service" (
        generated.readDerivation (builtins.elemAt homeService.serviceConfig.ExecStartPre 1)
      );
      assert !(homeService.serviceConfig ? ExecStopPost);
      # A silent handshake moves the interface to a new port: at start, and from the watchdog.
      assert pkgs.lib.hasInfix "set \"$interface\" listen-port 0" homeStart;
      assert pkgs.lib.hasInfix "--inspect" homeStart;
      assert homeWatchdog.bindsTo == [ "proxy-suite-awg-home.service" ];
      assert homeWatchdog.wantedBy == [ "proxy-suite-awg-home.service" ];
      assert pkgs.lib.hasInfix "rekey + 10" homeWatchdogScript;
      true
    )
    (
      assert builtins.elem awgOnly.config.services.proxy-suite.amneziaWg.toolsPackage
        awgOnly.config.environment.systemPackages;
      assert builtins.elem awgOnly.config.services.proxy-suite.amneziaWg.userspacePackage
        awgOnly.config.environment.systemPackages;
      assert pkgs.lib.versionAtLeast awgOnly.config.services.proxy-suite.amneziaWg.toolsPackage.version
        "3.1";
      assert pkgs.lib.versionAtLeast
        awgOnly.config.services.proxy-suite.amneziaWg.userspacePackage.version
        "3.1";
      assert pkgs.lib.hasInfix "cmd_awg" ctl.script;
      assert
        ctl.awgProfiles == [
          "home"
          "work"
        ];
      true
    )
    (
      assert pkgs.lib.versionAtLeast
        defaultPackages.config.services.proxy-suite.amneziaWg.toolsPackage.version
        "3.1";
      assert pkgs.lib.versionAtLeast
        defaultPackages.config.services.proxy-suite.amneziaWg.userspacePackage.version
        "3.1";
      assert pkgs.lib.versionAtLeast
        defaultPackages.config.services.proxy-suite.amneziaWg.kernelModulePackage.version
        "3.1";
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
      # userControl covers the profile's unit by name, never by prefix: a prefix would also
      # match a transient unit (systemd-run --unit=proxy-suite-x), which runs anything as root.
      assert pkgs.lib.hasInfix "\"proxy-suite-awg-home.service\""
        awgOnly.config.security.polkit.extraConfig;
      assert
        !(pkgs.lib.hasInfix "unit.indexOf(\"proxy-suite-\") === 0" awgOnly.config.security.polkit.extraConfig);
      true
    )
    (
      assert builtins.elem "proxy-suite-awg-home.service"
        withGlobalTun.config.systemd.services.proxy-suite-tun.conflicts;
      assert builtins.elem "proxy-suite-awg-home.service"
        withGlobalTun.config.systemd.services.proxy-suite-tproxy.conflicts;
      assert builtins.elem "proxy-suite-awg-home.service"
        withGlobalTun.config.systemd.services.proxy-suite-zapret.conflicts;
      assert builtins.elem "proxy-suite-awg-home.service"
        withGlobalTun.config.systemd.services.proxy-suite-per-app-zapret.conflicts;
      assert builtins.elem "proxy-suite-socks.service" withGlobalAwgService.after;
      assert builtins.elem "proxy-suite-socks.service" withGlobalAwgService.wants;
      assert builtins.length withGlobalAwgStartPre == 3;
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
    # Profiles added with proxy-ctl: a template sharing one interface, which the kill switch
    # knows; a tunnel template per outbound, started by a sync unit the reload pulls in.
    (
      assert runtimeTemplate.wantedBy == [ ];
      assert builtins.elem "proxy-suite-awg-watchdog@%i.service" runtimeTemplate.wants;
      assert builtins.elem "proxy-suite-killswitch.service" runtimeTemplate.before;
      assert builtins.elem "proxy-suite-killswitch.service" runtimeTemplate.wants;
      assert builtins.elem "proxy-suite-tun.service" runtimeTemplate.conflicts;
      assert runtimeTemplate.serviceConfig.Group == "proxy-suite-awg";
      assert runtimeTemplate.serviceConfig.RuntimeDirectory == "proxy-suite-awg-rt-%i";
      assert pkgs.lib.hasSuffix " %i" runtimeTemplate.serviceConfig.ExecStart;
      assert builtins.all (pkgs.lib.hasSuffix " %i") (
        pkgs.lib.take 2 runtimeTemplate.serviceConfig.ExecStartPre
      );
      assert runtimeUnits."proxy-suite-awg-watchdog@".bindsTo == [ "proxy-suite-awg@%i.service" ];
      assert runtimeUnits."proxy-suite-awg-watchdog@".wantedBy == [ ];
      assert runtimeTunnel.wantedBy == [ ];
      assert runtimeTunnel.serviceConfig.Restart == "on-failure";
      assert runtimeTunnel.serviceConfig.RuntimeDirectory == "proxy-suite-awg-tunnel-%i";
      assert builtins.elem "proxy-suite-outbound-reload.service"
        runtimeUnits.proxy-suite-awg-runtime-sync.wantedBy;
      assert pkgs.lib.hasInfix "proxy-suite-awg-$kind@$tag.service" runtimeSync;
      assert pkgs.lib.hasInfix "[[ -e /var/lib/proxy-suite/outbounds.d/$tag.iface ]] && kind=if"
        runtimeSync;
      # Or, with <tag>.iface, an interface of its own: a template like the global one's,
      # behind a direct outbound bound to it.
      assert runtimeUnits."proxy-suite-awg-if@".wantedBy == [ ];
      assert runtimeUnits."proxy-suite-awg-if@".serviceConfig.RuntimeDirectory == "proxy-suite-awg-if-%i";
      assert builtins.elem "proxy-suite-awg-if-watchdog@%i.service"
        runtimeUnits."proxy-suite-awg-if@".wants;
      assert runtimeUnits."proxy-suite-awg-if-watchdog@".bindsTo == [ "proxy-suite-awg-if@%i.service" ];
      assert pkgs.lib.hasInfix "_proxy_suite_add_awg_interface" runtimeOutboundScript;
      assert pkgs.lib.hasInfix ''bind_interface: $i, domain_resolver: ("awg-dns-" + $t)''
        runtimeOutboundScript;
      assert runtimeCtl.wrapperEnv.AWG_RUNTIME_IFACE_OUTBOUNDS == "1";
      assert runtimeCtl.wrapperEnv.AWG_RUNTIME_OUTBOUND_KIND == "userspace";
      # The backend dials each one's tunnel on the port in <tag>.port.
      assert pkgs.lib.hasInfix ''"/var/lib/proxy-suite/outbounds.d"/*.awg'' runtimeOutboundScript;
      assert pkgs.lib.hasInfix "_proxy_suite_add_socks_hop" runtimeOutboundScript;
      assert pkgs.lib.hasInfix ''oifname { "awg-rt" } accept'' runtimeKillSwitchRules;
      assert pkgs.lib.hasInfix ''meta skgid "proxy-suite-awg" accept'' runtimeKillSwitchRules;
      assert builtins.elem "d /var/lib/proxy-suite/amneziawg.d 2775 root proxy-suite -"
        runtimeOnly.config.systemd.tmpfiles.rules;
      assert builtins.elem "d /var/lib/proxy-suite/outbounds.d 0700 root root -"
        runtimeOnly.config.systemd.tmpfiles.rules;
      assert builtins.elem runtimeOnly.config.services.proxy-suite.amneziaWg.wireproxyPackage
        runtimeOnly.config.environment.systemPackages;
      assert pkgs.lib.hasInfix "proxy-suite-awg-tunnel@" runtimeOnly.config.security.polkit.extraConfig;
      assert runtimeCtl.wrapperEnv.AWG_RUNTIME_GLOBAL == "1";
      assert runtimeCtl.wrapperEnv.AWG_RUNTIME_OUTBOUNDS == "1";
      assert runtimeCtl.wrapperEnv.AWG_RUNTIME_DIR == "/var/lib/proxy-suite/amneziawg.d";
      assert pkgs.lib.hasSuffix "/amneziawg_config.py" runtimeCtl.wrapperEnv.AWG_CONFIG_TOOL;
      assert runtimeCtl.awgProfiles == [ ];
      # Declared profiles only in a configuration that turns the runtime ones off.
      assert !(awgOnlyNoRuntime.config.systemd.services ? "proxy-suite-awg@");
      assert
        builtins.length awgOnlyNoRuntime.config.systemd.services.proxy-suite-awg-home.serviceConfig.ExecStartPre
        == 1;
      true
    )
  ]
  ++ mkFailingAssertions mkBadProxySuiteFixture [
    {
      enable = true;
      amneziaWg = {
        enable = true;
        runtime.enable = false;
      };
    }
    {
      enable = true;
      amneziaWg = {
        enable = true;
        kernelModulePackage = null;
        profiles.home = {
          interfaceName = "awg-rt";
          configFile = "/run/home.conf";
        };
      };
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
  ]
  # An AmneziaWG profile and a global proxy mode both autostarting. Message-matched: with
  # `proxy.tun.autostart` (removed) this case used to fail on the option name instead.
  ++ [
    (rejectsProxySuite "at most one AmneziaWG, TUN, or TProxy global mode may autostart" {
      enable = true;
      proxy = {
        enable = true;
        backend = "sing-box";
        outbounds = [
          {
            tag = "primary";
            url = "http://proxy.example.com:8080";
          }
        ];
        tun.enable = true;
        autostart = "tun";
      };
      amneziaWg = {
        enable = true;
        kernelModulePackage = null;
        profiles.home = {
          autostart = true;
          configFile = "/run/home.conf";
        };
      };
    })
  ];
}
