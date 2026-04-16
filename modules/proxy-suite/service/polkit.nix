# Polkit rules granting proxy-suite group members passwordless control over services.
{ lib, cfg, userControlCfg }:

let
  userControlEnabled = userControlCfg.global.enable || userControlCfg.perApp.enable;

  userControlPolkitRules =
    lib.optionalString userControlCfg.perApp.enable ''
      if (unit.indexOf("proxy-suite-app-") === 0) {
        return polkit.Result.YES;
      }
    ''
    + lib.optionalString userControlCfg.global.enable ''
      if ((unit.indexOf("proxy-suite-") === 0 &&
           unit.indexOf("proxy-suite-app-") !== 0) ||
          unit === "zapret-discord-youtube.service") {
        return polkit.Result.YES;
      }
    '';
in
{ inherit userControlEnabled userControlPolkitRules; }
