# Cloudflare WARP: the sing-box tunnel or AmneziaWG profile behind the "warp" outbound, the global
# AmneziaWG profile and, without a configFile, wgcf registration.
{
  lib,
  pkgs,
  cfg,
  derived,
}:

let
  w = derived.warpCfg;
  inherit (derived.constants) unprivilegedServiceConfig;
  inherit (derived.localProxy) auth host hostPart;
  listener = cfg.proxy.listener;
  passwordSource =
    if auth.passwordFile != null then
      auth.passwordFile
    else if auth.password != null then
      pkgs.writeText "proxy-suite-warp" auth.password
    else
      null;
  withProxyAuth = derived.localProxy.authEnabled;
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

  inherit
    (import ./wg-tunnel.nix {
      inherit
        lib
        pkgs
        cfg
        derived
        ;
    })
    mkTunnel
    ;
  viaAmneziaWg = builtins.elem w.asOutbound [
    "userspace"
    "interface"
  ];
  deviceTags = map (d: d.tag) w.devices;
in
{
  # One AmneziaWG profile per device, named after it.
  services.proxy-suite.amneziaWg.profiles = lib.mkIf (w.asAmneziaWg || viaAmneziaWg) (
    lib.listToAttrs (
      map (
        d:
        lib.nameValuePair d.tag {
          configFile = d.profilePath;
          inherit (d) endpoint;
          inherit (w) domainStrategy;
          asOutbound = lib.mkIf viaAmneziaWg w.asOutbound;
          autostart = lib.mkIf w.autostart true;
        }
      ) w.devices
    )
  );

  # Several devices: "warp" picks among them, so whatever names "warp" fails over.
  services.proxy-suite.proxy.groups = lib.mkIf (w.grouped && w.asOutbound != null) {
    warp = {
      outbounds = lib.mkDefault deviceTags;
      strategy = lib.mkDefault w.group.strategy;
      failback = lib.mkDefault w.group.failback;
    };
  };

  services.proxy-suite.internal.services = lib.mkMerge (
    map (
      d:
      lib.mkMerge [
        (lib.mkIf (w.asOutbound == "singBox") {
          ${d.tunnelUnit} = mkTunnel {
            description = "proxy-suite - Cloudflare WARP tunnel behind the ${d.tag} outbound";
            unit = d.tunnelUnit;
            inherit (d) tag;
            profile = ''
              profile=${lib.escapeShellArg d.profilePath}
              if [ ! -s "$profile" ]; then
                echo "proxy-suite: waiting for the WARP profile at $profile" >&2
                until [ -s "$profile" ]; do sleep 5; done
              fi
            '';
            inherit (d)
              tunnelPort
              directPort
              endpoint
              ;
            inherit (w) domainStrategy;
          };
        })

        (lib.mkIf d.autoRegister {
          ${d.registerUnit} = {
            description = "proxy-suite - register the Cloudflare WARP device ${d.tag} with wgcf";
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
              StateDirectory = "proxy-suite/${d.stateSubdir}";
              StateDirectoryMode = "0700";
              WorkingDirectory = "${derived.constants.stateDir}/${d.stateSubdir}";
              UMask = "0077";
              LoadCredential = lib.optional (
                cfg.proxy.enable && withProxyAuth
              ) "proxy-password:${passwordSource}";
              ExecStart = registerScript;
            };
          };

          # Only pulls registration in: a simple unit gives the profile no ordering guarantee.
          "proxy-suite-awg-${d.tag}" = lib.mkIf (w.asAmneziaWg || viaAmneziaWg) {
            wants = [ "${d.registerUnit}.service" ];
          };
        })
      ]
    ) w.devices
  );
}
