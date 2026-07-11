{
  pkgs,
  evalProxySuite,
  mkTProxyConfig,
  mkTunConfig,
  mkPerAppTunConfig,
  shellValueByPrefix,
  checkConstants,
}:

let
  fixtures = import ./xray-backend-runtime/fixtures.nix {
    inherit
      pkgs
      evalProxySuite
      mkTProxyConfig
      mkTunConfig
      mkPerAppTunConfig
      shellValueByPrefix
      ;
  };

  inherit (fixtures)
    xrayBackendJqFilter
    xrayBackendJqFilterFile
    xrayDnsLocalClient
    xrayDnsRemoteClient
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
  xrayJqFilterRuntimeCheck =
    pkgs.runCommand "proxy-suite-xray-jq-filter-runtime-check" { nativeBuildInputs = [ pkgs.jq ]; }
      ''
        OBS='[{"protocol":"freedom","tag":"proxy-suite-ob-primary"}]'

        check_runtime() {
          local name="$1"
          local input="$2"
          local output="$TMPDIR/$name.json"

          jq \
            --argjson obs "$OBS" \
            --argjson auth_enabled false \
            --arg user "" \
            --arg password "" \
            --argjson route_enabled true \
            --argjson route_rules '[]' \
            --arg route_final "proxy" \
            --arg dns_final "remote" \
            --argjson clear_dns_rules false \
            --arg xray_loglevel "" \
            --arg xray_bind_interface "eth0" \
            --arg xray_single_proxy_tag "proxy-suite-ob-primary" \
            --argjson xray_tun_dns_runtime true \
            --arg xray_dns_local_client ${pkgs.lib.escapeShellArg xrayDnsLocalClient} \
            --arg xray_dns_remote_client ${pkgs.lib.escapeShellArg xrayDnsRemoteClient} \
            -f ${pkgs.lib.escapeShellArg xrayBackendJqFilterFile} \
            "$input" > "$output"

          jq -e \
            --arg remote ${pkgs.lib.escapeShellArg xrayDnsRemoteClient} \
            --arg local ${pkgs.lib.escapeShellArg xrayDnsLocalClient} \
            '
              type == "object"
              and (.dns.servers | length) >= 3
              and .dns.servers[0].tag == "fakedns"
              and ([.routing.rules[] | select((.ruleTag? // "") == "dns-hijack")] | length) == 1
              and ([.routing.rules[] | select((.ruleTag? // "") == "dns-upstream-direct")] | length) == 1
              and ([.outbounds[] | select(.tag == "proxy-suite-ob-primary" and (.streamSettings.sockopt.interface? // "") == "eth0")] | length) == 1
              and ([.outbounds[] | select(.tag == "dns-out" and ((.streamSettings.sockopt.interface? // "") == ""))] | length) == 1
              and ([.inbounds[] | select(.tag == "tun-in") | .settings.dns] | length) == 1
              and ([.inbounds[] | select(.tag == "tun-in") | .settings.dns][0] == [$remote, $local])
              and ((.routing | has("balancers")) | not)
              and ((has("observatory")) | not)
            ' "$output" >/dev/null
        }

        check_runtime global ${pkgs.lib.escapeShellArg xrayTunConfigJson}
        check_runtime per-app ${pkgs.lib.escapeShellArg xrayPerAppTunConfigJson}
        touch "$out"
      '';

  serviceShapeChecks = import ./xray-backend-runtime/service-shape.nix {
    inherit
      pkgs
      xrayFixture
      xrayTproxyConfig
      xrayStartScript
      ;
  };
  tunChecks = import ./xray-backend-runtime/tun.nix {
    inherit
      pkgs
      checkConstants
      xrayTunConfig
      xrayPerAppTunConfig
      xrayStartBackendJqFilterFile
      xrayTunBackendJqFilterFile
      xrayPerAppTunBackendJqFilterFile
      xrayStartScript
      xrayTunStartScript
      xrayTunUpScript
      xrayPerAppTunStartScript
      xrayPerAppTunUpScript
      xrayPerAppTunCleanupScript
      xrayBackendJqFilter
      ;
  };
in
{
  runtime = xrayJqFilterRuntimeCheck;

  assertions = serviceShapeChecks.assertions ++ tunChecks.assertions;
}
