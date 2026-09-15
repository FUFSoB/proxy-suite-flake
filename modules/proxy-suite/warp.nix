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
  inherit (derived.constants) serviceUser runAsServiceUser unprivilegedServiceConfig;
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
  withProxyAuth = auth.username != null && passwordSource != null;
  userinfo = lib.optionalString withProxyAuth ''
    userinfo=$(${pkgs.jq}/bin/jq -rn --arg u ${lib.escapeShellArg auth.username} \
      --rawfile p "$CREDENTIALS_DIRECTORY/proxy-password" '"\($u | @uri):\($p | rtrimstr("\n") | @uri)@"')
  '';

  registerScript = pkgs.writeShellScript "proxy-suite-warp" ''
    set -euo pipefail
    [ -s wgcf-profile.conf ] && exit 0

    register() {
      [ -s wgcf-account.toml ] || wgcf register --accept-tos
      wgcf generate
    }
    ${lib.optionalString (w.generatorUrl != null) ''

      # Fallback: a third-party generator registers from abroad and hands the profile back.
      # curl follows HTTPS_PROXY when it is set.
      generate() {
        body=$(${pkgs.curl}/bin/curl -fsS --max-time 60 -A proxy-suite \
          ${lib.escapeShellArg w.generatorUrl}) || return 1
        case "$body" in
          "[Interface]"*) printf '%s\n' "$body" ;;
          *) ${pkgs.jq}/bin/jq -er '.content | @base64d' <<< "$body" ;;
        esac > wgcf-profile.conf.tmp || { rm -f wgcf-profile.conf.tmp; return 1; }
        grep -q '^PrivateKey' wgcf-profile.conf.tmp || { rm -f wgcf-profile.conf.tmp; return 1; }
        mv wgcf-profile.conf.tmp wgcf-profile.conf
      }
    ''}
    ${
      let
        fallbacks = lib.optionalString (w.generatorUrl != null) " || generate";
      in
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
          proxied() {
            HTTPS_PROXY="socks5://''${userinfo}${hostPart}:${toString listener.port}" "$@"
          }
          proxied register || register${fallbacks}${
            lib.optionalString (w.generatorUrl != null) " || proxied generate"
          }
        ''
      else
        "register${fallbacks}"
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
  mark = cfg.proxy.tproxy.proxyMark;
  probe = port: url: ''
    ${pkgs.curl}/bin/curl -s --noproxy "" -x socks5h://127.0.0.1:${toString port} -m "$timeout" \
      -o /dev/null ${url}'';

  # Some lines drop a share of fresh WARP handshakes for good, and sing-box retries on the
  # same source port forever. A new process binds a new port, so the watchdog exits when
  # WARP stops answering and systemd starts the tunnel again. A healthy WARP handshake takes
  # a fraction of a second, so a start gets 15 seconds; a running tunnel gets three misses.
  # The "direct-in" listener reaches Cloudflare through the uplink with the backend's mark (not
  # urlTest.url, which is picked to be blocked here): when that fails too, WARP could not work
  # from a new port either.
  watchdogScript = pkgs.writeShellScript "proxy-suite-warp" ''
    set -uo pipefail
    ${cfg.proxy.singBox.package}/bin/sing-box run -c "$RUNTIME_DIRECTORY/config.json" &
    singbox=$!

    healthy=0
    failures=0
    uplink_down=0
    since=0
    while sleep $(( healthy ? 10 : 2 )); do
      kill -0 "$singbox" 2>/dev/null || { wait "$singbox"; exit 1; }
      timeout=$(( healthy ? 10 : 4 ))
      if ${probe w.tunnelPort "-f ${lib.escapeShellArg cfg.proxy.urlTest.url}"}; then
        (( healthy )) || echo "proxy-suite: WARP is answering" >&2
        healthy=1 failures=0 uplink_down=0
        continue
      fi
      if ! ${probe w.directPort "https://1.1.1.1/cdn-cgi/trace"}; then
        (( uplink_down )) || echo "proxy-suite: the uplink is down; waiting for it before judging WARP" >&2
        uplink_down=1 failures=0 since=$SECONDS
        continue
      fi
      uplink_down=0
      if (( healthy ? ++failures >= 3 : SECONDS - since >= 15 )); then
        echo "proxy-suite: WARP is not answering; restarting the tunnel on a new source port" >&2
        kill "$singbox"
        wait "$singbox"
        exit 1
      fi
    done
  '';

  tunnelScript = pkgs.writeShellScript "proxy-suite-warp" ''
    set -euo pipefail
    profile=${lib.escapeShellArg w.profilePath}
    if [ ! -s "$profile" ]; then
      echo "proxy-suite: waiting for the WARP profile at $profile" >&2
      until [ -s "$profile" ]; do sleep 5; done
    fi

    # The profile is a secret, so it is converted here, as root, rather than baked into
    # the store; sing-box itself runs as ${serviceUser}.
    endpoint=$(${pkgs.python3}/bin/python3 ${scriptsDir}/warp_outbound.py --tag warp --routing-mark ${toString mark} < "$profile")
    (umask 027 && ${pkgs.jq}/bin/jq -n --argjson ep "$endpoint" '{
      log: {level: "warn"},
      dns: {servers: [${builtins.toJSON dnsServer}]},
      route: {
        default_domain_resolver: "local",
        rules: [{inbound: ["direct-in"], outbound: "direct"}],
        final: "warp"
      },
      inbounds: [
        {type: "socks", tag: "socks-in", listen: "127.0.0.1", listen_port: ${toString w.tunnelPort}},
        {type: "socks", tag: "direct-in", listen: "127.0.0.1", listen_port: ${toString w.directPort}}
      ],
      outbounds: [{type: "direct", tag: "direct", routing_mark: ${toString mark}}],
      endpoints: [$ep]
    }' > "$RUNTIME_DIRECTORY/config.json")
    ${pkgs.coreutils}/bin/chgrp ${serviceUser} "$RUNTIME_DIRECTORY" "$RUNTIME_DIRECTORY/config.json"

    exec ${runAsServiceUser pkgs [ "net_admin" ]} ${watchdogScript}
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
          RuntimeDirectoryMode = "0750";
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
        serviceConfig = unprivilegedServiceConfig [ ] // {
          Type = "simple";
          RemainAfterExit = true;
          Restart = "on-failure";
          RestartSec = 30;
          StateDirectory = "proxy-suite/warp";
          StateDirectoryMode = "0700";
          WorkingDirectory = "/var/lib/proxy-suite/warp";
          UMask = "0077";
          LoadCredential = lib.optional (cfg.proxy.enable && withProxyAuth) "proxy-password:${passwordSource}";
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
