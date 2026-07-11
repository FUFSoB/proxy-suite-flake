{
  pkgs,
  evalProxySuite,
  baseModule,
  mkRoutingRules,
  mkTProxyNftRules,
  mkBadFixture,
  mkFailingAssertions,
  hasDirectIP,
  minimal,
  minimalSocksService,
  zapretSyncService,
}:

let
  fixtures = import ./tg-ws-proxy/fixtures.nix {
    inherit
      evalProxySuite
      baseModule
      mkRoutingRules
      mkTProxyNftRules
      mkBadFixture
      mkFailingAssertions
      ;
  };
  inherit (fixtures)
    tgSecretFile
    tgSecretFileService
    tgAllOptionsStartScript
    tgWithGlobalTunServiceConfig
    tgWithGlobalTunBypassUp
    tgWithGlobalTunBypassDown
    tgWithGlobalTunRules
    tgWithGlobalTproxyNft
    invalidTgWsProxyAssertions
    ;
in
{
  assertions = [
    (
      assert tgSecretFile.config.services.proxy-suite.tgWsProxy.host == "127.0.0.1";
      true
    )
    (
      assert minimal.config.services.proxy-suite.tgWsProxy.host == "127.0.0.1";
      true
    )
    (
      assert minimal.config.services.proxy-suite.tgWsProxy.dcIps == { };
      true
    )

    # Upstream runtime flags are exposed as typed module options.
    (
      assert pkgs.lib.hasInfix "--port=2443" tgAllOptionsStartScript;
      assert pkgs.lib.hasInfix "--host=0.0.0.0" tgAllOptionsStartScript;
      assert pkgs.lib.hasInfix "--secret-file=\"$CREDENTIALS_DIRECTORY/tg_ws_proxy_secret\""
        tgAllOptionsStartScript;
      assert pkgs.lib.hasInfix "--verbose" tgAllOptionsStartScript;
      assert pkgs.lib.hasInfix "--log-file=/var/log/tg-ws-proxy.log" tgAllOptionsStartScript;
      assert pkgs.lib.hasInfix "--log-max-mb=2.500000" tgAllOptionsStartScript;
      assert pkgs.lib.hasInfix "--log-backups=3" tgAllOptionsStartScript;
      assert pkgs.lib.hasInfix "--buf-kb=512" tgAllOptionsStartScript;
      assert pkgs.lib.hasInfix "--pool-size=8" tgAllOptionsStartScript;
      assert pkgs.lib.hasInfix "--cfproxy-domain=cdn.example.com" tgAllOptionsStartScript;
      assert pkgs.lib.hasInfix "--cfproxy-domain=edge.example.net" tgAllOptionsStartScript;
      assert pkgs.lib.hasInfix "--cfproxy-worker-domain=worker.example.com" tgAllOptionsStartScript;
      assert pkgs.lib.hasInfix "--no-cfproxy" tgAllOptionsStartScript;
      assert pkgs.lib.hasInfix "--fake-tls-domain=mask.example.com" tgAllOptionsStartScript;
      assert pkgs.lib.hasInfix "--proxy-protocol" tgAllOptionsStartScript;
      true
    )

    (
      assert
        tgSecretFile.config.systemd.services."proxy-suite-tg-ws-proxy".serviceConfig.LoadCredential
        == [ "tg_ws_proxy_secret:/run/secrets/tg-ws-proxy" ];
      true
    )

    # Global TUN/TProxy bypass mark keeps relay traffic out of transparent capture.
    (
      assert tgWithGlobalTunServiceConfig.SocketMark == "4";
      assert pkgs.lib.hasInfix "rule add pref 8999 fwmark 4 lookup main" tgWithGlobalTunBypassUp;
      assert pkgs.lib.hasInfix "rule del pref 8999 fwmark 4 lookup main" tgWithGlobalTunBypassDown;
      assert hasDirectIP tgWithGlobalTunRules "149.154.167.220";
      assert pkgs.lib.hasInfix "meta mark 4 return" tgWithGlobalTproxyNft;
      true
    )

    # Network-sensitive global services wait for network-online.
    (
      assert builtins.elem "network-online.target" minimalSocksService.after;
      assert builtins.elem "network-online.target" minimalSocksService.wants;
      assert builtins.elem "network-online.target" tgSecretFileService.after;
      assert builtins.elem "network-online.target" tgSecretFileService.wants;
      assert builtins.elem "network-online.target" zapretSyncService.after;
      assert builtins.elem "network-online.target" zapretSyncService.wants;
      true
    )
  ]
  ++ invalidTgWsProxyAssertions;
}
