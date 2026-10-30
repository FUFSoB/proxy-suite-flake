# The listeners of services.proxy-suite.inbounds sing-box serves (anytls, naive, tuic,
# shadowtls). It takes them on their ports and hands each user on to the listener's loopback
# VLESS inbound in XRay, which routes, counts and limits them like any other; so the
# inbounds' start script renders its config along with XRay's (proxy_inbound.py), and
# inbound_apply.py rewrites and reloads it when their users change.
{
  lib,
  pkgs,
  cfg,
  derived,
}:

let
  inherit (derived) constants;
  unitName = "proxy-suite-inbounds-sing-box";
  inboundsUnit = "proxy-suite-inbounds.service";
  configFile = "${constants.runtimeDir}/proxy-suite-inbounds/sing-box.json";
  singBox = "${cfg.inbounds.singBoxPackage}/bin/sing-box";
  run = constants.runAsServiceUser pkgs [ "net_bind_service" ];

  start = pkgs.writeShellScript unitName ''
    set -euo pipefail
    # Written as the inbounds start, into a runtime directory each of their restarts empties
    # (one restarts this too).
    for _ in $(${pkgs.coreutils}/bin/seq 60); do
      [ -s ${configFile} ] && break
      ${pkgs.coreutils}/bin/sleep 1
    done
    if [ ! -s ${configFile} ]; then
      echo "proxy-suite: ${inboundsUnit} has not written ${configFile}" >&2
      exit 1
    fi
    exec ${run} ${singBox} run -c ${configFile}
  '';
in
{
  services.proxy-suite.internal = {
    services.${unitName} = {
      description = "proxy-suite sing-box server inbounds (anytls, naive, tuic, shadowtls)";
      after = [ inboundsUnit ];
      wantedBy = [ "multi-user.target" ];
      # Stopped and restarted with the inbounds, whose restart renders its config anew.
      partOf = [ inboundsUnit ];
      serviceConfig = {
        ExecStart = start;
        # sing-box checks the new config, and keeps the old one when it does not hold up.
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
        Restart = "on-failure";
        RestartSec = 5;
      }
      // lib.optionalAttrs constants.privileged {
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
      };
    };

    services.proxy-suite-inbounds.wants = [ "${unitName}.service" ];
  };
}
