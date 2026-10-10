# Routing rules added at runtime (`proxy-ctl proxy rules`): the units, spool and environment
# they need, the configuration's sections proxy-ctl lists, and (runtime) the rules composed into
# real configs, which the backends then accept.
{
  checkLib,
  pkgs,
  minimalProxyCtlWrapper,
  minimalProxyCtlScript,
}:

let
  inherit (checkLib)
    ok
    evalProxySuite
    baseModule
    mkRouteModeRules
    shellValueByPrefix
    startScript
    unitScript
    ;
  inherit (pkgs) lib;
  fillTemplate = import ../../modules/proxy-suite/lib/fill-template.nix;

  routing = {
    rules = [
      {
        outbound = "primary";
        domains = [ "custom.example" ];
      }
    ];
    proxy.domains = [ "proxied.example" ];
    block.domains = [ "blocked.example" ];
  };
  fixture =
    backend:
    evalProxySuite [
      baseModule
      {
        services.proxy-suite = {
          proxy = {
            backend = lib.mkForce backend;
            inherit routing;
          };
          userControl = {
            enable = true;
            scopes = [ "routing" ];
          };
        };
      }
    ];
  singBoxFixture = fixture "sing-box";
  xrayFixture = fixture "xray";
  services = singBoxFixture.config.systemd.services;
  execStart = f: f.config.systemd.services.proxy-suite-socks.serviceConfig.ExecStart;
  socksScript = startScript singBoxFixture;
  applyScript = unitScript singBoxFixture "proxy-suite-routing-apply";
  buckets = mkRouteModeRules singBoxFixture;
  polkitRules = singBoxFixture.config.security.polkit.extraConfig;
  sections = (checkLib.mkRouting singBoxFixture).routingSections;

  # The inbounds' guard, alone: where it lands around runtime direct rules.
  guardFilter = pkgs.writeText "proxy-suite-runtime-routing-guard.jq" (
    import ../../modules/proxy-suite/service/script-blocks/backend-jq-filter.nix {
      inherit lib;
      pureXrayEnabled = false;
      selectionMode = "first";
      proxyInboundsGuardPrivate = true;
    }
  );

  runtime =
    pkgs.runCommand "proxy-suite-runtime-routing-check"
      {
        nativeBuildInputs = [
          pkgs.jq
          pkgs.gnugrep
        ];
      }
      (
        fillTemplate ./runtime-routing/compose.template.sh {
          singBoxStart = execStart singBoxFixture;
          xrayStart = execStart xrayFixture;
          singBox = "${singBoxFixture.config.services.proxy-suite.proxy.singBox.package}/bin/sing-box";
          xray = "${xrayFixture.config.services.proxy-suite.proxy.xray.package}/bin/xray";
          xrayAssets = "${xrayFixture.config.services.proxy-suite.geodata.xray.assets}/share/v2ray";
          inherit guardFilter;
        }
      );
in
{
  inherit runtime;
  assertions = [
    # proxy-ctl reads the configuration's sections, the spool and the rendered copy, and checks
    # geosites against the geodata the backend would load.
    (
      assert
        shellValueByPrefix minimalProxyCtlWrapper "export RUNTIME_ROUTING_DIR="
        == "/var/lib/proxy-suite/routing.d";
      assert
        shellValueByPrefix minimalProxyCtlWrapper "export ROUTING_RULES_DIR="
        == "/var/lib/proxy-suite/routing";
      assert lib.hasPrefix "/nix/store/" (
        shellValueByPrefix minimalProxyCtlWrapper "export ROUTING_RULES_FILE="
      );
      assert lib.hasSuffix "/share/sing-box/rule-set" (
        shellValueByPrefix minimalProxyCtlWrapper "export GEODATA_GEOSITE_DIR="
      );
      assert lib.hasInfix "proxy rules add <target> <match...>" minimalProxyCtlScript;
      true
    )

    # The sections, at the priorities runtime rules sort among, with the tags as written.
    (ok (
      map (s: s.id) sections == [
        "rules"
        "proxy"
        "block"
        "direct"
        "proxyGeo"
      ]
      &&
        map (s: s.priority) sections == [
          100
          200
          300
          400
          500
        ]
      && (builtins.head (builtins.head sections).entries).target == "primary"
      && (builtins.head (builtins.elemAt sections 2).entries).domains == [ "blocked.example" ]
    ))

    # The DNS mirror by section adds up to the configuration's own, in its order.
    (ok (
      lib.concatMap (c: c.dns) buckets.custom
      ++ buckets.dns.proxyPrimary
      ++ buckets.dns.direct
      ++ buckets.dns.proxyGeo == (checkLib.mkRouting singBoxFixture).singBoxDnsRules
    ))

    # The apply unit: root, over the routing scope's spool, which polkit lets that scope start.
    (
      let
        apply = services.proxy-suite-routing-apply.serviceConfig;
      in
      assert apply.RemainAfterExit == false;
      assert apply.ProtectSystem == "strict";
      assert apply.StateDirectory == "proxy-suite";
      assert lib.hasInfix "systemctl restart proxy-suite-socks" (
        builtins.replaceStrings [ "\n" ] [ " " ] applyScript
      );
      assert lib.hasInfix "/run/proxy-suite-tun/routing-structure" applyScript;
      assert lib.hasInfix "proxy-suite-routing-apply" polkitRules;
      assert builtins.elem "d /var/lib/proxy-suite/routing.d 2770 root proxy-suite -"
        singBoxFixture.config.systemd.tmpfiles.rules;
      true
    )

    # Every start renders the spool and composes the route, the runtime rules among the
    # configuration's, before the filter.
    (
      assert lib.hasInfix "routing-convert.jq" socksScript;
      assert lib.hasInfix "routing-compose.jq" socksScript;
      assert lib.hasInfix "--slurpfile user_rule_sets" socksScript;
      assert lib.hasInfix ''"$RUNTIME_DIR/routing-structure"'' socksScript;
      true
    )
  ];
}
