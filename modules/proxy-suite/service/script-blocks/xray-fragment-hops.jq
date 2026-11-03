# XRay fragments a TLS ClientHello in freedom alone: an outbound with `fragment`
# (proxy_parsing._xray_tweaks marks it "_fragment") dials through a freedom of its own,
# "proxy-suite-fragment-<tag>", which takes over its mark, interface, name resolution and
# detour: real -> fragment -> hop. Not "<tag>-...": the balancer of pure XRay picks by tag
# prefix, and would take the freedom, a direct exit, for one of its members. Over an array
# of outbounds. No single quote in here: the sidecar script holds this in one.
def proxy_suite_fragment_hops:
  [.[] | select(._fragment? != null)] as $fragmented
  | [.[] | if ._fragment? != null then
        (.streamSettings.sockopt // {}) as $so
        | .streamSettings.sockopt = (($so | del(.mark, .interface, .dialerProxy))
            + {dialerProxy: ("proxy-suite-fragment-" + .tag)})
        | del(._fragment)
      else . end]
    + [$fragmented[] | (.streamSettings.sockopt // {}) as $so
        | {protocol: "freedom", tag: ("proxy-suite-fragment-" + .tag),
           settings: {fragment: ._fragment},
           streamSettings: {sockopt: ($so | {mark, interface, dialerProxy, domainStrategy}
                                         | with_entries(select(.value != null)))}}];
