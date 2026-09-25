# The home-manager, system-manager and nix-on-droid adapters, evaluated against stubs of
# the options each host framework declares: the frameworks stay out of the flake lock,
# and the adapters only use option names they share with these stubs.
{
  pkgs,
  proxySuiteModules,
  mkTProxyConfig,
  mkInboundsConfig,
}:

let
  lib = pkgs.lib;
  inherit (lib) mkOption types;

  stub = type: default: mkOption { inherit type default; };
  anyAttrs = stub (types.attrsOf types.anything) { };
  packages = stub (types.listOf types.package) [ ];
  strings = stub (types.listOf types.str) [ ];
  etc = stub (types.attrsOf (
    types.submodule {
      freeformType = types.attrsOf types.anything;
      options.text = stub (types.nullOr types.lines) null;
    }
  )) { };

  common = {
    options = {
      assertions = stub (types.listOf types.unspecified) [ ];
      warnings = strings;
    };
    config._module.args.pkgs = pkgs;
  };

  hostStubs = {
    homeManager.options = {
      lib = stub (types.attrsOf types.attrs) { };
      home.packages = packages;
      xdg.stateHome = stub types.str "/home/u/.local/state";
      xdg.cacheHome = stub types.str "/home/u/.cache";
      systemd.user = {
        services = anyAttrs;
        timers = anyAttrs;
        paths = anyAttrs;
        tmpfiles.rules = strings;
      };
    };

    systemManager.options = {
      systemd =
        let
          units = stub (types.attrsOf (types.submodule { freeformType = types.attrsOf types.anything; })) { };
        in
        {
          services = units;
          timers = units;
          paths = units;
          tmpfiles.rules = strings;
        };
      environment.systemPackages = packages;
      environment.etc = etc;
      users.users = anyAttrs;
      users.groups = anyAttrs;
      networking.enableIPv6 = stub types.bool true;
      networking.firewall.allowedTCPPorts = stub (types.listOf types.port) [ ];
      networking.firewall.allowedUDPPorts = stub (types.listOf types.port) [ ];
    };

    nixOnDroid.options = {
      user.home = stub types.str "/data/data/com.termux.nix/files/home";
      environment.packages = packages;
      environment.etc = etc;
      build.activationAfter = stub (types.attrsOf types.str) { };
    };
  };

  evalHost =
    host: modules:
    lib.evalModules {
      modules = [
        common
        hostStubs.${host}
        proxySuiteModules.${host}
      ]
      ++ modules;
    };
  failedAssertions =
    fixture: map (a: a.message) (lib.filter (a: !a.assertion) fixture.config.assertions);
  # Through JSON: derivations stop at their store paths, which is where the scripts get built.
  forced = value: builtins.isString (builtins.toJSON value);

  proxy = {
    enable = true;
    listener.port = 1080;
    outbounds = [
      {
        tag = "primary";
        url = "http://proxy.example.com:8080";
      }
    ];
  };

  # What a rootless host can run.
  rootlessSettings = {
    services.proxy-suite = {
      enable = true;
      inherit proxy;
      tgWsProxy = {
        enable = true;
        secretFile = "/run/secrets/tg";
      };
      warp = {
        enable = true;
        asOutbound = "singBox";
      };
      tor = {
        enable = true;
        asOutbound = true;
        onionService.enable = true;
      };
      perAppRouting = {
        enable = true;
        proxychains.enable = true;
      };
      inbounds = {
        enable = true;
        listeners.vless = {
          type = "vless";
          port = 8443;
          users = [ { uuidFile = "/run/secrets/uuid"; } ];
          tls.certificateFile = "/c";
          tls.keyFile = "/k";
        };
      };
      whitelistBypass = {
        enable = true;
        joiners.wl = {
          platform = "wbstream";
          linkFile = "/run/secrets/wb-link";
        };
        creators.phone = {
          platform = "dion";
          cookiesFile = "/run/secrets/wb-cookies";
          upstream = "proxy";
        };
      };
    };
  };

  homeManager = evalHost "homeManager" [ rootlessSettings ];
  hmCfg = homeManager.config;
  hmSocksConfig = mkTProxyConfig homeManager;
  hmInboundsConfig = mkInboundsConfig homeManager;

  systemManager = evalHost "systemManager" [
    {
      services.proxy-suite = {
        enable = true;
        proxy = proxy // {
          tproxy.enable = true;
        };
        gui.enable = true;
        userControl.enable = true;
      };
    }
  ];
  smCfg = systemManager.config;

  nixOnDroid = evalHost "nixOnDroid" [ rootlessSettings ];
  nodCfg = nixOnDroid.config;

  rejects =
    host: settings: message:
    lib.any (lib.hasInfix message) (
      failedAssertions (
        evalHost host [
          rootlessSettings
          { services.proxy-suite = settings; }
        ]
      )
    );
