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
  inherit (derived.constants) unprivilegedServiceConfig;
  inherit (cfg.host) privileged;

  listener = cfg.proxy.listener;
  auth = listener.auth;
  # Tor dials the local proxy by address: a wildcard listener is reached on loopback.
  proxyHost =
    if
      builtins.elem listener.address [
        "0.0.0.0"
        "::"
      ]
    then
      "127.0.0.1"
    else
      listener.address;
  proxyHostPart = if lib.hasInfix ":" proxyHost then "[${proxyHost}]" else proxyHost;
  passwordSource =
    if auth.passwordFile != null then
      auth.passwordFile
    else if auth.password != null then
      pkgs.writeText "proxy-suite-tor" auth.password
    else
      null;
  viaProxy = t.upstream == "proxy";
  withProxyAuth = viaProxy && auth.username != null && passwordSource != null;
  bridgesEnabled = t.bridges.lines != [ ] || t.bridges.file != null;

  # The control socket's directory: members of userControl.group may use it for
  # `proxy-ctl tor status|newnym`, so it takes that group (setgid) on a system install.
  controlGroup = privileged && derived.userControlAllows "services";

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
        "ControlSocketsGroupWritable 1"
      ]
      ++ lib.optional t.clientOnly "ClientOnly 1"
      ++ (
        if t.asOutbound then
          [ "SocksPort 127.0.0.1:${toString t.socksPort}" ]
        else
          [ "SocksPort 0" ]
      )
      ++ lib.optionals bridgesEnabled [
        "UseBridges 1"
        "ClientTransportPlugin obfs4,webtunnel,meek_lite exec ${t.lyrebirdPackage}/bin/lyrebird"
        "ClientTransportPlugin snowflake exec ${t.snowflakePackage}/bin/client"
      ]
      ++ lib.optional viaProxy "Socks5Proxy ${proxyHostPart}:${toString listener.port}"
      ++ map (line: "Bridge ${line}") t.bridges.lines
    )
  );

  # Group-owned and setgid, so the socket tor creates in it is the group's.
  controlDirScript = pkgs.writeShellScript "proxy-suite-tor-control-dir" ''
    set -euo pipefail
    dir="$RUNTIME_DIRECTORY/control"
    ${pkgs.coreutils}/bin/install -d -m 2750 -o ${derived.constants.serviceUser} \
      -g ${lib.escapeShellArg cfg.userControl.group} "$dir"
  '';

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
        echo "Socks5ProxyUsername "${lib.escapeShellArg auth.username}
        printf 'Socks5ProxyPassword %s\n' "$(${pkgs.coreutils}/bin/head -n1 "$CREDENTIALS_DIRECTORY/proxy-password")"
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

    ${lib.optionalString (derived.torOnionEnabled && t.onionService.secretKeyFile != null) ''
      # Tor wants the service directory private to it.
      ${pkgs.coreutils}/bin/install -d -m 0700 "$STATE_DIRECTORY/onion"
      if ! ${pkgs.diffutils}/bin/cmp -s "$CREDENTIALS_DIRECTORY/onion-secret-key" "$STATE_DIRECTORY/onion/hs_ed25519_secret_key"; then
        # Another key: the old address and its public key must not be served with it.
        ${pkgs.coreutils}/bin/rm -f "$STATE_DIRECTORY/onion/hs_ed25519_public_key" "$STATE_DIRECTORY/onion/hostname"
        ${pkgs.coreutils}/bin/install -m 0600 "$CREDENTIALS_DIRECTORY/onion-secret-key" \
          "$STATE_DIRECTORY/onion/hs_ed25519_secret_key"
      fi
    ''}

    exec ${t.package}/bin/tor -f "$torrc"
  '';
in
{
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
        # The service user is excluded from TUN and TProxy capture, which is what keeps
        # tor's own connections out of the proxy.
        StateDirectory = "proxy-suite/tor";
        StateDirectoryMode = "0700";
        RuntimeDirectory = "proxy-suite-tor";
        RuntimeDirectoryMode = "0711";
        # Copies the service user can read, whoever owns the originals.
        LoadCredential =
          lib.optional withProxyAuth "proxy-password:${passwordSource}"
          ++ lib.optional (t.bridges.file != null) "bridges:${t.bridges.file}"
          ++ lib.optional (
            derived.torOnionEnabled && t.onionService.secretKeyFile != null
          ) "onion-secret-key:${t.onionService.secretKeyFile}";
        Restart = "always";
        RestartSec = 5;
        LimitNOFILE = 65536;
      }
      // lib.optionalAttrs controlGroup {
        ExecStartPre = "+${controlDirScript}";
      };
  };
}
