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
  inherit (derived.constants)
    unprivilegedServiceConfig
    privileged
    serviceUser
    ;
  inherit (derived.localProxy) auth;

  # A file in the state directory, which the whitelistBypass scope's group writes to: a
  # regular file only, never through a symlink, which could name the backend's config
  # (the daemon reads it) and have its credentials on a command line.
  readState = file: "${pkgs.coreutils}/bin/dd if=${file} iflag=nofollow,nonblock status=none";

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
  # Groups in userControl.groups get it through ACLs (proxy-suite-acls), which the mode must
  # leave open: systemd applies it on every start.
  groupAccess = privileged && derived.userControlAnyAllows "whitelistBypass";
  stateDir = "${derived.constants.stateDir}/whitelist-bypass";
  stateMode = if groupAccess then "0770" else "0700";
  # The creators' logins, which they rewrite as they run: the daemon's alone, out of the
  # group's directory.
  sessionsDir = "${derived.constants.stateDir}/whitelist-bypass-sessions";
  stateGroup =
    if privileged && derived.userControlAllows "whitelistBypass" then
      cfg.userControl.group
    else
      serviceUser;
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
        RestartSteps = 5;
        RestartMaxDelaySec = 120;
        StateDirectory = "proxy-suite/whitelist-bypass";
        StateDirectoryMode = stateMode;
      }
      # The group writes the state directory: whatever a name there points at, the daemon
      # writes nowhere else but the creators' sessions ("-": none without creators).
      // lib.optionalAttrs privileged {
        ProtectSystem = "strict";
        ReadWritePaths = [ "-${sessionsDir}" ];
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
          # The link from the environment (pkgs/whitelist-bypass.nix): argv is public.
          WB_LINK=$(${readState ''"$join"''} | tr -d '[:space:]')
          export WB_LINK
          # Its listener takes the hop login, which the backend dials it with; the password
          # from the environment as well.
          WB_SOCKS_PASS=$(< ${lib.escapeShellArg derived.constants.hopLoginFile})
          export WB_SOCKS_PASS
          exec ${w.package}/bin/headless-${j.platform}-joiner --socks-port ${toString j.port} \
            --socks-user ${derived.constants.hopUser}
        '';
        # Root draws it, where nothing has yet this boot (the daemon cannot write there).
        ExecStartPre = "+${derived.constants.ensureHopLogin pkgs}";
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
          shared="$STATE_DIRECTORY/${name}.cookies.json"
          cookies=${lib.escapeShellArg "${sessionsDir}/${name}.cookies.json"}
          links="$STATE_DIRECTORY/${name}.link"
          umask 077
          # A login `proxy-ctl wl auth` left replaces the working copy, read without following
          # a symlink, then goes: what the creator refreshes is the copy's.
          if [ -L "$shared" ]; then
            rm -f -- "$shared"
          elif [ -f "$shared" ]; then
            ${readState ''"$shared"''} > "$cookies.new"
            mv -f -- "$cookies.new" "$cookies"
            rm -f -- "$shared"
          fi
          ${lib.optionalString (c.cookiesFile != null) ''
            [ -e "$cookies" ] || install -m 600 "$CREDENTIALS_DIRECTORY/cookies" "$cookies"
          ''}
          args=(--cookies "$cookies" --write-file "$links" --resources ${c.resources})
          ${
            if c.linkFile != null then
              ''link=$(tr -d '[:space:]' < "$CREDENTIALS_DIRECTORY/link")''
            else
              "link=$(${readState ''"$links"''} 2>/dev/null | tail -n 1 || true)"
          }
          # From the environment (pkgs/whitelist-bypass.nix): argv is public.
          export WB_LINK="$link"
          ${lib.optionalString viaProxy ''
            args+=(--upstream-socks ${derived.localProxy.hostPart}:${toString cfg.proxy.listener.port})
          ''}${lib.optionalString withProxyAuth ''
            args+=(--upstream-user ${lib.escapeShellArg auth.username})
            # The package reads it from here (pkgs/whitelist-bypass.nix): argv is public.
            WB_UPSTREAM_PASS="$(< "$CREDENTIALS_DIRECTORY/proxy-password")"
            export WB_UPSTREAM_PASS
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
      # Without a login it has nothing to run on until `proxy-ctl wl auth` writes one, or
      # one is in its working copy already.
      // lib.optionalAttrs (c.cookiesFile == null) {
        unitConfig.ConditionPathExists = [
          "|%S/proxy-suite/whitelist-bypass/${name}.cookies.json"
          "|${sessionsDir}/${name}.cookies.json"
        ];
      }
    );
in
{
  services.proxy-suite.internal = {
    services = lib.listToAttrs (
      map mkJoiner derived.whitelistBypassJoiners ++ lib.mapAttrsToList mkCreator w.creators
    );
    tmpfiles = [
      "d ${stateDir} ${stateMode} ${if privileged then "${serviceUser} ${stateGroup}" else "- -"} -"
    ]
    ++
      lib.optional (w.creators != { })
        "d ${sessionsDir} 0700 ${if privileged then "${serviceUser} ${serviceUser}" else "- -"} -";
  };
}
