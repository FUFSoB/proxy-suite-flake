{
  lib,
  pureXrayEnabled,
  selectionMode,
  proxyInboundsGuardPrivate,
  proxyInboundsGuardStrategy ? null,
  userDnsRules ? [ ],
}:

let
  fillTemplate = import ../../lib/fill-template.nix;
in
if pureXrayEnabled then
  (fillTemplate ./backend-filter-xray.template.jq { inherit selectionMode; })
else
  (fillTemplate ./backend-filter-sing-box.template.jq {
    userDnsRuleCount = toString (builtins.length userDnsRules);
  })
  + lib.optionalString proxyInboundsGuardPrivate (
    fillTemplate ./backend-filter-private-guard.template.jq {
      resolveStrategy = lib.optionalString (
        proxyInboundsGuardStrategy != null
      ) ", strategy: \"${proxyInboundsGuardStrategy}\"";
    }
  )
