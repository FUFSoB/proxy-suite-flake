# A WireGuard profile as a sing-box endpoint in its own process, behind a loopback SOCKS
# listener the proxy outbound dials: the WARP tunnel and AmneziaWG profiles with
# asOutbound = "singBox".
{
  lib,
  pkgs,
  cfg,
  derived,
}:

let
  inherit (derived.constants) serviceUser runAsServiceUser;
  scriptsDir = builtins.path {
    name = "proxy-suite-scripts";
    path = ../../scripts;
  };

  # sing-box's "local" server has no upstream on hosts behind systemd-resolved, so the tunnel
  # resolves the peer hostname like the main config, with proxy.dns.local. Destinations are
  # resolved through the tunnel itself, with proxy.dns.remote.
  dnsServer = tag: upstream: {
    inherit tag;
    type = upstream.type;
    server = upstream.address;
    server_port = upstream.port;
  };
  mark = cfg.proxy.tproxy.proxyMark;
  probe = port: url: ''
    ${pkgs.curl}/bin/curl -s --noproxy "" -x socks5h://127.0.0.1:${toString port} -m "$timeout" \
      -o /dev/null ${url}'';

  # Some lines drop a share of fresh handshakes for good, and sing-box retries on the same
  # source port forever. A new process binds a new port, so the watchdog exits when the peer
  # stops answering and systemd starts the tunnel again. A healthy handshake takes a fraction
  # of a second, so a start gets 15 seconds; a running tunnel gets three misses. The
  # "direct-in" listener reaches Cloudflare through the uplink with the backend's mark (not
  # urlTest.url, which is picked to be blocked here): when that fails too, the tunnel could
  # not work from a new port either.
  mkWatchdog =
    {
      tag,
      tunnelPort,
      directPort,
    }:
    pkgs.writeShellScript "proxy-suite-wg-tunnel" ''
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
        if ${probe tunnelPort "-f ${lib.escapeShellArg cfg.proxy.urlTest.url}"}; then
          (( healthy )) || echo "proxy-suite: ${tag} is answering" >&2
          healthy=1 failures=0 uplink_down=0
          continue
        fi
        if ! ${probe directPort "https://1.1.1.1/cdn-cgi/trace"}; then
          (( uplink_down )) || echo "proxy-suite: the uplink is down; waiting for it before judging ${tag}" >&2
          uplink_down=1 failures=0 since=$SECONDS
          continue
        fi
        uplink_down=0
        if (( healthy ? ++failures >= 3 : SECONDS - since >= 15 )); then
          echo "proxy-suite: ${tag} is not answering; restarting the tunnel on a new source port" >&2
          kill "$singbox"
          wait "$singbox"
          exit 1
        fi
      done
    '';

  # `profile` is a shell snippet, run as root, that sets $profile to the WireGuard .conf.
  mkTunnel =
    {
      description,
      unit,
      tag,
      profile,
      tunnelPort,
      directPort,
    }:
    let
      tunnelScript = pkgs.writeShellScript "proxy-suite-wg-tunnel" ''
        set -euo pipefail
        ${profile}

        # The profile is a secret, so it is converted here, as root, rather than baked into
        # the store; sing-box itself runs as ${serviceUser}.
        endpoint=$(${pkgs.python3}/bin/python3 ${scriptsDir}/warp_outbound.py --tag ${tag} --routing-mark ${toString mark} < "$profile")
        (umask 027 && ${pkgs.jq}/bin/jq -n --argjson ep "$endpoint" '{
          log: {level: "warn"},
          dns: {servers: [
            ${builtins.toJSON (dnsServer "local" cfg.proxy.dns.local)},
            (${builtins.toJSON (dnsServer "remote" cfg.proxy.dns.remote)} + {detour: "${tag}", domain_resolver: "local"})
          ]},
          route: {
            default_domain_resolver: "remote",
            rules: [{inbound: ["direct-in"], outbound: "direct"}],
            final: "${tag}"
          },
          inbounds: [
            {type: "socks", tag: "socks-in", listen: "127.0.0.1", listen_port: ${toString tunnelPort}},
            {type: "socks", tag: "direct-in", listen: "127.0.0.1", listen_port: ${toString directPort}}
          ],
          outbounds: [{type: "direct", tag: "direct", routing_mark: ${toString mark}}],
          endpoints: [$ep + {domain_resolver: "local"}]
        }' > "$RUNTIME_DIRECTORY/config.json")
        ${pkgs.coreutils}/bin/chgrp ${serviceUser} "$RUNTIME_DIRECTORY" "$RUNTIME_DIRECTORY/config.json"

        exec ${runAsServiceUser pkgs [ "net_admin" ]} ${mkWatchdog { inherit tag tunnelPort directPort; }}
      '';
    in
    {
      inherit description;
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
        RuntimeDirectory = unit;
        RuntimeDirectoryMode = "0750";
        UMask = "0077";
      };
    };
in
{
  inherit mkTunnel;
}
