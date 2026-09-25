{
  nixpkgs,
  pkgsFor,
  proxySuiteModule,
}:

system:

let
  pkgs = pkgsFor system;
  lib = pkgs.lib;
  eval = import "${nixpkgs}/nixos/lib/eval-config.nix" {
    inherit system;
    modules = [
      proxySuiteModule
      { system.stateVersion = lib.trivial.release; }
    ];
  };

  # Visible options only (renamed aliases are hidden, and so are groups left
  # with nothing but aliases), packages shown by name.
  visibleConfig =
    opts: cfg:
    lib.filterAttrs (name: value: lib.isOption opts.${name} || value != { }) (
      lib.mapAttrs (
        name: opt:
        if !lib.isOption opt then
          visibleConfig opt cfg.${name}
        else if lib.isDerivation cfg.${name} then
          {
            __pretty = _: "pkgs.${lib.getName cfg.${name}}";
            val = null;
          }
        else
          cfg.${name}
      ) (lib.filterAttrs (name: opt: name != "_module" && (opt.visible or true) != false) opts)
    );

  optionDocs = pkgs.nixosOptionsDoc {
    options.services.proxy-suite = eval.options.services.proxy-suite;
    documentType = "none";
    variablelistId = "proxy-suite-options";
    optionIdPrefix = "proxy-suite-opt-";
    transformOptions = opt: opt // { declarations = [ ]; };
  };
in
import ./options-doc/render-options-markdown.nix {
  inherit pkgs optionDocs;
  # The index lists the groups in this order.
  groupSummaries = [
    {
      name = "proxy";
      summary = "The local proxy: outbounds, subscriptions, selection, routing, DNS, TUN and TProxy.";
    }
    {
      name = "killSwitch";
      summary = "Block traffic outside the global tunnel.";
    }
    {
      name = "perAppRouting";
      summary = "Route single apps through proxychains, a per-app TUN or TProxy, or zapret.";
    }
    {
      name = "zapret";
      summary = "DPI bypass without a proxy: zapret-discord-youtube or zapret2.";
    }
    {
      name = "amneziaWg";
      summary = "AmneziaWG client profiles, as a global VPN or as outbounds.";
    }
    {
      name = "warp";
      summary = "Cloudflare WARP, as an outbound or an AmneziaWG profile.";
    }
    {
      name = "tor";
      summary = "Tor as an outbound, with bridges, and an onion service for the inbounds.";
    }
    {
      name = "sshProxy";
      summary = "An SSH SOCKS5 tunnel, optionally as an outbound.";
    }
    {
      name = "tgWsProxy";
      summary = "A Telegram MTProto proxy over WebSocket.";
    }
    {
      name = "whitelistBypass";
      summary = "Tunnels through video-call servers, past mobile internet whitelists.";
    }
    {
      name = "inbounds";
      summary = "Server side: listeners for remote clients, share links, subscriptions and stats.";
    }
    {
      name = "geodata";
      summary = "Geosite and geoip databases used by routing.";
    }
    {
      name = "userControl";
      summary = "Let a group use `proxy-ctl` without root.";
    }
    {
      name = "gui";
      summary = "The desktop app with a tray icon.";
    }
    {
      name = "tui";
      summary = "The `proxy-tui` terminal UI.";
    }
  ];
  defaultConfigText = lib.generators.toPretty { allowPrettyValues = true; } (
    visibleConfig eval.options.services.proxy-suite eval.config.services.proxy-suite
  );
}
