# Cloudflare WARP: the tunnel behind the "warp" outbound, the AmneziaWG profile and, without a
# configFile, wgcf registration.
{
  lib,
  pkgs,
  cfg,
  derived,
}:

let
  w = derived.warpCfg;
  listener = cfg.proxy.listener;
  auth = listener.auth;
  scriptsDir = builtins.path {
    name = "proxy-suite-scripts";
    path = ../../scripts;
  };
  host =
    if
      builtins.elem listener.address [
        "0.0.0.0"
        "::"
      ]
    then
      "127.0.0.1"
    else
      listener.address;
  hostPart = if lib.hasInfix ":" host then "[${host}]" else host;
  passwordSource =
    if auth.passwordFile != null then
      auth.passwordFile
    else if auth.password != null then
      pkgs.writeText "proxy-suite-warp" auth.password
    else
      null;
  userinfo = lib.optionalString (auth.username != null && passwordSource != null) ''
    userinfo=$(${pkgs.jq}/bin/jq -rn --arg u ${lib.escapeShellArg auth.username} \
      --rawfile p ${lib.escapeShellArg passwordSource} '"\($u | @uri):\($p | rtrimstr("\n") | @uri)@"')
  '';

  registerScript = pkgs.writeShellScript "proxy-suite-warp" ''
    set -euo pipefail
    [ -s wgcf-profile.conf ] && exit 0

    register() {
      [ -s wgcf-account.toml ] || wgcf register --accept-tos
      wgcf generate
    }

    ${
      if cfg.proxy.enable then
        ''
          # The API is blocked in some countries, so the local proxy goes first. It may
          # still be coming up, as when a switch restarts it alongside this unit.
          for _ in {1..30}; do
            (exec 3<>/dev/tcp/${host}/${toString listener.port}) 2>/dev/null && break
            sleep 1
          done
          userinfo=
          ${userinfo}
          HTTPS_PROXY="socks5://''${userinfo}${hostPart}:${toString listener.port}" register || register
        ''
      else
        "register"
    }
  '';

  # sing-box's "local" server has no upstream on hosts behind systemd-resolved, so the tunnel
  # resolves like the main config: the peer hostname and destinations go to proxy.dns.local.
  dnsServer = {
    tag = "local";
    type = cfg.proxy.dns.local.type;
    server = cfg.proxy.dns.local.address;
    server_port = cfg.proxy.dns.local.port;
  };

  # Some lines drop a share of fresh WARP handshakes for good, and sing-box retries on the
  # same source port forever. A new process binds a new port, so the probe exits after
  # repeated failures and systemd starts the tunnel again.
  tunnelScript = pkgs.writeShellScript "proxy-suite-warp" ''
    set -euo pipefail
    profile=${lib.escapeShellArg w.profilePath}
    if [ ! -s "$profile" ]; then
      echo "proxy-suite: waiting for the WARP profile at $profile" >&2
      until [ -s "$profile" ]; do sleep 5; done
    fi

    # The profile is a secret, so it is converted here rather than baked into the store.
    endpoint=$(${pkgs.python3}/bin/python3 ${scriptsDir}/warp_outbound.py --tag warp --routing-mark ${toString cfg.proxy.tproxy.proxyMark} < "$profile")
    ${pkgs.jq}/bin/jq -n --argjson ep "$endpoint" '{
      log: {level: "warn"},
      dns: {servers: [${builtins.toJSON dnsServer}]},
      route: {default_domain_resolver: "local", final: "warp"},
      inbounds: [{type: "socks", tag: "socks-in", listen: "127.0.0.1", listen_port: ${toString w.tunnelPort}}],
      endpoints: [$ep]
    }' > "$RUNTIME_DIRECTORY/config.json"

    ${cfg.proxy.singBox.package}/bin/sing-box run -c "$RUNTIME_DIRECTORY/config.json" &
    singbox=$!

    failures=0
    while sleep 10; do
      kill -0 "$singbox" 2>/dev/null || { wait "$singbox"; exit 1; }
      if ${pkgs.curl}/bin/curl -sf --noproxy "" -x socks5h://127.0.0.1:${toString w.tunnelPort} -m 10 -o /dev/null ${lib.escapeShellArg cfg.proxy.urlTest.url}; then
        failures=0
      elif (( ++failures >= 3 )); then
        echo "proxy-suite: WARP stopped answering; restarting the tunnel on a new source port" >&2
        exit 1
      fi
    done
  '';
in
{
  services.proxy-suite.amneziaWg.profiles = lib.mkIf w.asAmneziaWg {
    warp.configFile = w.profilePath;
  };

  systemd.services = lib.mkMerge [
    (lib.mkIf w.asOutbound {
      proxy-suite-warp-tunnel = {
        description = "proxy-suite - Cloudflare WARP tunnel behind the warp outbound";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        # Probe-triggered restarts must not trip the start limit.
        startLimitIntervalSec = 0;
        serviceConfig = {
          Type = "simple";
          ExecStart = tunnelScript;
          Restart = "always";
          RestartSec = 2;
          RuntimeDirectory = "proxy-suite-warp-tunnel";
          RuntimeDirectoryMode = "0700";
          UMask = "0077";
        };
      };
    })

    (lib.mkIf w.autoRegister {
      proxy-suite-warp = {
        description = "proxy-suite - register a Cloudflare WARP device with wgcf";
        after = [ "network-online.target" ] ++ lib.optional cfg.proxy.enable "proxy-suite-socks.service";
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        path = [ pkgs.wgcf ];
        # Retried until it registers. Not a oneshot: a slow or failed registration must not
        # hold up or fail a switch.
        startLimitIntervalSec = 0;
        serviceConfig = {
          Type = "simple";
          RemainAfterExit = true;
          Restart = "on-failure";
          RestartSec = 30;
          StateDirectory = "proxy-suite/warp";
          StateDirectoryMode = "0700";
          WorkingDirectory = "/var/lib/proxy-suite/warp";
          UMask = "0077";
          ExecStart = registerScript;
        };
      };

      # Only pulls registration in: a simple unit gives the profile no ordering guarantee.
      proxy-suite-awg-warp = lib.mkIf w.asAmneziaWg {
        wants = [ "proxy-suite-warp.service" ];
      };
    })
  ];
}
