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
  inherit (derived.constants) unprivilegedServiceConfig privileged serviceUser;
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

  # Logins, calls and the links joiners take at runtime (`proxy-ctl wl auth|join|new`); the
  # whitelistBypass scope's group writes them too. tmpfiles makes it before any unit has run,
  # so a creator or joiner that waits on a file there can be given one.
  groupAccess = privileged && derived.userControlAllows "whitelistBypass";
  stateDir = "${derived.constants.stateDir}/whitelist-bypass";
  stateMode = if groupAccess then "0770" else "0700";
  stateGroup = if groupAccess then cfg.userControl.group else serviceUser;
  # A runtime file the unit cannot start without, when nothing in the configuration stands in.
  waitFor = file: {
    unitConfig.ConditionPathExists = "%S/proxy-suite/whitelist-bypass/${file}";
  };

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
        StateDirectory = "proxy-suite/whitelist-bypass";
        StateDirectoryMode = stateMode;
      }
      // lib.optionalAttrs groupAccess { Group = stateGroup; }
      // serviceConfig;
  };

  # The link `wl join` gave it wins over linkFile.
  mkJoiner =
    j:
    lib.nameValuePair "proxy-suite-wb-joiner-${j.tag}" (
      mkUnit "proxy-suite - whitelist-bypass joiner ${j.tag}" {
        ExecStart = pkgs.writeShellScript "proxy-suite-wb-joiner-${j.tag}" ''
          set -euo pipefail
          join="$STATE_DIRECTORY/${j.tag}.join"
          ${lib.optionalString (j.linkFile != null) ''[ -e "$join" ] || join="$CREDENTIALS_DIRECTORY/link"''}
          link=$(tr -d '[:space:]' < "$join")
          exec ${w.package}/bin/headless-${j.platform}-joiner \
            ${joinerLinkFlag.${j.platform}} "$link" --socks-port ${toString j.port}
        '';
        LoadCredential = lib.optional (j.linkFile != null) "link:${j.linkFile}";
      }
      // lib.optionalAttrs (j.linkFile == null) (waitFor "${j.tag}.join")
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
          ${lib.optionalString (c.cookiesFile != null) ''
            [ -e "$cookies" ] || install -m 600 "$CREDENTIALS_DIRECTORY/cookies" "$cookies"
          ''}
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
        LoadCredential =
          lib.optional (c.cookiesFile != null) "cookies:${c.cookiesFile}"
          ++ lib.optional (c.linkFile != null) "link:${c.linkFile}"
          ++ lib.optional withProxyAuth "proxy-password:${passwordSource}";
      };
    in
    lib.nameValuePair "proxy-suite-wb-creator-${name}" (
      unit
      // lib.optionalAttrs viaProxy { after = unit.after ++ [ "proxy-suite-socks.service" ]; }
      # Without a login it has nothing to run on until `proxy-ctl wl auth` writes one.
      // lib.optionalAttrs (c.cookiesFile == null) (waitFor "${name}.cookies.json")
    );
in
{
  services.proxy-suite.internal = {
    services = lib.listToAttrs (
      map mkJoiner derived.whitelistBypassJoiners ++ lib.mapAttrsToList mkCreator w.creators
    );
    tmpfiles = [
      "d ${stateDir} ${stateMode} ${if privileged then "${serviceUser} ${stateGroup}" else "- -"} -"
    ];
  };
}
