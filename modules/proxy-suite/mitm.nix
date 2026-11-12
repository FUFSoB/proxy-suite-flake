# mitmproxy: behind the "mitm" outbound with the proxy on, whose backend also takes back what
# it has read (mitm.returnPort); a proxy of its own without.
{
  lib,
  pkgs,
  cfg,
  derived,
}:

let
  m = derived.mitmCfg;
  inherit (derived) constants;
  inherit (constants) mitmUser;
  inherit (cfg.host) privileged;
  outbound = derived.mitmOutboundEnabled;
  # As the service user's, but mitmproxy's own user: the CA's key and what it decrypts are
  # not the backends' to read, nor their credentials its.
  unprivilegedServiceConfig =
    caps:
    constants.unprivilegedServiceConfig caps
    // lib.optionalAttrs privileged {
      User = mitmUser;
      Group = mitmUser;
    };

  # mitm.requestLog's addon.
  requestLogAddon = "${import ./lib/scripts-dir.nix { inherit lib; }}/mitm_request_log.py";
  # Its log, for whoever holds the mitm scope, as mitmweb's password is: mitmweb shows them
  # the same. userControl.group owns the directory; the other groups get ACLs.
  logGroupOwns = privileged && derived.userControlAllows "mitm";
  logShared = privileged && derived.userControlAnyAllows "mitm";
  logDirOwner =
    if !privileged then
      "-m 0700"
    else if logGroupOwns then
      "-m 2750 -o ${mitmUser} -g ${lib.escapeShellArg derived.userControlCfg.group}"
    else if logShared then
      "-m 0750 -o ${mitmUser} -g ${mitmUser}"
    else
      "-m 0700 -o ${mitmUser} -g ${mitmUser}";

  coreutils = "${pkgs.coreutils}/bin";
  jq = "${pkgs.jq}/bin/jq";
  openssl = "${pkgs.openssl}/bin/openssl";
  userControlGroups = derived.userControlExtraGroupsFor "mitm";
  # What mitmproxy's own user is handed, in its state directory: `install` replaces the
  # name, never writes through what is there.
  give = lib.optionalString privileged "-o ${mitmUser} -g ${mitmUser} ";

  # Each a pattern mitmproxy searches "host:port" for.
  hostPattern = host: "(^|\\.)${lib.escapeRegex host}(:[0-9]+)?$";

  # What does not depend on the host's state.
  staticOptions = {
    mode =
      if outbound then
        [ "upstream:http://127.0.0.1:${toString m.returnPort}@127.0.0.1:${toString m.port}" ]
      else
        [
          "regular@${
            if lib.hasInfix ":" m.listener.address then "[${m.listener.address}]" else m.listener.address
          }:${toString m.listener.port}"
        ];
    ignore_hosts = map hostPattern m.ignoreHosts;
    web_host = "127.0.0.1";
    web_port = m.web.port;
    web_open_browser = false;
  };

  # As root where there is one: the hop login is the daemons' and the settings the
  # userControl groups', neither mitmproxy's user's to read where they lie. Nothing is
  # written through a name either of them could have left: `install` replaces it.
  stageScript = pkgs.writeShellScript "proxy-suite-mitm-stage" ''
    set -euo pipefail
    umask 0077
    state="$STATE_DIRECTORY"
    hand() {
      ${coreutils}/install ${give}-m 0600 /dev/stdin "$state/$1"
    }
    ${lib.optionalString outbound ''
      ${constants.ensureHopLogin pkgs}
      hand hop-login < ${lib.escapeShellArg constants.hopLoginFile}
    ''}
    settings=${lib.escapeShellArg constants.mitmSettingsFile}
    if [ -f "$settings" ] && [ ! -L "$settings" ] \
      && ${jq} -e 'type == "object"' "$settings" > /dev/null 2>&1; then
      hand settings.json < "$settings"
    else
      ${coreutils}/rm -f "$state/settings.json"
    fi
    # mitmweb's password: the one given, or one drawn once and kept.
    ${
      if m.web.passwordFile != null then
        ''password=$(${coreutils}/head -n1 "$CREDENTIALS_DIRECTORY/web-password")''
      else
        ''
          kept="$state/web-password"
          if [ -f "$kept" ] && [ ! -L "$kept" ] && [ -s "$kept" ]; then
            password=$(${coreutils}/head -n1 "$kept")
          else
            password=$(${coreutils}/od -An -tx1 -N16 /dev/urandom | ${coreutils}/tr -d ' \n')
          fi
        ''
    }
    printf '%s' "$password" | hand web-password
    # And where `proxy-ctl mitm web` reads it.
    shown=${lib.escapeShellArg constants.mitmWebPasswordFile}
    printf '%s' "$password" | ${coreutils}/install -m 0600 /dev/stdin "$shown"
    ${lib.optionalString privileged ''
      ${lib.optionalString (derived.userControlAllows "mitm") ''
        ${coreutils}/chgrp ${lib.escapeShellArg derived.userControlCfg.group} "$shown"
        ${coreutils}/chmod 0640 "$shown"
      ''}
      ${constants.grantFileAcl pkgs ''"$shown"'' userControlGroups "r"}
    ''}
    # mitm.requestLog's directory, there whether or not it is on, as proxy-ctl may switch it.
    # Never through a name mitmproxy's user left: whatever is there but a directory goes.
    logdir=${lib.escapeShellArg m.requestLogDir}
    if [ -L "$logdir" ] || { [ -e "$logdir" ] && [ ! -d "$logdir" ]; }; then
      ${coreutils}/rm -f -- "$logdir"
    fi
    ${coreutils}/install -d ${logDirOwner} -- "$logdir"
    ${constants.grantDirAcl pkgs ''"$logdir"'' userControlGroups "rX"}
  '';

  # The CA mitmproxy signs with, and its public half for whatever is to trust it.
  caScript = pkgs.writeShellScript "proxy-suite-mitm-ca" ''
    set -euo pipefail
    umask 0077
    state="$STATE_DIRECTORY"
    public="$RUNTIME_DIRECTORY"
    ca="$state/mitmproxy-ca.pem"
    ${
      if m.ca.certFile != null then
        ''
          # Key first, as mitmproxy writes its own.
          ${coreutils}/cat "$CREDENTIALS_DIRECTORY/ca-key" "$CREDENTIALS_DIRECTORY/ca-cert" > "$ca.new"
          if ${pkgs.diffutils}/bin/cmp -s "$ca.new" "$ca"; then
            ${coreutils}/rm -f "$ca.new"
          else
            ${coreutils}/mv -f "$ca.new" "$ca"
          fi
        ''
      else
        ''
          if [ ! -s "$ca" ]; then
            ${openssl} req -x509 -new -nodes -newkey rsa:2048 -sha256 -days 3650 \
              -subj "/CN=proxy-suite mitm/O=proxy-suite" \
              -addext "basicConstraints=critical,CA:TRUE" \
              -addext "keyUsage=critical,keyCertSign,cRLSign" \
              -keyout "$state/ca.key.new" -out "$state/ca.crt.new" 2> /dev/null
            ${coreutils}/cat "$state/ca.key.new" "$state/ca.crt.new" > "$ca.new"
            ${coreutils}/rm -f "$state/ca.key.new" "$state/ca.crt.new"
            ${coreutils}/mv -f "$ca.new" "$ca"
          fi
        ''
    }
    # The certificate alone, as mitmproxy serves it on http://mitm.it and others read it.
    cert="$state/mitmproxy-ca-cert.pem"
    ${openssl} x509 -in "$ca" -out "$cert.new"
    ${coreutils}/mv -f "$cert.new" "$cert"
    ${coreutils}/cp -f "$cert" "$state/mitmproxy-ca-cert.cer"
    ${openssl} pkcs12 -export -nokeys -in "$cert" -passout pass: -out "$state/mitmproxy-ca-cert.p12"

    umask 0022
    ${coreutils}/install -m 0644 "$cert" "$public/ca.pem"
    # The system's CAs, the host's own additions among them, and this one.
    system=/etc/ssl/certs/ca-certificates.crt
    [ -r "$system" ] || system=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
    ${coreutils}/cat "$system" "$cert" > "$public/ca-bundle.pem.new"
    ${coreutils}/mv -f "$public/ca-bundle.pem.new" "$public/ca-bundle.pem"
    # Chromium's --ignore-certificate-errors-spki-list takes the key's hash.
    ${openssl} x509 -in "$cert" -pubkey -noout \
      | ${openssl} pkey -pubin -outform der \
      | ${openssl} dgst -sha256 -binary \
      | ${coreutils}/base64 > "$public/ca-spki"
    # Android names a system CA by its subject's old hash.
    ${coreutils}/rm -rf "$public/android"
    ${coreutils}/mkdir -p "$public/android"
    ${coreutils}/install -m 0644 "$cert" "$public/android/$(${openssl} x509 -in "$cert" -subject_hash_old -noout).0"
  '';

  startScript = pkgs.writeShellScript "proxy-suite-mitm" ''
    set -euo pipefail
    umask 0077
    state="$STATE_DIRECTORY"
    settings="$state/settings.json"
    [ -s "$settings" ] || settings=/dev/null

    # Secrets by their files' names: argv is public.
    secrets=(--rawfile web_password "$state/web-password")
    ${lib.optionalString outbound ''secrets+=(--rawfile hop "$state/hop-login")''}
    ${lib.optionalString (!outbound && derived.mitmListenerAuth) ''
      secrets+=(--rawfile listener_password "$CREDENTIALS_DIRECTORY/listener-password")
    ''}
    # mitm.requestLog's files, in the directory root made as it staged.
    log_file=${lib.escapeShellArg "${m.requestLogDir}/requests.jsonl"}
    flows_file=${lib.escapeShellArg "${m.requestLogDir}/requests.mitm"}
    # The options, then what proxy-ctl changed without a rebuild, then extraOptions.
    ${jq} -n \
      --argjson static ${lib.escapeShellArg (builtins.toJSON staticOptions)} \
      --argjson extra ${lib.escapeShellArg (builtins.toJSON m.extraOptions)} \
      --argjson web ${builtins.toJSON m.web.enable} \
      --argjson save ${builtins.toJSON m.saveFlows} \
      --argjson log ${builtins.toJSON m.requestLog.enable} \
      --argjson logHeaders ${builtins.toJSON m.requestLog.headers} \
      --argjson bodies ${builtins.toJSON m.requestLog.bodies} \
      --arg flowsFile "$flows_file" \
      --arg logAddon ${lib.escapeShellArg requestLogAddon} \
      --arg logFile "$log_file" \
      --argjson logMax ${toString (builtins.floor (m.requestLog.maxSizeMiB * 1024 * 1024))} \
      --argjson logShared ${builtins.toJSON logShared} \
      --slurpfile s "$settings" \
      --arg state "$state" \
      "''${secrets[@]}" \
      '
        ($s[0] // {}) as $runtime
        # `//` would take a false for a missing one.
        | def chosen($key; $default): if ($runtime[$key] | type) == "boolean" then $runtime[$key] else $default end;
        $static
        | .ignore_hosts += [
            ($runtime.ignoreHosts // [])[]
            | select(type == "string" and test("^[A-Za-z0-9._-]+$"))
            | "(^|\\.)" + gsub("\\."; "\\.") + "(:[0-9]+)?$"
          ]
        | if chosen("saveFlows"; $save) then .save_stream_file = "+" + $state + "/flows.mitm" else . end
        | chosen("requestLog"; $log) as $lines
        | chosen("requestBodies"; $bodies) as $whole
        | if $lines or $whole then
            .scripts = [$logAddon]
            | .request_log_max_bytes = $logMax
            | .request_log_group_read = $logShared
          else . end
        | if $lines then .request_log_file = $logFile | .request_log_headers = $logHeaders else . end
        | if $whole then .request_log_flows_file = $flowsFile else . end
        | .web_password = ($web_password | rtrimstr("\n"))
        ${lib.optionalString outbound ''| .upstream_auth = "${constants.hopUser}:" + ($hop | rtrimstr("\n"))''}
        ${lib.optionalString (!outbound && derived.mitmListenerAuth)
          ''| .proxyauth = ${builtins.toJSON m.listener.auth.username} + ":" + ($listener_password | split("\n")[0])''
        }
        # The scripts of extraOptions come after these, not instead of them.
        | ((.scripts // []) + ($extra.scripts // [])) as $scripts
        | {
            config: (. + $extra | if $scripts == [] then del(.scripts) else .scripts = $scripts end),
            web: chosen("web"; $web)
          }
      ' > "$state/config.json.new"
    web=$(${jq} -r '.web' "$state/config.json.new")
    # JSON, which YAML is a superset of.
    ${jq} '.config' "$state/config.json.new" > "$state/config.yaml.new"
    ${coreutils}/rm -f "$state/config.json.new"
    ${coreutils}/mv -f "$state/config.yaml.new" "$state/config.yaml"

    if [ "$web" = true ]; then
      exec ${m.package}/bin/mitmweb --set confdir="$state"
    fi
    exec ${m.package}/bin/mitmdump --set confdir="$state"
  '';
in
{
  services.proxy-suite.internal.systemUsers = lib.optional privileged mitmUser;

  services.proxy-suite.internal.firewall.allowedTCPPorts = lib.optional (
    m.listener.enable && m.listener.openFirewall
  ) m.listener.port;

  services.proxy-suite.internal.services.proxy-suite-mitm = {
    description = "proxy-suite - mitmproxy";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    # Restart=always must not trip the start limit while the network is down.
    startLimitIntervalSec = 0;
    serviceConfig = unprivilegedServiceConfig [ ] // {
      Type = "simple";
      ExecStartPre = [
        "+${stageScript}"
        caScript
      ];
      ExecStart = startScript;
      # mitmdump's line per request into the journal as it comes, not a buffer at a time.
      Environment = [ "PYTHONUNBUFFERED=1" ];
      # The CA's key, config.yaml with its logins, and saved flows.
      StateDirectory = "proxy-suite/mitm";
      StateDirectoryMode = "0700";
      # The CA's certificate, for anyone to read.
      RuntimeDirectory = "proxy-suite-mitm";
      RuntimeDirectoryMode = "0755";
      # Copies the service user can read, whoever owns the originals.
      LoadCredential =
        lib.optionals (m.ca.certFile != null) [
          "ca-cert:${m.ca.certFile}"
          "ca-key:${m.ca.keyFile}"
        ]
        ++ lib.optional (m.web.passwordFile != null) "web-password:${m.web.passwordFile}"
        ++ lib.optional (
          !outbound && derived.mitmListenerAuth
        ) "listener-password:${m.listener.auth.passwordFile}";
      Restart = "always";
      RestartSec = 5;
      LimitNOFILE = 65536;
    };
  };
}
