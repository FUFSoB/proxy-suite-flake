{
  lib,
  pureXrayEnabled,
  selectionMode,
  proxyInboundsGuardPrivate,
  proxyInboundsGuardStrategy ? null,
  # inbounds.routing.blockPrivate: the guard rejects the private ranges, else loopback alone.
  proxyInboundsBlockPrivate ? true,
  proxyInboundsLoopback ? [ ],
  # The ports of this host's own addresses its inbounds' clients may not reach, as ranges.
  proxyInboundsHostClosedPorts ? [ ],
  userDnsRules ? [ ],
  # proxy.dns.remote as a sing-box server, for the AmneziaWG interfaces added at runtime; null
  # when there are none.
  awgRuntimeDnsServer ? null,
  # proxy.listener on an address other machines reach (0.0.0.0, a LAN address).
  listenerExposed ? false,
}:

let
  fillTemplate = import ../../lib/fill-template.nix;
  # XRay's port list: "80,1000-2000".
  closedPorts = map (
    r: if r.from == r.to then toString r.from else "${toString r.from}-${toString r.to}"
  ) proxyInboundsHostClosedPorts;
in
if pureXrayEnabled then
  (fillTemplate ./backend-filter-xray.template.jq {
    inherit selectionMode;
    hostClosedPorts = lib.concatStringsSep "," closedPorts;
  })
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
  # A listener others reach, without the inbounds' guard: a LAN client could CONNECT to
  # 127.0.0.1 (or a name resolving there), which the private-ranges rule sends direct, dialed
  # from here: this host's loopback-only services. This host's own clients may still, and
  # their names stay unresolved for the proxy.
  + lib.optionalString (listenerExposed && !proxyInboundsGuardPrivate) ''
    | {source_ip_cidr: ["127.0.0.0/8", "::1/128"], invert: true} as $remote
    | [{type: "logical", mode: "and", rules: [{inbound: ["mixed-in"]}, $remote],
        action: "resolve", server: "local"},
       {type: "logical", mode: "and",
        rules: [{inbound: ["mixed-in"], ip_cidr: ${builtins.toJSON proxyInboundsLoopback}}, $remote],
        action: "reject"}] as $guard
    | (.route.rules
       | map((.outbound? // "") == "direct" and ((.inbound? // ["mixed-in"]) | index(["mixed-in"])) != null)
       | index(true)) as $first_direct
    | if $first_direct != null then
        .route.rules = .route.rules[:$first_direct] + $guard + .route.rules[$first_direct:]
      elif (.route.final // "direct") == "direct" then
        .route.rules += $guard
      else . end
  ''
  # No sniffing on mixed-in, where the inbounds' clients arrive: an SNI the rules send direct
  # would take their connection direct to any address. Their names still route as names.
  + lib.optionalString proxyInboundsGuardPrivate ''
    | (.route.rules[]? | select(.action? == "sniff" and (has("inbound") | not)))
        |= . + {inbound: ["mixed-in"], invert: true}
  ''
  + lib.optionalString proxyInboundsGuardPrivate (
    fillTemplate ./backend-filter-private-guard.template.jq {
      rejectMatch =
        if proxyInboundsBlockPrivate then
          ", ip_is_private: true"
        else
          ", ip_cidr: ${builtins.toJSON proxyInboundsLoopback}";
      # sing-box's port_range is always from:to.
      hostPortMatch = ", port_range: ${
        builtins.toJSON (map (r: "${toString r.from}:${toString r.to}") proxyInboundsHostClosedPorts)
      }";
      # Then there is nothing to reject: no rule, as an empty port_range would match any port.
      hostPortsAllOpen = lib.boolToString (proxyInboundsHostClosedPorts == [ ]);
      resolveStrategy = lib.optionalString (
        proxyInboundsGuardStrategy != null
      ) ", strategy: \"${proxyInboundsGuardStrategy}\"";
    }
  )
