# whitelist-bypass: joiners, the loopback SOCKS listeners behind their outbounds, and
# creators, the free ends of the calls they tunnel through.
{
  lib,
  pkgs,
  cfg,
  derived,
}:

let
  w = derived.whitelistBypassCfg;
  inherit (derived.constants) unprivilegedServiceConfig;
  inherit (derived.localProxy) auth;

  # Every flag that takes the call, joiner and creator alike.
  linkFlag = {
    wbstream = "--room";
    dion = "--room";
    bitrix = "--room";
    telemost = "--tm-link";
    vk = "--vk-link";
  };
  joinerLinkFlag = linkFlag // {
    bitrix = "--link";
  };

  passwordSource =
    if auth.passwordFile != null then
      auth.passwordFile
    else if auth.password != null then
      pkgs.writeText "proxy-suite-wb-creator" auth.password
    else
      null;

  # Restart=always must not trip the start limit while the network or the platform is down.
  mkUnit = description: serviceConfig: {
    inherit description;
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    startLimitIntervalSec = 0;
    serviceConfig =
      unprivilegedServiceConfig [ ]
      // {
        Restart = "always";
        RestartSec = 5;
      }
      // serviceConfig;
  };

  mkJoiner =
    j:
    lib.nameValuePair "proxy-suite-wb-joiner-${j.tag}" (
      mkUnit "proxy-suite - whitelist-bypass joiner ${j.tag}" {
        ExecStart = pkgs.writeShellScript "proxy-suite-wb-joiner-${j.tag}" ''
          set -euo pipefail
          link=$(tr -d '[:space:]' < "$CREDENTIALS_DIRECTORY/link")
          exec ${w.package}/bin/headless-${j.platform}-joiner \
            ${joinerLinkFlag.${j.platform}} "$link" --socks-port ${toString j.port}
        '';
        LoadCredential = [ "link:${j.linkFile}" ];
      }
    );

  mkCreator =
    name: c:
    let
      viaProxy = c.upstream == "proxy";
      withProxyAuth = viaProxy && derived.localProxy.authEnabled;
      unit = mkUnit "proxy-suite - whitelist-bypass creator ${name}" {
        ExecStart = pkgs.writeShellScript "proxy-suite-wb-creator-${name}" ''
          set -euo pipefail
          cookies="$STATE_DIRECTORY/${name}.cookies.json"
          links="$STATE_DIRECTORY/${name}.link"
          [ -e "$cookies" ] || install -m 600 "$CREDENTIALS_DIRECTORY/cookies" "$cookies"
          args=(--cookies "$cookies" --write-file "$links" --resources ${c.resources})
          ${
            if c.linkFile != null then
              ''link=$(tr -d '[:space:]' < "$CREDENTIALS_DIRECTORY/link")''
            else
              ''link=$(tail -n 1 "$links" 2>/dev/null || true)''
          }
          [ -z "$link" ] || args+=(${linkFlag.${c.platform}} "$link")
          ${lib.optionalString viaProxy ''
            args+=(--upstream-socks ${derived.localProxy.hostPart}:${toString cfg.proxy.listener.port})
          ''}${lib.optionalString withProxyAuth ''
            args+=(--upstream-user ${lib.escapeShellArg auth.username} --upstream-pass "$(< "$CREDENTIALS_DIRECTORY/proxy-password")")
          ''}
          exec ${w.package}/bin/headless-${c.platform}-creator "''${args[@]}"
        '';
        StateDirectory = "proxy-suite/whitelist-bypass";
        StateDirectoryMode = "0700";
        LoadCredential = [
          "cookies:${c.cookiesFile}"
        ]
        ++ lib.optional (c.linkFile != null) "link:${c.linkFile}"
        ++ lib.optional withProxyAuth "proxy-password:${passwordSource}";
      };
    in
    lib.nameValuePair "proxy-suite-wb-creator-${name}" (
      unit // lib.optionalAttrs viaProxy { after = unit.after ++ [ "proxy-suite-socks.service" ]; }
    );
in
{
  services.proxy-suite.internal.services = lib.listToAttrs (
    map mkJoiner derived.whitelistBypassJoiners ++ lib.mapAttrsToList mkCreator w.creators
  );
}
