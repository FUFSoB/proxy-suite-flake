# A WireGuard profile in its own process, behind a loopback SOCKS listener the proxy
# outbound dials: the WARP tunnel and AmneziaWG profiles with asOutbound = "singBox"
# (a sing-box endpoint) or "userspace" (wireproxy, which keeps AmneziaWG's obfuscation).
{
  lib,
  pkgs,
  cfg,
  derived,
}:

let
  inherit (derived.constants) serviceUser runAsServiceUser ifPrivileged;
  scriptsDir = import ./lib/scripts-dir.nix { inherit lib; };

  # sing-box's "local" server has no upstream on hosts behind systemd-resolved, so the tunnel
  # resolves the peer hostname like the main config, with proxy.dns.local. Destinations are
  # resolved through the tunnel itself, with proxy.dns.remote.
  dnsServer = tag: upstream: {
    inherit tag;
    type = upstream.type;
    server = upstream.address;
    server_port = upstream.port;
  };
  # Past TUN and TProxy. Setting a mark takes CAP_NET_ADMIN, which a rootless host lacks,
  # and has nothing to capture its traffic anyway.
  mark = if cfg.host.privileged then cfg.proxy.tproxy.proxyMark else null;
  probe = port: url: ''
    ${pkgs.curl}/bin/curl -s --noproxy "" -x socks5h://127.0.0.1:${toString port} -m "$timeout" \
      -o /dev/null ${url}'';

  # Some lines drop a share of fresh handshakes for good, and both engines retry on the
  # same source port forever. A new process binds a new port, so the watchdog exits when
  # the peer stops answering and the service manager starts the tunnel again. A healthy
  # handshake takes a fraction of a second, so a start gets 15 seconds; a running tunnel
  # gets three misses. sing-box's "direct-in" listener reaches Cloudflare through the uplink
  # with the backend's mark (not urlTest.url, which is picked to be blocked here): when that
  # fails too, the tunnel could not work from a new port either. wireproxy has no such
  # listener (directPort = null), so it is restarted either way.
  mkWatchdog =
    {
      tag,
      command,
      tunnelPort,
      directPort,
    }:
    pkgs.writeShellScript "proxy-suite-wg-tunnel" ''
      set -uo pipefail
      ${command} &
      tunnel=$!

      healthy=0
      failures=0
      uplink_down=0
      since=0
      while sleep $(( healthy ? 10 : 2 )); do
        kill -0 "$tunnel" 2>/dev/null || { wait "$tunnel"; exit 1; }
        timeout=$(( healthy ? 10 : 4 ))
        if ${probe tunnelPort "-f ${lib.escapeShellArg cfg.proxy.urlTest.url}"}; then
          (( healthy )) || echo "proxy-suite: ${tag} is answering" >&2
          healthy=1 failures=0 uplink_down=0
          continue
        fi
        ${lib.optionalString (directPort != null) ''
          if ! ${probe directPort "https://1.1.1.1/cdn-cgi/trace"}; then
            (( uplink_down )) || echo "proxy-suite: the uplink is down; waiting for it before judging ${tag}" >&2
            uplink_down=1 failures=0 since=$SECONDS
            continue
          fi
        ''}
        uplink_down=0
        if (( healthy ? ++failures >= 3 : SECONDS - since >= 15 )); then
          echo "proxy-suite: ${tag} is not answering; restarting the tunnel on a new source port" >&2
          kill "$tunnel"
          wait "$tunnel"
          exit 1
        fi
      done
    '';

  markArg = flag: lib.optionalString (mark != null) " ${flag} ${toString mark}";

  # The profile is a secret, so it is converted at start, by root on a privileged host,
  # rather than baked into the store; the engine itself runs as ${serviceUser}.
  singBoxEngine =
    {
      tag,
      tunnelPort,
      directPort,
      endpoint,
    }:
    {
      convert = ''
        endpoint=$(${pkgs.python3}/bin/python3 ${scriptsDir}/warp_outbound.py --tag ${tag}${markArg "--routing-mark"}${
          lib.optionalString (endpoint != null) " --endpoint ${lib.escapeShellArg endpoint}"
        } < "$profile")
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
          outbounds: [{type: "direct", tag: "direct"${
            lib.optionalString (mark != null) ", routing_mark: ${toString mark}"
          }}],
          endpoints: [$ep + {domain_resolver: "local"}]
        }' > "$RUNTIME_DIRECTORY/config.json")
      '';
      config = "config.json";
      command = ''${cfg.proxy.singBox.package}/bin/sing-box run -c "$RUNTIME_DIRECTORY/config.json"'';
      inherit directPort;
    };

  wireproxyEngine =
    { tunnelPort, ... }:
    {
      convert = ''
        ${pkgs.python3}/bin/python3 ${scriptsDir}/amneziawg_config.py --config "$profile" \
          --output "$RUNTIME_DIRECTORY/wireproxy.conf" \
          --wireproxy 127.0.0.1:${toString tunnelPort}${markArg "--outbound-fwmark"}
      '';
      config = "wireproxy.conf";
      command = ''${cfg.amneziaWg.wireproxyPackage}/bin/wireproxy -c "$RUNTIME_DIRECTORY/wireproxy.conf"'';
      directPort = null;
    };

  # `profile` is a shell snippet, run as root on a privileged host, that sets $profile to
  # the WireGuard .conf. `engine` is "singBox" or "userspace"; only sing-box uses directPort,
  # and `endpoint`, a host:port in place of the profile's Endpoint.
  mkTunnel =
    {
      description,
      unit,
      tag,
      profile,
      tunnelPort,
      directPort ? null,
      endpoint ? null,
      engine ? "singBox",
    }:
    let
      chosen = (if engine == "userspace" then wireproxyEngine else singBoxEngine) {
        inherit
          tag
          tunnelPort
          directPort
          endpoint
          ;
      };
      tunnelScript = pkgs.writeShellScript "proxy-suite-wg-tunnel" ''
        set -euo pipefail
        ${profile}

        ${chosen.convert}
        ${ifPrivileged ''
          ${pkgs.coreutils}/bin/chgrp ${serviceUser} "$RUNTIME_DIRECTORY" "$RUNTIME_DIRECTORY/${chosen.config}"
          ${pkgs.coreutils}/bin/chmod g+r "$RUNTIME_DIRECTORY/${chosen.config}"
        ''}

        exec ${runAsServiceUser pkgs [ "net_admin" ]} ${
          mkWatchdog {
            inherit tag tunnelPort;
            inherit (chosen) command directPort;
          }
        }
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
