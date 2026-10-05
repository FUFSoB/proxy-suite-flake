{ lib, ... }:

let
  inherit (lib) mkOption types;
  t = import ./types.nix { inherit lib; };
in
{
  options.services.proxy-suite.proxy = {
    outbounds = mkOption {
      type = types.listOf t.outboundType;
      default = [ ];
      description = ''
        Proxy servers to connect through. Each sets exactly one of `url`, `urlFile`, `singBoxJson`
        or `xrayJson`. The proxy needs at least one outbound or subscription to start;
        `proxy-ctl proxy outbounds add` can add one at runtime.
      '';
      example = [
        {
          tag = "de-vps";
          urlFile = "/run/secrets/proxy-de-url";
        }
        {
          tag = "nl-vps";
          url = "hy2://password@example.com:443?sni=example.com";
        }
      ];
    };

    subscriptions = mkOption {
      type = types.listOf t.subscriptionType;
      default = [ ];
      description = ''
        Subscription URLs that serve a list of proxy links (plain or base64). Fetched on first
        start, cached, and refreshed on a timer. `proxy-ctl proxy subs add` adds more at runtime.
      '';
      example = [
        {
          tag = "private";
          urlFile = "/run/secrets/private-sub-url";
        }
      ];
    };

    runtimeSubscriptions = {
      allowHttp = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Let subscriptions added at runtime (`proxy-ctl proxy subs add`) be fetched over plain
          http. Anyone on the way can then add entries of their own.
        '';
      };
      allowInsecure = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Keep entries of subscriptions added at runtime that turn certificate checks off, as
          `subscriptions.*.allowInsecure` does for a declared one. Anyone on the way can then
          stand in for those servers.
        '';
      };
      allowPrivateServers = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Keep entries of subscriptions added at runtime whose server is a private address, as
          `subscriptions.*.allowPrivateServers` does for a declared one. Whoever can add a
          subscription then picks servers on your network.
        '';
      };
    };

    subscriptionUpdateInterval = mkOption {
      type = types.str;
      default = "1d";
      description = "How often subscriptions are refreshed (systemd time span).";
      example = "6h";
    };

    selection = mkOption {
      type = types.enum [
        "first"
        "selector"
        "urltest"
        "failover"
      ];
      default = "first";
      description = ''
        How to pick an outbound among the top-level ones: groups and outbounds in no group.
        - "first": the pinned one, or else the first available.
        - "selector": pick by hand.
        - "urltest": the fastest, unless one is pinned.
        - "failover": the first one that works, in `priority` order; moves on within seconds
          of a failure and comes back once the earlier one works again. sing-box and hybrid only.

        `proxy-ctl proxy pin` works in every mode and survives restarts. On sing-box, "selector",
        "urltest" and "failover" switch without restarting the backend.
      '';
      example = "failover";
    };

    groups = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            outbounds = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Member tags, in order: the failover order. Any outbound or group tag.";
              example = [
                "warp-1"
                "warp-2"
              ];
            };
            subscriptions = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Subscriptions whose every entry is a member, as the subscription holds them at start.";
              example = [ "community-list" ];
            };
            match = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Glob patterns (`*`, `?`) over outbound tags; every match is a member.";
              example = [ "de-*" ];
            };
            strategy = mkOption {
              type = types.enum [
                "failover"
                "urltest"
                "selector"
              ];
              default = "failover";
              description = ''
                How the group picks a member:
                - "failover": the first member that works, in order; moves on within seconds of a
                  failure.
                - "urltest": the fastest; `proxy.urlTest.tolerance` keeps it from switching over
                  small differences.
                - "selector": the first member, or the one picked by hand.
              '';
            };
            failback = mkOption {
              type = types.bool;
              default = true;
              description = ''
                With "failover": go back to an earlier member once it has worked three checks in a
                row. Off: stay on the member it moved to until that one fails.
              '';
            };
            interval = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = ''
                How often members are tested (Go duration). `null`: `proxy.urlTest.interval` for
                "urltest", 30s for "failover". Health checks of their own, such as the AmneziaWG
                watchdog's, trigger a test at once.
              '';
              example = "15s";
            };
          };
        }
      );
      default = { };
      description = ''
        Outbound groups: one tag standing for several outbounds, which picks among them. A group
        works wherever an outbound tag does: routing rules, `detour`, pins, other groups. Its
        members are no longer picked on their own at the top level, only through the group.
        sing-box and hybrid only.
      '';
      example = lib.literalExpression ''
        {
          warp-pool.outbounds = [ "warp-1" "warp-2" ];
          eu = {
            subscriptions = [ "community-list" ];
            match = [ "de-*" ];
            strategy = "urltest";
          };
        }
      '';
    };

    priority = mkOption {
      type = types.attrsOf types.int;
      default = { };
      description = ''
        Order of outbounds and groups, lower first: which one "first" and "failover" take, and the
        order of group members pulled in by `subscriptions` or `match`. Tags not listed come after,
        in their usual order. `proxy-ctl proxy priority` changes it at runtime.
      '';
      example = {
        warp-pool = 10;
        de-vps = 20;
      };
    };

    selectionExclude = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Outbound tags that selection never picks on its own, such as chain hops (`detour`) or
        exits meant only for routing rules. Any tag works, including subscription entries,
        `warp`, `ssh-proxy` and AmneziaWG. You can still pin or select them by hand.
      '';
      example = [
        "ru-vps"
        "warp"
      ];
    };

    urlTest = {
      url = mkOption {
        type = types.str;
        default = "https://www.gstatic.com/generate_204";
        description = "URL used to test outbounds. Pick one that is blocked in your region.";
        example = "https://telegram.org";
      };

      interval = mkOption {
        type = types.str;
        default = "3m";
        description = "How often outbounds are tested (Go duration).";
        example = "1m";
      };

      tolerance = mkOption {
        type = types.int;
        default = 50;
        description = "How many milliseconds faster an outbound must be to replace the current one (sing-box only).";
        example = 100;
      };
    };
  };
}
