# Polkit rule body granting userControl group members passwordless control over the
# units of their scopes.
{ userControlCfg }:

let
  # Units a narrower scope starts; every other proxy-suite unit is "services".
  scopeByUnitPrefix = {
    "proxy-suite-per-app-" = "perApp";
    "proxy-suite-outbound-pin@" = "routing";
    "proxy-suite-outbound-unpin." = "routing";
    "proxy-suite-route-mode@" = "routing";
    "proxy-suite-outbound-reload." = "outbounds";
    "proxy-suite-subscription-update." = "outbounds";
    "proxy-suite-autoproxy-learn." = "autoProxy";
    "proxy-suite-zapret2-cutoff." = "zapret";
    "proxy-suite-inbound-stats." = "stats";
  };
in
{
  userControlPolkitRules = ''
    var scopeByUnitPrefix = ${builtins.toJSON scopeByUnitPrefix};
    var scope = unit.indexOf("proxy-suite-") === 0 ? "services" : null;
    for (var prefix in scopeByUnitPrefix) {
      if (unit.indexOf(prefix) === 0) {
        scope = scopeByUnitPrefix[prefix];
        break;
      }
    }
    // No scopes listed means all of them.
    var scopes = ${builtins.toJSON userControlCfg.scopes};
    if (scope !== null && (scopes.length === 0 || scopes.indexOf(scope) !== -1)) {
      return polkit.Result.YES;
    }
  '';
}
