{
  checkLib,
  pkgs,
  evalProxySuite,
  mkTProxyConfig,
  mkTunConfig,
  mkPerAppTunConfig,
  shellValueByPrefix,
}:

let
  inherit (checkLib) startScript unitScript;
  generated = import ../read-generated.nix;

  xrayModule = {
    system.stateVersion = "26.05";
    services.proxy-suite = {
      enable = true;
      proxy = {
        enable = true;
        backend = "xray";
        selection = "urltest";
        outbounds = [
          {
            tag = "primary";
            url = "vless://uuid@example.com:443?type=xhttp&security=tls&sni=cdn.example.com&host=cdn.example.com&path=%2Fx";
            routing.domains = [ "specific.example" ];
          }
        ];
        routing = {
          proxy.domains = [ "proxy.example" ];
          direct = {
            domains = [ "direct.example" ];
            geosites = [ "category-ru" ];
          };
          block.domains = [ "block.example" ];
        };
        tproxy.enable = true;
        tun.enable = true;
      };
      perAppRouting = {
        enable = true;
        createDefaultProfiles = true;
        tun.enable = true;
        tproxy.enable = true;
      };
    };
  };

  xrayFixture = evalProxySuite [ xrayModule ];
  xrayTproxyConfig = mkTProxyConfig xrayFixture;
  xrayTunConfig = mkTunConfig xrayFixture;
  xrayPerAppTunConfig = mkPerAppTunConfig xrayFixture;
  xrayStartScript = startScript xrayFixture;
  xrayTunStartScript = unitScript xrayFixture "proxy-suite-tun";
  xrayTunUpScript = generated.readDerivation (
    xrayFixture.config.systemd.services."proxy-suite-tun".serviceConfig.ExecStartPost
  );
  xrayPerAppTunStartScript = unitScript xrayFixture "proxy-suite-per-app-tun";
  xrayPerAppTunUpScript = generated.readDerivation (
    xrayFixture.config.systemd.services."proxy-suite-per-app-tun".serviceConfig.ExecStartPost
  );
  xrayPerAppTunCleanupScript = generated.readDerivation (
    xrayFixture.config.systemd.services."proxy-suite-per-app-tun".serviceConfig.ExecStopPost
  );
  xrayStartBackendJqFilterFile = builtins.unsafeDiscardStringContext (
    shellValueByPrefix xrayStartScript "BACKEND_JQ_FILTER="
  );
  xrayTunBackendJqFilterFile = builtins.unsafeDiscardStringContext (
    shellValueByPrefix xrayTunStartScript "BACKEND_JQ_FILTER="
  );
  xrayPerAppTunBackendJqFilterFile = builtins.unsafeDiscardStringContext (
    shellValueByPrefix xrayPerAppTunStartScript "BACKEND_JQ_FILTER="
  );
  xrayBackendJqFilter =
    import ../../../modules/proxy-suite/service/script-blocks/backend-jq-filter.nix
      {
        lib = pkgs.lib;
        proxyInboundsGuardPrivate = false;
        pureXrayEnabled = true;
        selectionMode = xrayFixture.config.services.proxy-suite.proxy.selection;
      };
  xrayBackendJqFilterFile = pkgs.writeText "proxy-suite-xray-backend-filter-check.jq" xrayBackendJqFilter;
  xrayTunConfigJson = pkgs.writeText "proxy-suite-xray-tun-check.json" (
    builtins.toJSON xrayTunConfig
  );
  xrayPerAppTunConfigJson = pkgs.writeText "proxy-suite-xray-per-app-tun-check.json" (
    builtins.toJSON xrayPerAppTunConfig
  );
in
{
  inherit
    xrayBackendJqFilter
    xrayBackendJqFilterFile
    xrayFixture
    xrayPerAppTunBackendJqFilterFile
    xrayPerAppTunCleanupScript
    xrayPerAppTunConfig
    xrayPerAppTunConfigJson
    xrayPerAppTunStartScript
    xrayPerAppTunUpScript
    xrayStartBackendJqFilterFile
    xrayStartScript
    xrayTproxyConfig
    xrayTunBackendJqFilterFile
    xrayTunConfig
    xrayTunConfigJson
    xrayTunStartScript
    xrayTunUpScript
    ;
}
