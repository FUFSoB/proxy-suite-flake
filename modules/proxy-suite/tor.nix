# The Tor daemon: the SOCKS listener behind the "tor" outbound, and the onion service in front
# of the inbounds.
{
  lib,
  pkgs,
  cfg,
  derived,
}:

let
  t = derived.torCfg;
  inherit (derived.constants) torUser;
  # As the service user's, but Tor's own user: shares nothing with the inbounds or backend.
  unprivilegedServiceConfig =
    caps:
    derived.constants.unprivilegedServiceConfig caps
    // lib.optionalAttrs privileged {
      User = torUser;
      Group = torUser;
    };
  inherit (cfg.host) privileged;

  inherit (derived.localProxy) auth;
  listener = cfg.proxy.listener;
  proxyHost = derived.localProxy.host;
  proxyHostPart = derived.localProxy.hostPart;
  passwordSource =
    if auth.passwordFile != null then
      auth.passwordFile
    else if auth.password != null then
      pkgs.writeText "proxy-suite-tor" auth.password
    else
      null;
  viaProxy = t.upstream == "proxy";
  withProxyAuth = viaProxy && derived.localProxy.authEnabled;
  bridgesEnabled = t.bridges.lines != [ ] || t.bridges.file != null;
  # A torrc string: Tor unescapes \\ and \" inside the quotes.
  torQuote = s: ''"${builtins.replaceStrings [ "\\" "\"" ] [ "\\\\" "\\\"" ] s}"'';

  # The control socket is Tor's own user's: userControl's group asks for a new identity
  # through proxy-suite-tor-newnym instead.
  controlSocket = derived.constants.torControlSocket;
  newnymScript = pkgs.writeShellScript "proxy-suite-tor-newnym" ''
    set -euo pipefail
    reply=$(printf 'AUTHENTICATE\r\nSIGNAL NEWNYM\r\nQUIT\r\n' \
      | ${pkgs.socat}/bin/socat -t 5 - UNIX-CONNECT:${lib.escapeShellArg controlSocket})
    # One "250 OK" each for AUTHENTICATE and SIGNAL.
    if [ "$(${pkgs.gnugrep}/bin/grep -c '^250 OK' <<< "$reply")" -lt 2 ]; then
      printf 'Tor refused: %s\n' "$reply" >&2
      exit 1
    fi
  '';

  # An onion service port per listener: its share port, forwarded to where XRay listens.
  onionTarget =
    l:
    let
      addr =
        if
          builtins.elem l.address [
            "::"
            "0.0.0.0"
            "localhost"
          ]
        then
          "127.0.0.1"
        else
          l.address;
    in
    "${if lib.hasInfix ":" addr then "[${addr}]" else addr}:${toString l.port}";
  onionPorts = map (ib: {
    virtual = if ib.listener.sharePort != null then ib.listener.sharePort else ib.listener.port;
    target = onionTarget ib.listener;
  }) derived.torOnionInbounds;

  staticConfig = (
    lib.concatStringsSep "\n" (
      [
        "GeoIPFile ${t.package.geoip}/share/tor/geoip"
        "GeoIPv6File ${t.package.geoip}/share/tor/geoip6"
        "ClientUseIPv6 1"
        "AvoidDiskWrites 1"
        "Log notice stdout"
        # Names come in over SOCKS unresolved; nothing here resolves for the host.
        "AutomapHostsOnResolve 0"
        "DNSPort 0"
        "TransPort 0"
        "NATDPort 0"
        "CookieAuthentication 0"
      ]
      ++ lib.optional t.clientOnly "ClientOnly 1"
      ++ (if t.asOutbound then [ "SocksPort 127.0.0.1:${toString t.socksPort}" ] else [ "SocksPort 0" ])
      ++ lib.optionals bridgesEnabled [
        "UseBridges 1"
        "ClientTransportPlugin obfs4,webtunnel,meek_lite exec ${t.lyrebirdPackage}/bin/lyrebird"
        "ClientTransportPlugin snowflake exec ${t.snowflakePackage}/bin/client"
      ]
      ++ lib.optional viaProxy "Socks5Proxy ${proxyHostPart}:${toString listener.port}"
      ++ map (line: "Bridge ${line}") t.bridges.lines
    )
  );

  # Before ExecStart, which is when proxy-suite-inbounds may start reading the hostname: a
  # stale one must be gone by then.
  onionKeyScript = pkgs.writeShellScript "proxy-suite-tor-onion-key" ''
    set -euo pipefail
    umask 0077
    # Tor wants the service directory private to it.
    ${pkgs.coreutils}/bin/install -d -m 0700 "$STATE_DIRECTORY/onion"
    if ! ${pkgs.diffutils}/bin/cmp -s "$CREDENTIALS_DIRECTORY/onion-secret-key" "$STATE_DIRECTORY/onion/hs_ed25519_secret_key"; then
      # Another key: the old address and its public key must not be served with it.
      ${pkgs.coreutils}/bin/rm -f "$STATE_DIRECTORY/onion/hs_ed25519_public_key" "$STATE_DIRECTORY/onion/hostname"
      ${pkgs.coreutils}/bin/install -m 0600 "$CREDENTIALS_DIRECTORY/onion-secret-key" \
        "$STATE_DIRECTORY/onion/hs_ed25519_secret_key"
    fi
  '';
  onionKeyEnabled = derived.torOnionEnabled && t.onionService.secretKeyFile != null;

  startScript = pkgs.writeShellScript "proxy-suite-tor" ''
    set -euo pipefail
    umask 0077

    torrc="$RUNTIME_DIRECTORY/torrc"
    ${pkgs.coreutils}/bin/mkdir -p -m 0700 "$RUNTIME_DIRECTORY/control"
    {
      cat <<'TORRC'
    ${staticConfig}
    TORRC
      echo "DataDirectory $STATE_DIRECTORY"
      echo "ControlSocket unix:$RUNTIME_DIRECTORY/control/socket"
      ${lib.optionalString withProxyAuth ''
        # Quoted: bare, a "#" would start a comment, a leading quote open a string and a
        # trailing backslash join the next line on.
        echo ${lib.escapeShellArg "Socks5ProxyUsername ${torQuote auth.username}"}
        password=$(${pkgs.coreutils}/bin/head -n1 "$CREDENTIALS_DIRECTORY/proxy-password")
        password=''${password//\\/\\\\}
        printf 'Socks5ProxyPassword "%s"\n' "''${password//\"/\\\"}"
      ''}
      ${lib.optionalString (t.bridges.file != null) ''
        ${pkgs.gnused}/bin/sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' -e '/^#/d' \
          -e 's/^\(Bridge[[:space:]]\+\)\?/Bridge /' "$CREDENTIALS_DIRECTORY/bridges"
      ''}
      ${lib.optionalString derived.torOnionEnabled ''
        echo "HiddenServiceDir $STATE_DIRECTORY/onion"
        ${lib.concatMapStrings (p: ''
          echo ${lib.escapeShellArg "HiddenServicePort ${toString p.virtual} ${p.target}"}
        '') onionPorts}
      ''}
      cat ${pkgs.writeText "proxy-suite-torrc-extra" t.extraConfig}
    } > "$torrc"

    exec ${t.package}/bin/tor -f "$torrc"
  '';
in
{
  # Whatever the upstream: only its exemption from TUN and TProxy depends on it.
  services.proxy-suite.internal.systemUsers = lib.optional privileged torUser;

  services.proxy-suite.internal.services.proxy-suite-tor = {
    description = "proxy-suite - Tor";
    after = [ "network-online.target" ] ++ lib.optional viaProxy "proxy-suite-socks.service";
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    # Restart=always must not trip the start limit while the network is down.
    startLimitIntervalSec = 0;
    serviceConfig =
      unprivilegedServiceConfig [ ]
      // {
        Type = "simple";
        ExecStart = startScript;
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
        # Unless upstream = "proxy", its user is kept out of TUN and TProxy
        # (constants.ownTrafficUsers), and with it Tor's own connections.
        StateDirectory = "proxy-suite/tor";
        StateDirectoryMode = "0700";
        RuntimeDirectory = "proxy-suite-tor";
        RuntimeDirectoryMode = "0711";
        # Copies the service user can read, whoever owns the originals.
        LoadCredential =
          lib.optional withProxyAuth "proxy-password:${passwordSource}"
          ++ lib.optional (t.bridges.file != null) "bridges:${t.bridges.file}"
          ++ lib.optional onionKeyEnabled "onion-secret-key:${t.onionService.secretKeyFile}";
        Restart = "always";
        RestartSec = 5;
        LimitNOFILE = 65536;
      }
      // lib.optionalAttrs onionKeyEnabled { ExecStartPre = onionKeyScript; };
  };

  # `proxy-ctl tor newnym` for userControl's group ("services" scope), which cannot open
  # the control socket. As Tor's own user: root without capabilities could not even enter
  # the 0700 control directory.
  services.proxy-suite.internal.services.proxy-suite-tor-newnym = lib.mkIf privileged {
    description = "proxy-suite - new Tor circuits for new connections";
    after = [ "proxy-suite-tor.service" ];
    # Only a running Tor: this never starts one.
    unitConfig.Requisite = [ "proxy-suite-tor.service" ];
    serviceConfig = unprivilegedServiceConfig [ ] // {
      Type = "oneshot";
      ExecStart = newnymScript;
      # A filesystem socket is all it opens.
      RestrictAddressFamilies = [ "AF_UNIX" ];
    };
  };
}
