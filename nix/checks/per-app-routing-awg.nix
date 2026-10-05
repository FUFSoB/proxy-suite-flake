{
  checkLib,
  pkgs,
  mkPerAppUserRules,
}:

let
  inherit (checkLib) mkProxySuite rejectsProxySuite;
  generated = import ./read-generated.nix;
  inherit (pkgs.lib) hasInfix;

  config = {
    enable = true;
    proxy = {
      enable = true;
      tproxy.enable = true;
    };
    killSwitch.enable = true;
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
        # Global: apps run through a copy of it, brought up apart.
        home.configFile = "/run/secrets/home.conf";
      };
    };
    perAppRouting = {
      enable = true;
      profiles = [
        {
          name = "game";
          route = "tun";
          outbound = "de";
        }
      ];
    };
  };
  fixture = mkProxySuite config;
  services = fixture.config.systemd.services;
  via = services."proxy-suite-per-app-via@";
  perAppRouting = mkPerAppUserRules fixture;
  viaUp = generated.readDerivation perAppRouting.viaUp;
  viaDns = generated.readDerivation perAppRouting.viaDns;
  appCopy = services."proxy-suite-awg-app@";
  viaFile = builtins.fromJSON (generated.readDerivation perAppRouting.perAppViaFile);
  viaUserRule = generated.readDerivation perAppRouting.viaUserRule;
  viaUserStart = generated.readDerivation perAppRouting.viaUserStart;
  viaRetire = generated.readDerivation perAppRouting.viaRetire;
  viaReapply = generated.readDerivation perAppRouting.viaReapply;
  anchor = fixture.config.systemd.user.services."proxy-suite-per-app-via-anchor@";
  dePrepare = generated.readDerivation (
    builtins.head services.proxy-suite-awg-de.serviceConfig.ExecStartPre
  );
  nftr = import ../../modules/proxy-suite/nftables.nix {
    inherit (pkgs) lib;
    inherit pkgs;
    cfg = fixture.config.services.proxy-suite;
  };
  globalTproxyRules = generated.readDerivation nftr.nftablesRulesFile;
  killSwitchRules = generated.readDerivation nftr.killSwitchRulesFile;

  withoutPerApp = mkProxySuite (config // { perAppRouting.enable = false; });

  # Pins: any outbound, through per-app TProxy or TUN.
  pinConfig = {
    enable = true;
    proxy = {
      enable = true;
      ipv6 = false;
      tproxy.enable = true;
      outbounds = [
        {
          tag = "nl";
          url = "socks5://127.0.0.1:1080";
        }
      ];
    };
    killSwitch.enable = true;
    perAppRouting = {
      enable = true;
      tproxy.enable = true;
      tun.enable = true;
      profiles = [
        {
          name = "game";
          route = "tproxy";
          outbound = "nl";
        }
      ];
    };
  };
  pinFixture = mkProxySuite pinConfig;
  pinServices = pinFixture.config.systemd.services;
  pinPerApp = mkPerAppUserRules pinFixture;
  pinTproxyUp = generated.readDerivation pinPerApp.pinUp.tproxy;
  pinTproxyDown = generated.readDerivation pinPerApp.pinDown.tproxy;
  pinTunUp = generated.readDerivation pinPerApp.pinUp.tun;
  pinUserStart = generated.readDerivation pinPerApp.viaUserRule;
  pinTproxyConfig = checkLib.mkTProxyConfig pinFixture;
  pinTunConfig = checkLib.mkPerAppTunConfig pinFixture;
  pinNft = import ../../modules/proxy-suite/nftables.nix {
    inherit (pkgs) lib;
    inherit pkgs;
    cfg = pinFixture.config.services.proxy-suite;
  };
in
{
  assertions = [
    # Only the "interface" outbound takes apps directly, by its table and a mark of its own.
    (
      assert
        viaFile == {
          de = {
            interface = "awg-de";
            table = 110;
            mark = 23040;
            dnsPort = 19100;
            unit = "proxy-suite-awg-de.service";
            dnsFile = "/run/proxy-suite-awg-de/dns";
            fallbackDns = [ "1.1.1.1" ];
          };
        };
      assert hasInfix "--dns-out \"/run/proxy-suite-awg-de/dns\"" dePrepare;
      true
    )
    # The instance: the app's packets marked into the table, masqueraded, DNS rewritten to the
    # profile's resolver, and turned away while the table has no route.
    (
      assert hasInfix "%i" via.serviceConfig.ExecStart;
      assert via.serviceConfig.Type == "notify";
      assert hasInfix "per_app_dns.py --port \"$dns_port\" --mark \"$mark\"" viaDns;
      assert hasInfix ''nft_table="proxy_suite_per_app_via_$mark"'' viaUp;
      assert hasInfix ''oifname "$interface" meta mark $mark masquerade'' viaUp;
      assert hasInfix "ct mark $mark meta l4proto { tcp, udp } th dport 53 redirect to :$dns_port" viaUp;
      assert hasInfix "th dport 53 goto app_mark" viaUp;
      assert hasInfix "ip daddr 192.168.0.0/16 return" viaUp;
      assert hasInfix ''rule add pref 8986 fwmark "$mark" lookup "$table"'' viaUp;
      assert hasInfix ''rule add pref 8987 fwmark "$mark" unreachable'' viaUp;
      assert hasInfix "priority mangle - 10" viaUp;
      # The tunnel's own packets carry its FwMark and still look like the app's: never taken,
      # nor marked on the way in, or they loop back into the tunnel.
      assert hasInfix "meta mark != 0 return" viaUp;
      assert hasInfix ''iifname "$interface" ct mark $mark meta mark set $mark'' viaUp;
      # Private ranges go through the tunnel, the server's own address among them.
      assert !(hasInfix "RESERVED_IP" viaUp);
      true
    )
    # Each user's apps, in the outbound's slice; the slice from a user unit.
    (
      assert hasInfix "^([0-9]+)-((awg|app|tproxy|tun)-[0-9a-f]+)$" viaUserRule;
      assert hasInfix "nft_chain=app_mark" viaUserRule;
      assert hasInfix ''-name "$slice_name"'' viaUserRule;
      assert hasInfix "meta mark set $mark ct mark set $mark" viaUserRule;
      assert anchor.serviceConfig.Slice == "proxy-suite-per-app-via-%i.slice";
      assert services ? "proxy-suite-per-app-via-user@";
      true
    )
    # The via unit is every user's: perApp members only start it (polkit.nix), and the last
    # user's unit takes it down, under the lock a rule goes in by, so none lands in a table
    # on its way out. A restart puts the users' rules back in its fresh table.
    (
      let
        user = services."proxy-suite-per-app-via-user@".serviceConfig;
        lock = ''exec 8>>"/run/proxy-suite-per-app-via/users-$key.lock"'';
      in
      assert pkgs.lib.hasSuffix " %i" user.ExecStopPost;
      # Not on its own restart, nor through a switch's stop and start.
      assert hasInfix ''$3 == "restart"'' viaRetire;
      assert !services."proxy-suite-per-app-via-user@".serviceConfig.X-RestartIfChanged;
      assert hasInfix lock viaUserStart && hasInfix lock viaRetire;
      assert hasInfix ''show --property=ActiveState --value "$via_unit") != active'' viaUserStart;
      assert hasInfix ''via_unit="proxy-suite-per-app-via@$key.service"'' viaRetire;
      assert hasInfix ''via_unit="proxy-suite-per-app-via-''${key%%-*}@''${key#*-}.service"'' viaRetire;
      assert hasInfix "--state=active,activating,reloading" viaRetire;
      assert hasInfix "-v self=\"proxy-suite-per-app-via-user@$1.service\" '$1 != self')" viaRetire;
      # The profile brought up for the apps after the via unit, whose stop reads its slot.
      assert
        builtins.match ''.*stop "\$via_unit".*stop "proxy-suite-awg-app@\$tag\.service".*'' viaRetire
        != null;
      assert pkgs.lib.hasSuffix " %i" via.serviceConfig.ExecStartPost;
      assert hasInfix ''"proxy-suite-per-app-via-user@*-''${1:-}.service"'' viaReapply;
      assert hasInfix "--state=active " viaReapply;
      true
    )
    # Global TProxy and the kill switch let the apps' mark past.
    (
      # And the slots of the outbounds added at runtime, on interfaces of their own.
      assert hasInfix "meta mark { 23040, 23104, 23105," globalTproxyRules;
      # And the slots of the global profiles apps run through.
      assert hasInfix "23119, 23232," globalTproxyRules;
      assert hasInfix "23239 } return" globalTproxyRules;
      assert hasInfix "23040" killSwitchRules;
      true
    )
    # A global profile: a copy rendered as an "interface" outbound has it, on a slot's
    # interface, never up with the profile itself.
    (
      assert appCopy.wantedBy == [ ];
      assert appCopy.serviceConfig.Restart == "no";
      # Never up with the profile itself, and never taking it down: refused while it is up.
      assert (appCopy.conflicts or [ ]) == [ ];
      assert hasInfix "proxy-suite-awg-%i.service proxy-suite-awg@%i.service" (
        builtins.head appCopy.serviceConfig.ExecStartPre
      );
      assert builtins.elem "proxy-suite-awg-app-watchdog@%i.service" appCopy.wants;
      assert services."proxy-suite-awg-app-watchdog@".bindsTo == [ "proxy-suite-awg-app@%i.service" ];
      assert appCopy.serviceConfig.RuntimeDirectory == "proxy-suite-awg-app-%i";
      assert hasInfix ''"/run/proxy-suite-awg-app-$tag/slot"'' viaUp;
      assert hasInfix "^(awg|app)-([0-9a-f][0-9a-f]){1,64}$" viaUp;
      assert hasInfix ''iifname "psawga*" accept''
        fixture.config.networking.firewall.extraReversePathFilterRules;
      true
    )
    # Without per-app routing there is nothing to run via.
    (
      assert !(withoutPerApp.config.systemd.services ? "proxy-suite-per-app-via@");
      true
    )
    # Pin slots: a listener, a rule and a selector each in the backend, which the filter fills;
    # a unit per route, part of the backend whose selector it switches.
    (
      assert pinServices ? "proxy-suite-per-app-via-tproxy@";
      assert pinServices."proxy-suite-per-app-via-tproxy@".partOf == [ "proxy-suite-socks.service" ];
      assert pinServices."proxy-suite-per-app-via-tun@".partOf == [ "proxy-suite-per-app-tun.service" ];
      # Restarted with the backend, the slot's table comes back empty: the users' rules too.
      assert pkgs.lib.hasSuffix " tun-%i"
        pinServices."proxy-suite-per-app-via-tun@".serviceConfig.ExecStartPost;
      assert pkgs.lib.hasSuffix " tproxy-%i"
        pinServices."proxy-suite-per-app-via-tproxy@".serviceConfig.ExecStartPost;
      # Under a global mode it stays down rather than take the mode down.
      assert (pinServices."proxy-suite-per-app-via-tun@".conflicts or [ ]) == [ ];
      assert pkgs.lib.hasInfix "proxy-suite-tproxy.service proxy-suite-tun.service"
        pinServices."proxy-suite-per-app-via-tun@".serviceConfig.ExecStartPre;
      assert pinServices ? "proxy-suite-per-app-via-user@";
      # The kernel path's unit only with an "interface" AmneziaWG outbound to take.
      assert !(pinServices ? "proxy-suite-per-app-via@");
      assert builtins.elem {
        type = "tproxy";
        tag = "per-app-pin-tproxy-0";
        listen = "127.0.0.1";
        listen_port = 19160;
      } pinTproxyConfig.inbounds;
      assert builtins.elem {
        inbound = [ "per-app-pin-tproxy-7" ];
        outbound = "proxy-suite-pin-tproxy-7";
      } pinTproxyConfig.route.rules;
      assert builtins.elem {
        type = "selector";
        tag = "proxy-suite-pin-tproxy-0";
        outbounds = [ "block" ];
        default = "block";
      } pinTproxyConfig.outbounds;
      assert builtins.elem {
        inbound = [ "tun-in" ];
        source_ip_cidr = [ "172.20.1.2/32" ];
        outbound = "proxy-suite-pin-tun-0";
      } pinTunConfig.route.rules;
      assert pinTunConfig.experimental.clash_api.external_controller == "127.0.0.1:19180";
      assert hasInfix ''select_pin "$tag" 60'' pinTproxyUp;
      assert hasInfix "/proxies/proxy-suite-pin-tproxy-$slot" pinTproxyUp;
      assert hasInfix "/run/proxy-suite-socks/clash-secret" pinTproxyUp;
      assert hasInfix "127.0.0.1:19180" pinTunUp;
      assert hasInfix ''route replace default dev psperapptun0 table "$table"'' pinTunUp;
      # The backend tells a TUN slot by the source its packets are SNATed to.
      assert hasInfix ''oifname "psperapptun0" meta mark 23200 meta nfproto ipv4 snat ip to 172.20.1.2'' (
        generated.readDerivation (builtins.head pinNft.perAppPinTunChainFiles)
      );
      assert hasInfix ''rule add pref 8988 fwmark "$mark" table "$table"'' pinTunUp;
      assert hasInfix "select_pin block 1" pinTproxyDown;
      assert builtins.length pinNft.perAppPinTproxyRulesFiles == 8;
      assert hasInfix "tproxy ip to 127.0.0.1:19167" (
        generated.readDerivation (pkgs.lib.last pinNft.perAppPinTproxyRulesFiles)
      );
      assert hasInfix "table inet proxy_suite_per_app_via_tun_0" (
        generated.readDerivation (builtins.head pinNft.perAppPinTunChainFiles)
      );
      assert hasInfix "ct mark 23200 meta mark set 23200" (
        generated.readDerivation (builtins.head pinNft.perAppPinTunChainFiles)
      );
      # The user rule units find the slot a pin holds.
      assert hasInfix "^([0-9]+)-((awg|app|tproxy|tun)-[0-9a-f]+)$" pinUserStart;
      assert hasInfix "nft_chain=app_mark" pinUserStart;
      assert hasInfix "23168" (checkLib.mkNftRules pinFixture "killSwitchRulesFile");
      true
    )
    # Any outbound for a tproxy or tun profile; only an "interface" one for the rest.
    (rejectsProxySuite "outbound 'nl' needs route \"tproxy\" or \"tun\"" (
      pinConfig
      // {
        perAppRouting = pinConfig.perAppRouting // {
          profiles = [
            {
              name = "game";
              route = "proxychains";
              outbound = "nl";
            }
          ];
        };
      }
    ))
    # A table a pin slot takes for itself, named by an option too: the two would flush each
    # other's routes.
    (rejectsProxySuite "route table 170 (proxy.tproxy.routeTable" (
      pinConfig
      // {
        proxy = pinConfig.proxy // {
          tproxy = pinConfig.proxy.tproxy // {
            routeTable = 170;
          };
        };
      }
    ))
    (rejectsProxySuite "outbound 'plain' needs route \"tproxy\" or \"tun\"" (
      config
      // {
        perAppRouting = config.perAppRouting // {
          profiles = [
            {
              name = "game";
              route = "tun";
              outbound = "plain";
            }
          ];
        };
      }
    ))
  ];
}
