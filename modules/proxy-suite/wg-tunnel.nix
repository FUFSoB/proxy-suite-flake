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
  hintDir = "${derived.constants.runtimeDir}/proxy-suite-outbound-groups/health";
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
  # The tunnel's own listener takes the hop login ($HOP_PASSWORD), from curl's stdin.
  probe = port: url: ''
    printf 'proxy-user = "${derived.constants.hopUser}:%s"\n' "$HOP_PASSWORD" | ${pkgs.curl}/bin/curl -K - -s --noproxy "" \
      -x socks5h://127.0.0.1:${toString port} -m "$timeout" -o /dev/null ${url}'';
  # direct-in takes the login the start drew ($DIRECT_AUTH), from curl's stdin: argv is public.
  probeDirect = port: url: ''
    printf 'proxy-user = "probe:%s"\n' "$DIRECT_AUTH" | ${pkgs.curl}/bin/curl -K - -s --noproxy "" \
      -x socks5h://127.0.0.1:${toString port} -m "$timeout" -o /dev/null ${url}'';

  # Some lines drop a share of fresh handshakes for good, and both engines retry on the
  # same source port forever. A new process binds a new port, so the watchdog exits when
  # the peer stops answering and the service manager starts the tunnel again. A healthy
  # handshake takes a fraction of a second, so a start gets 15 seconds; a running tunnel
  # gets three misses. sing-box's "direct-in" listener reaches Cloudflare through the uplink
  # with the backend's mark (not urlTest.url, which is picked to be blocked here): when that
  # fails too, the tunnel could not work from a new port either. wireproxy has no such
  # listener (directPort = null), so it is restarted either way. The tag is $TUNNEL_TAG.
  mkWatchdog =
    {
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
          (( healthy )) || echo "proxy-suite: $TUNNEL_TAG is answering" >&2
          healthy=1 failures=0 uplink_down=0
          continue
        fi
        ${lib.optionalString (directPort != null) ''
          if ! ${probeDirect directPort "https://1.1.1.1/cdn-cgi/trace"}; then
            (( uplink_down )) || echo "proxy-suite: the uplink is down; waiting for it before judging $TUNNEL_TAG" >&2
            uplink_down=1 failures=0 since=$SECONDS
            continue
          fi
        ''}
        uplink_down=0
        # proxy-suite-outbound-groups hears of the first miss: a failover group moves off it now.
        if (( healthy && failures == 0 )) && [[ -d ${hintDir} ]]; then
          ${pkgs.coreutils}/bin/touch "${hintDir}/$TUNNEL_TAG" 2>/dev/null || true
        fi
        if (( healthy ? ++failures >= 3 : SECONDS - since >= 15 )); then
          echo "proxy-suite: $TUNNEL_TAG is not answering; restarting the tunnel on a new source port" >&2
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
      tunnelPort,
      directPort,
      endpoint,
      domainStrategy,
    }:
    {
      convert = ''
        endpoint=$(${pkgs.python3}/bin/python3 ${scriptsDir}/warp_outbound.py --tag "$TUNNEL_TAG"${markArg "--routing-mark"}${
          lib.optionalString (endpoint != null) " --endpoint ${lib.escapeShellArg endpoint}"
        } < "$profile")
        # direct-in gets past TProxy and the kill switch: a login drawn per start keeps other local
        # users off it (read from the environment, as argv is public).
        DIRECT_AUTH=$(${pkgs.coreutils}/bin/od -An -tx1 -N16 /dev/urandom | ${pkgs.coreutils}/bin/tr -d ' \n')
        export DIRECT_AUTH
        # From a pipe: the endpoint holds the private key, and argv is public.
        (umask 027 && ${pkgs.jq}/bin/jq -n --arg tag "$TUNNEL_TAG" --slurpfile ep <(printf '%s' "$endpoint") '$ep[0] as $ep | {
          log: {level: "warn"},
          dns: {servers: [
            ${builtins.toJSON (dnsServer "local" cfg.proxy.dns.local)},
            (${builtins.toJSON (dnsServer "remote" cfg.proxy.dns.remote)} + {detour: $tag, domain_resolver: "local"})
          ]},
          route: {
            default_domain_resolver: ${
              builtins.toJSON (
                if domainStrategy == null then
                  "remote"
                else
                  {
                    server = "remote";
                    strategy = domainStrategy;
                  }
              )
            },
            rules: [{inbound: ["direct-in"], outbound: "direct"}],
            final: $tag
          },
          inbounds: [
            {type: "socks", tag: "socks-in", listen: "127.0.0.1", listen_port: ${toString tunnelPort},
             users: [{username: "${derived.constants.hopUser}", password: $ENV.HOP_PASSWORD}]},
            {type: "socks", tag: "direct-in", listen: "127.0.0.1", listen_port: ${toString directPort},
             users: [{username: "probe", password: $ENV.DIRECT_AUTH}]}
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
  # `endpoint`, a host:port in place of the profile's Endpoint, and `domainStrategy`, the
  # address family it dials destinations over first.
  #
  # The tag comes from $TUNNEL_TAG, never spliced in (an attribute name can hold anything). A
  # template unit passes `tag = null` and `tunnelPort = "$TUNNEL_PORT"`, both from `profile`.
  mkTunnel =
    {
      description,
      unit,
      tag ? null,
      profile,
      tunnelPort,
      directPort ? null,
      endpoint ? null,
      domainStrategy ? null,
      engine ? "singBox",
      runtimeDirectory ? unit,
      wantedBy ? [ "multi-user.target" ],
      restart ? "always",
      # " %i" for a template, whose `profile` reads the instance name from $1.
      execArgs ? "",
    }:
    let
      chosen = (if engine == "userspace" then wireproxyEngine else singBoxEngine) {
        inherit
          tunnelPort
          directPort
          endpoint
          domainStrategy
          ;
      };
      tunnelScript = pkgs.writeShellScript "proxy-suite-wg-tunnel" ''
        set -euo pipefail
        ${lib.optionalString (tag != null) "TUNNEL_TAG=${lib.escapeShellArg tag}"}
        ${profile}
        export TUNNEL_TAG
        # The hop login (constants.ensureHopLogin): the backend dials the listener with it,
        # and the watchdog probes it so. Through the environment alone: argv is public.
        ${derived.constants.ensureHopLogin pkgs}
        HOP_PASSWORD=$(< ${lib.escapeShellArg derived.constants.hopLoginFile})
        export HOP_PASSWORD

        ${chosen.convert}
        ${ifPrivileged ''
          ${pkgs.coreutils}/bin/chgrp ${serviceUser} "$RUNTIME_DIRECTORY" "$RUNTIME_DIRECTORY/${chosen.config}"
          ${pkgs.coreutils}/bin/chmod g+r "$RUNTIME_DIRECTORY/${chosen.config}"
        ''}

        exec ${runAsServiceUser pkgs [ "net_admin" ]} ${
          mkWatchdog {
            inherit tunnelPort;
            inherit (chosen) command directPort;
          }
        }
      '';
    in
    {
      inherit description wantedBy;
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      # Probe-triggered restarts must not trip the start limit.
      startLimitIntervalSec = 0;
      serviceConfig = {
        Type = "simple";
        ExecStart = if execArgs == "" then tunnelScript else "${tunnelScript}${execArgs}";
        Restart = restart;
        RestartSec = 2;
        # A profile that fails for good backs off to a minute rather than going through its
        # conversion as root every 2 s.
        RestartSteps = 5;
        RestartMaxDelaySec = 60;
        RuntimeDirectory = runtimeDirectory;
        RuntimeDirectoryMode = "0750";
        UMask = "0077";
      }
      # Root only converts the profile; the engine gets net_admin alone. No ProtectHome: a
      # configFile may sit under /home or /root.
      // lib.optionalAttrs cfg.host.privileged {
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        # The watchdog's hints go to proxy-suite-outbound-groups' directory, which comes and
        # goes with that unit: a bind of the directory itself would go stale.
        ReadWritePaths = [ derived.constants.runtimeDir ];
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
      };
    };
in
{
  inherit mkTunnel;
}
