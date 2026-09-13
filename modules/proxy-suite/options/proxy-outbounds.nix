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
        Static proxy outbounds. The proxy needs at least one outbound or subscription to start;
        `proxy-ctl proxy outbounds add` supplies one at runtime if none is declared here.
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
        Subscription URLs serving a base64 or plain list of proxy URIs. Fetched on first start,
        cached under /var/lib/proxy-suite/subscriptions, refreshed by a timer. Ones added with
        `proxy-ctl proxy subs add` live in /var/lib/proxy-suite/subscriptions.d and refresh alongside.
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
        How to pick among outbounds:
        - "first": one at a time - the pinned outbound, or the first available.
        - "selector": all of them, pick by hand.
        - "urltest": all of them, ranked by latency unless one is pinned.

        `proxy-ctl proxy select` pins an outbound in every mode, and the pin outlives a restart.
        "selector" and "urltest" switch without restarting the backend (sing-box only); "first"
        and XRay restart it.
      '';
      example = "urltest";
    };

    urlTest = {
      url = mkOption {
        type = types.str;
        default = "https://www.gstatic.com/generate_204";
        description = "URL fetched through each outbound to rank them. Pick one blocked in your region.";
        example = "https://telegram.org";
      };

      interval = mkOption {
        type = types.str;
        default = "3m";
        description = "How often outbounds are re-tested (Go duration).";
        example = "1m";
      };

      tolerance = mkOption {
        type = types.int;
        default = 50;
        description = "Milliseconds a faster outbound must win by to replace the current one (sing-box only).";
        example = 100;
      };
    };
  };
}
