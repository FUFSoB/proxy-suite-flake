# Renders every per-exit autoProxy rule-set file from the learned state.
#
# Shared by the socks start script and the prober. The start script needs it
# because sing-box refuses to start when a local rule-set path is missing, so
# every file it will be told about must exist first; the prober needs it to
# publish what it learns, which sing-box then picks up without a restart.
{
  pkgs,
  serviceUser,
  ifPrivileged,
}:

let
  fillTemplate = import ./lib/fill-template.nix;
in
pkgs.writeShellScript "proxy-suite-autoproxy" (
  fillTemplate ./autoproxy-render.template.sh {
    path = pkgs.lib.makeBinPath [
      pkgs.coreutils
      pkgs.jq
    ];
    inherit serviceUser;
    groupArg = ifPrivileged "-g ${serviceUser} ";
  }
)
