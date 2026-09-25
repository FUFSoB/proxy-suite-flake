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
      ];
      default = "first";
      description = ''
        How to pick an outbound:
        - "first": the pinned one, or else the first available.
        - "selector": pick by hand.
        - "urltest": the fastest, unless one is pinned.

        `proxy-ctl proxy pin` works in every mode and survives restarts. On sing-box, "selector"
        and "urltest" switch without restarting the backend.
      '';
      example = "urltest";
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
