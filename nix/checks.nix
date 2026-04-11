{
  system,
  nixpkgs,
  proxySuiteModule,
}:

let
  pkgs = import nixpkgs { inherit system; };
  evalProxySuite =
    modules:
    import "${nixpkgs}/nixos/lib/eval-config.nix" {
      inherit system;
      modules = [ proxySuiteModule ] ++ modules;
    };
  forceEval = value: builtins.tryEval (builtins.deepSeq value true);
  rg = "${pkgs.ripgrep}/bin/rg";

  baseModule = {
    system.stateVersion = "26.05";
    services.proxy-suite = {
      enable = true;
      singBox.outbounds = [
        {
          tag = "primary";
          url = "http://proxy.example.com:8080";
        }
      ];
    };
  };

  minimal = evalProxySuite [ baseModule ];

  tgSecretFile = evalProxySuite [
    baseModule
    {
      services.proxy-suite.tgWsProxy = {
        enable = true;
        host = "127.0.0.1";
        secretFile = "/run/secrets/tg-ws-proxy";
      };
    }
  ];

  duplicateTags = forceEval (
    (evalProxySuite [
      {
        system.stateVersion = "26.05";
        services.proxy-suite = {
          enable = true;
          singBox.outbounds = [
            {
              tag = "dup";
              url = "http://one.example.com:8080";
            }
            {
              tag = "dup";
              url = "http://two.example.com:8080";
            }
          ];
        };
      }
    ]).config.system.build.toplevel.drvPath
  );

  reservedTag = forceEval (
    (evalProxySuite [
      {
        system.stateVersion = "26.05";
        services.proxy-suite = {
          enable = true;
          singBox.outbounds = [
            {
              tag = "proxy";
              url = "http://proxy.example.com:8080";
            }
          ];
        };
      }
    ]).config.system.build.toplevel.drvPath
  );

  unknownRoutingTarget = forceEval (
    (evalProxySuite [
      {
        system.stateVersion = "26.05";
        services.proxy-suite = {
          enable = true;
          singBox = {
            outbounds = [
              {
                tag = "primary";
                url = "http://proxy.example.com:8080";
              }
            ];
            routing.rules = [
              {
                outbound = "missing";
                domains = [ "example.com" ];
              }
            ];
          };
        };
      }
    ]).config.system.build.toplevel.drvPath
  );

  tproxyWithFirewall = evalProxySuite [
    {
      system.stateVersion = "26.05";
      networking.firewall.enable = true;
      services.proxy-suite = {
        enable = true;
        singBox = {
          tproxy.enable = true;
          outbounds = [
            {
              tag = "primary";
              url = "http://proxy.example.com:8080";
            }
          ];
        };
      };
    }
  ];

  routingOrFixture = evalProxySuite [
    {
      system.stateVersion = "26.05";
      services.proxy-suite = {
        enable = true;
        singBox = {
          outbounds = [
            {
              tag = "primary";
              url = "http://proxy.example.com:8080";
            }
          ];
          routing.rules = [
            {
              outbound = "primary";
              domains = [ "example.com" ];
              geoips = [ "us" ];
            }
          ];
        };
      };
    }
  ];

  routingOrRules = (import ../modules/proxy-suite/rules.nix {
    lib = pkgs.lib;
    inherit pkgs;
    cfg = routingOrFixture.config.services.proxy-suite;
  }).routingRules;

  routingOrDomainRules = builtins.filter (
    rule: (rule ? domain_suffix) && rule.domain_suffix == [ "example.com" ]
  ) routingOrRules;

  routingOrGeoIPRules = builtins.filter (
    rule: (rule ? rule_set) && rule.rule_set == [ "geoip-us" ]
  ) routingOrRules;

  validated =
    builtins.seq (assert minimal.config.services.proxy-suite.singBox.listenAddress == "127.0.0.1"; true) (
      builtins.seq (assert tgSecretFile.config.services.proxy-suite.tgWsProxy.host == "127.0.0.1"; true) (
        builtins.seq (
          assert tgSecretFile.config.systemd.services."proxy-suite-tg-ws-proxy".serviceConfig.LoadCredential
            == [ "tg_ws_proxy_secret:/run/secrets/tg-ws-proxy" ];
          true
        ) (
          builtins.seq (assert duplicateTags.success == false; true) (
            builtins.seq (assert reservedTag.success == false; true) (
              builtins.seq (assert unknownRoutingTarget.success == false; true) (
                builtins.seq (assert tproxyWithFirewall.config.networking.firewall.enable; true) (
                  builtins.seq (
                    assert builtins.length routingOrDomainRules == 1;
                    true
                  ) (
                    builtins.seq (
                      assert builtins.length routingOrGeoIPRules == 1;
                      true
                    ) (
                      builtins.seq (
                        assert (builtins.head routingOrDomainRules).outbound == "proxy";
                        true
                      ) (
                        assert (builtins.head routingOrGeoIPRules).outbound == "proxy"; true
                      )
                    )
                  )
                )
              )
            )
          )
        )
      )
    );
in
{
  proxy-suite-module = builtins.seq validated (pkgs.writeText "proxy-suite-module-check" "ok");

  build-outbound-parser = pkgs.runCommand "build-outbound-parser-check" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    export PYTHONDONTWRITEBYTECODE=1
    export BUILD_OUTBOUND_SCRIPT=${../scripts/build-outbound.py}
    python ${../scripts/test-build-outbound.py}
    touch "$out"
  '';

  no-secrets = pkgs.runCommand "proxy-suite-no-secrets-check" {} ''
    repo_root=${../.}
    if ${rg} --pcre2 -n -I -H -S \
      -e '-----BEGIN (RSA|DSA|EC|OPENSSH|PGP) PRIVATE KEY-----' \
      -e 'ghp_[A-Za-z0-9]{36}' \
      -e 'github_pat_[A-Za-z0-9_]{20,}' \
      -e 'glpat-[A-Za-z0-9_-]{20,}' \
      -e 'xox[baprs]-[A-Za-z0-9-]{10,}' \
      -e 'AKIA[0-9A-Z]{16}' \
      -e 'AIza[0-9A-Za-z_-]{35}' \
      -e 'sk-(proj-)?[A-Za-z0-9_-]{20,}' \
      "$repo_root"; then
      echo "secret-like content detected in source tree" >&2
      exit 1
    fi
    touch "$out"
  '';
}
