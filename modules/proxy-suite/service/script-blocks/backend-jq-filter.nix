{
  lib,
  pureXrayEnabled,
  selectionMode,
  proxyInboundsGuardPrivate,
  proxyInboundsGuardStrategy ? null,
  userDnsRules ? [ ],
  # proxy.dns.remote as a sing-box server, for the AmneziaWG interfaces added at runtime; null
  # when there are none.
  awgRuntimeDnsServer ? null,
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
  # An outbound on such an interface resolves through it (awg-dns-<tag>), as a declared one
  # does; only its server cannot be in the build-time config.
  + lib.optionalString (awgRuntimeDnsServer != null) ''
    | ([.dns.servers[]?.tag]) as $have
    | .dns.servers += [
        .outbounds[]
        | select(.type == "direct" and (.bind_interface | type) == "string"
            and ((.domain_resolver? // "") | type) == "string"
            and ((.domain_resolver? // "") | startswith("awg-dns-")))
        | select(.domain_resolver as $t | $have | index($t) | not)
        | {tag: .domain_resolver, bind_interface} + ${builtins.toJSON awgRuntimeDnsServer}
          + (if .routing_mark then {routing_mark} else {} end)
      ]
  ''
  + lib.optionalString proxyInboundsGuardPrivate (
    fillTemplate ./backend-filter-private-guard.template.jq {
      resolveStrategy = lib.optionalString (
        proxyInboundsGuardStrategy != null
      ) ", strategy: \"${proxyInboundsGuardStrategy}\"";
    }
  )
