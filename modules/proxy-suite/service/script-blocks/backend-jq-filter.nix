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
  # derived.xhttpXmuxJq.
  xhttpXmuxJq ? "",
  # proxy.routing.blockQuic.
  blockQuic ? false,
}:

let
  fillTemplate = import ../../lib/fill-template.nix;
  # A guard for mixed-in's names goes just before the first direct rule that applies to
  # mixed-in, or last for a direct final. A runtime routing rule (routing-convert.jq: its first
  # rule set is user:<name>) does not count: one sending a name direct at the top would take the
  # guard, and its lookup, above every proxy rule. Each such rule above the guard gets the guard
  # to itself instead, only for what it matches.
  insertGuardDefs = ''
    | def runtime_rule: ((.rule_set? // [])[0] // "") | type == "string" and startswith("user:");
      def direct_for_mixed: (.outbound? // "") == "direct"
        and ((.inbound? // ["mixed-in"]) | index(["mixed-in"])) != null;
      # An "and" takes the rule set as one more condition; anything else, "or" included, is
      # wrapped whole.
      def scoped($sets):
        if .type? == "logical" and .mode? == "and" then .rules += [{rule_set: $sets}]
        else {type: "logical", mode: "and",
              rules: [del(.action, .strategy, .server), {rule_set: $sets}]}
             + ({action, strategy, server} | with_entries(select(.value != null)))
        end;
      def first_direct: .route.rules | map(direct_for_mixed and (runtime_rule | not)) | index(true);
      def insert_guard($guard):
        (first_direct // (.route.rules | length)) as $limit
        | .route.rules = [.route.rules | to_entries[] | .key as $i | .value
            | if $i < $limit and direct_for_mixed and runtime_rule
              then (. as $rule | $guard[] | scoped($rule.rule_set)), .
              else . end]
        | first_direct as $first_direct
        | if $first_direct != null then
            .route.rules = .route.rules[:$first_direct] + $guard + .route.rules[$first_direct:]
          elif (.route.final // "direct") == "direct" then
            .route.rules += $guard
          else . end;
      .
  '';
  # proxy.routing.blockQuic: QUIC (UDP to 443) refused on its way to a proxy, so browsers take
  # TCP at once. Every rule that sends traffic through an outbound carrying UDP badly gets a twin
  # just before it, matching the same and UDP to 443, that rejects; and the final one, when it
  # is such an outbound. Not a rule that names its own network or port (zapret2's "QUIC through
  # the proxy" for the sites whose QUIC it cannot fix), an inbound (the guards, the probes) or
  # an app pinned to an outbound. $outbound_sources (slurped): tag -> source, the start
  # script's: AmneziaWG and WARP hops are tunnels that carry UDP.
  quicNativeSources = "(($ARGS.named.outbound_sources // [{}])[0]) as $src";
  singBoxBlockQuic = ''
    | ${quicNativeSources}
    | [.outbounds[]
        | select((.type? // "") as $t
            | $t == "hysteria" or $t == "hysteria2" or $t == "tuic" or $t == "wireguard"
              or ($t == "direct" and (.bind_interface? | type) == "string")
              or ((($src[.tag] // "") | tostring) as $s | $s == "awg" or $s == "warp"))
        | .tag] as $base
    # A group carries UDP itself only when every member it may pick does.
    | [.outbounds[] | select(.type? == "selector" or .type? == "urltest")] as $groups
    | (reduce range(0; 4) as $_ ($base;
        . as $n | (. + [$groups[] | select((.outbounds // []) != [] and all(.outbounds[]; . as $m | $n | index([$m]) != null))
                        | .tag]) | unique)) as $native
    | def quic_bound($o): ($o | type) == "string" and $o != "direct" and $o != "block"
        and ($o | startswith("proxy-suite-pin-") | not) and ($native | index([$o]) | not);
      def own_scope: has("network") or has("port") or has("port_range") or has("protocol") or has("inbound")
        or ((.action? // "route") != "route");
      .route.rules = [.route.rules[]
        | if quic_bound(.outbound?) and (own_scope | not) then
            {type: "logical", mode: "and", rules: [del(.outbound, .action), {network: ["udp"], port: [443]}],
             action: "reject"}, .
          else . end]
    | if quic_bound(.route.final? // "direct") then
        .route.rules += [{network: ["udp"], port: [443], action: "reject"}]
      else . end
  '';
  xrayBlockQuic = ''
    | ${quicNativeSources}
    | [.outbounds[]
        | select((.protocol? // "") as $p
            | $p == "hysteria" or $p == "wireguard"
              or ((.streamSettings.network? // "") | . == "kcp" or . == "mkcp")
              or (.streamSettings.network? == "xhttp" and .streamSettings.security? == "tls"
                  and .streamSettings.tlsSettings.alpn? == ["h3"])
              or ($p == "freedom" and (.streamSettings.sockopt.interface? | type) == "string")
              or ((($src[.tag | ltrimstr("proxy-suite-ob-")] // "") | tostring) as $s | $s == "awg" or $s == "warp"))
        | .tag] as $native
    # A balancer may pick any member: as one that carries UDP badly.
    | def quic_bound: ((.balancerTag? | type) == "string")
        or ((.outboundTag? | type) == "string" and .outboundTag != "direct" and .outboundTag != "block"
            and (.outboundTag as $o | $native | index([$o]) | not));
      def own_scope: has("network") or has("port") or has("protocol") or has("inboundTag")
        or has("source") or has("sourcePort");
      .routing.rules = [.routing.rules[]
        | if .type? == "field" and quic_bound and (own_scope | not) then
            (del(.outboundTag, .balancerTag) + {network: "udp", port: "443", outboundTag: "block"}
             | if (.ruleTag | type) == "string" then .ruleTag += ":quic" else . end), .
          elif .ruleTag? == "final-default" and quic_bound then
            {type: "field", ruleTag: "final-quic", network: "udp", port: "443", outboundTag: "block"}, .
          else . end]
  '';
  # XRay's port list: "80,1000-2000".
  closedPorts = map (
    r: if r.from == r.to then toString r.from else "${toString r.from}-${toString r.to}"
  ) proxyInboundsHostClosedPorts;
in
if pureXrayEnabled then
  (fillTemplate ./backend-filter-xray.template.jq {
    inherit selectionMode;
    hostClosedPorts = lib.concatStringsSep "," closedPorts;
    setXhttpXmux = xhttpXmuxJq;
    fragmentHopsDef = builtins.readFile ./xray-fragment-hops.jq;
  })
  + lib.optionalString blockQuic xrayBlockQuic
else
  (fillTemplate ./backend-filter-sing-box.template.jq {
    userDnsRuleCount = toString (builtins.length userDnsRules);
  })
  + lib.optionalString (listenerExposed || proxyInboundsGuardPrivate) insertGuardDefs
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
    | insert_guard($guard)
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
  + lib.optionalString blockQuic singBoxBlockQuic