in
{
  assertions = [
    (
      assert failedAssertions homeManager == [ ];
      assert hmCfg.services.proxy-suite.host.serviceManager == "systemd-user";
      assert lib.hasPrefix "/home/u/.local/state/" hmCfg.services.proxy-suite.host.stateDir;
      assert hmCfg.systemd.user.services ? proxy-suite-socks;
      # The helpers are published where home-manager keeps its own.
      assert hmCfg.lib.proxy-suite.urls.http == "http://127.0.0.1:1080";
      assert hmCfg.systemd.user.services ? proxy-suite-inbounds;
      assert hmCfg.systemd.user.services ? proxy-suite-tor;
      # Rootless, there is no userControl group to hand the control socket to.
      assert !(hmCfg.systemd.user.services.proxy-suite-tor.Service ? Group);
      assert forced hmCfg.systemd.user.services;
      # No setpriv on a user manager: nothing to drop to.
      assert
        !(lib.hasInfix "setpriv" (
          toString hmCfg.systemd.user.services.proxy-suite-socks.Service.ExecStart
        ));
      true
    )
    (
      # Rootless, the socks unit only listens: no TProxy inbound, no SO_MARK.
      assert lib.any (inbound: inbound.type == "mixed") hmSocksConfig.inbounds;
      assert !(lib.any (inbound: inbound.type == "tproxy") hmSocksConfig.inbounds);
      assert !(lib.any (outbound: outbound ? routing_mark) hmSocksConfig.outbounds);
      assert !(lib.any (outbound: outbound ? routing_mark) (hmInboundsConfig.outbounds or [ ]));
      true
    )
    (
      assert failedAssertions systemManager == [ ];
      assert smCfg.services.proxy-suite.host.privileged;
      assert
        smCfg.systemd.services.proxy-suite-socks.serviceConfig.SyslogIdentifier == "proxy-suite-socks";
      assert smCfg.systemd.services ? proxy-suite-tproxy;
      assert smCfg.environment.etc ? "polkit-1/rules.d/50-proxy-suite.rules";
      assert smCfg.environment.etc ? "systemd/user/proxy-suite-gui.service";
      assert forced smCfg.systemd.services;
      true
    )
    (
      assert failedAssertions nixOnDroid == [ ];
      assert nodCfg.services.proxy-suite.host.serviceManager == "supervisor";
      assert lib.hasSuffix "/bin/proxy-suitectl" nodCfg.services.proxy-suite.host.systemctl;
      assert lib.any (p: lib.getName p == "proxy-suitectl") nodCfg.environment.packages;
      assert lib.hasInfix "proxy-suitectl boot" nodCfg.build.activationAfter.proxySuite;
      assert lib.hasInfix "proxy-suitectl ensure" nodCfg.environment.etc.profile.text;
      assert forced nodCfg.build.activationAfter.proxySuite;
      assert nodCfg.services.proxy-suite.internal.services.proxy-suite-tor.enable;
      assert nodCfg.services.proxy-suite.internal.services.proxy-suite-wb-joiner-wl.enable;
      assert nodCfg.services.proxy-suite.internal.services.proxy-suite-wb-creator-phone.enable;
      # Android bans apps from netlink's route groups, which stock sing-box subscribes to.
      assert nodCfg.services.proxy-suite.proxy.singBox.package.passthru.rootlessNetlink or false;
      assert !(hmCfg.services.proxy-suite.proxy.singBox.package.passthru.rootlessNetlink or false);
      true
    )
    (
      assert rejects "homeManager" { proxy.tproxy.enable = true; } "proxy.tproxy needs root";
      assert rejects "homeManager" { proxy.tun.enable = true; } "proxy.tun needs root";
      assert rejects "homeManager" { userControl.enable = true; } "userControl has nothing to grant";
      assert rejects "nixOnDroid" { zapret.enable = true; } "zapret needs root";
      assert rejects "nixOnDroid" {
        perAppRouting.zapret.enable = true;
      } "perAppRouting.zapret needs root";
      assert rejects "nixOnDroid" { gui.enable = true; } "the GUI needs a desktop session";
      assert rejects "nixOnDroid" {
        inbounds.listeners.vless.port = lib.mkForce 443;
      } "inbounds.listeners.vless.port = 443 is a privileged port";
      true
    )
  ];
}
