# Polkit rules granting proxy-suite group members passwordless control over services.
{
  lib,
  cfg,
  userControlCfg,
}:

let
  userControlEnabled = userControlCfg.allow != [ ];

  userControlPolkitRules =
    lib.optionalString (builtins.elem "perApp" userControlCfg.allow) ''
      if (unit.indexOf("proxy-suite-per-app-") === 0) {
        return polkit.Result.YES;
      }
    ''
    + lib.optionalString (builtins.elem "global" userControlCfg.allow) ''
      if ((unit.indexOf("proxy-suite-") === 0 &&
           unit.indexOf("proxy-suite-per-app-") !== 0) ||
          unit === "zapret-discord-youtube.service") {
        return polkit.Result.YES;
      }
    '';
in
{
  inherit userControlEnabled userControlPolkitRules;
}
