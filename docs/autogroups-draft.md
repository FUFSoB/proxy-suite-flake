# Auto-groups: HOME and WHITELIST from subscriptions (draft)

Status: wired. Files: `modules/proxy-suite/options/proxy-autogroups.nix`,
`modules/proxy-suite/autogroups.nix`, `scripts/test-autogroups-classify.py`.

The goal: after a subscription is imported or refreshed, reserves in the home pool and
whitelist-only servers are grouped automatically, with no per-server regex from the user.

## How it works

A subscription entry's outbound tag is `<subscription tag>-<slugified remark>` (see
`scripts/proxy_parsing.py`). The slug keeps Unicode word characters and `-`, and turns every
other separator into `-`, so a subscription tag separates tokens with `-` or `_` only.

Two phases:

1. **Build time** (`mkAutoGroups` in `autogroups.nix`) turns each whitelist token into globs
   for every separator position inside `<sub>-<slug>`, in every ASCII case variant:
   `sub-WL`, `sub-WL-*`, `sub-*-WL`, `sub-*-WL-*` (and the `_` spellings). Nix cannot
   emit a character class, because the engine's glob language has only `*` and `?`, so the
   four contexts are emitted separately. The home group simply names every declared
   subscription (plus `extraHomeGlobs`).
2. **Start time** (`outbound-groups.jq`, unchanged) resolves those globs against the tags the
   fetched subscriptions actually hold. A server added to an existing subscription is therefore
   picked up without touching this config.

Token matching is by whole token, not substring: `LTE` matches `sub-LTE-1` and
`sub-foo_lte_bar`, but not `complete` or `welt`. ASCII case and the emoji presentation
selector (U+FE0F) are ignored, so `wl`, `Wlte` and `🏳` match `WL`, `WLTE` and `🏳️`.

## Wiring

`options/default.nix` imports `options/proxy-autogroups.nix`, and
`options/proxy-outbounds.nix` merges the generator's groups into `proxy.groups` (the option's
`apply`). Every reader of `proxy.groups` — routing rules, assertions, the start script — sees
them, without a local module. A manually declared group of the same name wins: `mkAutoGroups`
skips a generated name the merged groups already hold, so its membership is never rewritten.
The generated groups' warnings go to the module's `warnings`.

`generated.groups` is empty when `autoGroups.enable = false`. `generated.warnings` names an
empty group or a home/whitelist name collision; `generated.skipped` lists names a manual group
shadowed.

## HOME: the everyday pool

Main subscription plus reserves, all through the home group; the usual local SOCKS listener,
optionally with TUN started at boot:

```nix
services.proxy-suite = {
  enable = true;
  proxy = {
    enable = true;
    autostart = "tun"; # optional: route the whole machine
    tun.enable = true;

    autoGroups.enable = true;

    subscriptions = [
      { tag = "main"; urlFile = "/run/secrets/main-sub"; }
      { tag = "reserve"; urlFile = "/run/secrets/reserve-sub"; }
    ];

    selection = "failover";
    priority = { home = 10; };
  };
};
```

Everything from `main-*` and `reserve-*` is in `home`; the top level picks `home` first and
fails over inside it. A manual group (or an outbound not in a group) still follows in priority
order.

Because globs have no negation, a whitelist entry inside `main` or `reserve` is **also** in
`home`. That is harmless for failover (WL servers are ordinary exits); for a strict split keep
whitelist servers in their own subscription, as below.

## WHITELIST: TUN only, whitelist servers only

```nix
services.proxy-suite = {
  enable = true;
  proxy = {
    enable = true;
    autostart = "tun"; # no SOCKS listener needed
    tun.enable = true;

    autoGroups = {
      enable = true;
      whitelistTokens = [ "WL" "WLTE" "LTE" "🏳️" ];
    };

    subscriptions = [
      { tag = "home-sub"; urlFile = "/run/secrets/home-sub"; }
      { tag = "mobile-wl"; urlFile = "/run/secrets/mobile-wl-sub"; }
    ];

    # The top level picks whitelist first: only WL entries carry the traffic.
    selection = "first";
    priority = { whitelist = 0; home = 100; };
  };
};
```

Only `mobile-wl-*WL*` entries land in `whitelist` (the generated globs are
`mobile-wl-WL`, `mobile-wl-WL-*`, `mobile-wl-*-WL`, `mobile-wl-*-WL-*` and their case
variants). A group with no member blocks rather than falling through, so if the whitelist
subscription yields nothing, traffic stops instead of leaking direct. To send only some traffic
through WL while the rest uses `home`, keep `selection = "failover"` and add a rule:

```nix
proxy.routing.rules = [
  { outbound = "whitelist"; geosites = [ "youtube" "telegram" ]; }
];
```

## Surviving subscription updates

- The subscription timer refreshes entry lists; `outbound-groups.jq` resolves group membership
  at service start. Restart the proxy service (or the unit that renders the config) after a
  refresh to re-evaluate membership.
- New servers in an existing subscription get tags `<same sub tag>-…`, so the same patterns
  match them after that restart. No edit here.
- Removing a server drops it from the groups; a group that becomes empty blocks (warns on start).
- Manual groups are never rewritten. If a manual group uses a generated name, the generated one
  is skipped, not merged. If a tag is a member of both a manual and a generated group, both keep
  it; routing decides which group a rule names.

## Limitations, and the second stage

- **Separators.** Generated globs cover `-` and `_`, the only separators a subscription tag can
  contain. A custom outbound tag using `.`, space, `/` or `|` needs `extraWhitelistGlobs`
  (globs are case-sensitive too, so spell the case exactly).
- **Unicode.** Nix has no NFKC and `lib.toLower` folds ASCII only. ASCII tokens are fully
  case-insensitive through the generated variants; a Cyrillic or other non-ASCII token matches
  only its exact spelling. Add `extraWhitelistGlobs`, or wait for stage two.
- **No negation.** `home` cannot exclude whitelist entries at build time.
- **Glob syntax.** Only `*` and `?`; `[`, `{` and escapes are literals. A subscription tag
  containing `*` or `?` would widen the generated patterns.

Runtime stage two (a follow-up, not in this lane): let `outbound-groups.jq` classify fetched
tags directly, with `ascii_downcase` (and NFKC/Unicode folding if the jq build has it), a
`match` pattern option that takes a regex with the `i` flag, and an `exclude` / negative
`match` list. That would make separators and Unicode exact, and let `home` exclude whitelist
tags. The generated globs above stay as the fallback for unchanged engines.

## Test

```sh
python3 scripts/test-autogroups-classify.py
```

The script tests `classifyTag` against the Nix implementation for ten-plus tags (WL, wlte, lte,
emoji with and without VS16, `complete`, `welt`, token boundaries), and checks that the
generated whitelist globs match whitelist tags and no home tags.
