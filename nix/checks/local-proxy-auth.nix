{
  pkgs,
  evalProxySuite,
  baseModule,
  mkProxyCtlDerived,
  shellValueByPrefix,
  mkBadFixture,
  mkFailingAssertions,
  ruDefaultConfig,
}:

let
  generated = import ./read-generated.nix;

  localProxyAuthFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite.proxy.auth = {
        username = "local-user";
        password = "local-pass";
      };
    }
  ];
  localProxyAuthStartScript = generated.readDerivation (
    localProxyAuthFixture.config.systemd.services."proxy-suite-socks".serviceConfig.ExecStart
  );
  localProxyAuthBackendJqFilter =
    import ../../modules/proxy-suite/service/script-blocks/backend-jq-filter.nix
      {
        pureXrayEnabled = false;
        selectionMode = localProxyAuthFixture.config.services.proxy-suite.proxy.selection;
      };

  localProxyAuthPasswordFileFixture = evalProxySuite [
    baseModule
    {
      services.proxy-suite = {
        proxy.auth = {
          username = "local-user";
          passwordFile = "/run/secrets/local-proxy-password";
        };
        perAppRouting = {
          enable = true;
          proxychains.enable = true;
          profiles = [
            {
              name = "steam-browser";
              route = "proxychains";
            }
          ];
        };
      };
    }
  ];
  _localProxyAuthPasswordFile = mkProxyCtlDerived localProxyAuthPasswordFileFixture;
  localProxyAuthPasswordFileWrapper = _localProxyAuthPasswordFile.wrapper;
  localProxyAuthPasswordFileScript = _localProxyAuthPasswordFile.script;
  localProxyAuthPasswordFileStartScript = generated.readDerivation (
    localProxyAuthPasswordFileFixture.config.systemd.services."proxy-suite-socks".serviceConfig.ExecStart
  );

  invalidLocalProxyAuthAssertions = mkFailingAssertions mkBadFixture [
    # Auth requires both username and a password source.
    [
      { services.proxy-suite.proxy.auth.username = "local-user"; }
    ]
    [
      { services.proxy-suite.proxy.auth.password = "local-pass"; }
    ]

    # Inline password and passwordFile are mutually exclusive.
    [
      {
        services.proxy-suite.proxy.auth = {
          username = "local-user";
          password = "local-pass";
          passwordFile = "/run/secrets/local-proxy-password";
        };
      }
    ]
  ];
in
{
  assertions = [
    # Default mixed inbound stays unauthenticated.
    (
      let
        mixedInbound = builtins.head (
          builtins.filter (inbound: inbound.tag == "mixed-in") ruDefaultConfig.inbounds
        );
      in
      assert !(mixedInbound ? users);
      true
    )

    # Authenticated mixed inbound is injected at runtime.
    (
      assert pkgs.lib.hasInfix ''LOCAL_PROXY_PASSWORD="$(cat "'' localProxyAuthStartScript;
      assert pkgs.lib.hasInfix "BACKEND_JQ_FILTER=" localProxyAuthStartScript;
      assert pkgs.lib.hasInfix ''-f "$BACKEND_JQ_FILTER"'' localProxyAuthStartScript;
      assert pkgs.lib.hasInfix "--arg user local-user" localProxyAuthStartScript;
      assert pkgs.lib.hasInfix ''--arg password "$LOCAL_PROXY_PASSWORD"'' localProxyAuthStartScript;
      assert pkgs.lib.hasInfix ''select(.type == "mixed" and .tag == "mixed-in") | .users''
        localProxyAuthBackendJqFilter;
      assert pkgs.lib.hasInfix ''chmod 600 "$RUNTIME_DIR/config.json"'' localProxyAuthStartScript;
      true
    )

    # passwordFile is read from runtime path and proxychains uses runtime config.
    (
      assert pkgs.lib.hasInfix "/run/secrets/local-proxy-password" localProxyAuthPasswordFileStartScript;
      assert pkgs.lib.hasInfix "/run/proxy-suite-socks/proxychains.conf"
        localProxyAuthPasswordFileStartScript;
      assert pkgs.lib.hasInfix "printf 'socks5 %s %s %s %s\\n'" localProxyAuthPasswordFileStartScript;
      assert pkgs.lib.hasInfix ''chgrp proxy-suite "/run/proxy-suite-socks/proxychains.conf"''
        localProxyAuthPasswordFileStartScript;
      assert pkgs.lib.hasInfix ''chmod 640 "/run/proxy-suite-socks/proxychains.conf"''
        localProxyAuthPasswordFileStartScript;
      assert builtins.hasAttr "proxy-suite" localProxyAuthPasswordFileFixture.config.users.groups;
      assert
        shellValueByPrefix localProxyAuthPasswordFileWrapper "export PROXYCHAINS_CONFIG="
        == "/run/proxy-suite-socks/proxychains.conf";
      assert pkgs.lib.hasInfix "Proxychains config is not readable" localProxyAuthPasswordFileScript;
      true
    )

  ]
  ++ invalidLocalProxyAuthAssertions;
}
