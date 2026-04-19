{ lib, ... }:

let
  inherit (lib) mkOption types;
  t = import ./types.nix { inherit lib; };
in
{
  options.services.proxy-suite.singBox = {
    outbounds = mkOption {
      type = types.listOf t.outboundType;
      default = [ ];
      description = ''
        List of static proxy outbounds.
        Set exactly one of urlFile, url, or json per entry.

        At least one outbound or one subscription is required when
        singBox.enable = true.
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
        Subscription URLs that provide dynamic lists of proxy outbounds.
        Each URL must return a base64-encoded newline-separated list of proxy URIs
        (standard v2rayN / Clash subscription format) or plain text of the same.

        On first service start, each subscription is fetched live and cached
        under /var/lib/proxy-suite/subscriptions/<tag>.json. Later restarts
        reuse the cache, so ordinary service restarts do not need network access.

        A systemd timer (proxy-suite-subscription-update) refreshes all caches on
        the interval set by subscriptionUpdateInterval and restarts the running
        sing-box services after a successful refresh.
      '';
      example = [
        {
          tag = "community";
          url = "https://example.com/sub/token";
        }
        {
          tag = "private";
          urlFile = "/run/secrets/private-sub-url";
        }
      ];
    };

    subscriptionUpdateInterval = mkOption {
      type = types.str;
      default = "1d";
      description = ''
        How often the proxy-suite-subscription-update timer fires and refreshes
        all subscription caches. Accepts any systemd time span string
        (e.g. "1h", "6h", "1d", "12h").

        Only used when singBox.subscriptions is non-empty. The timer also runs
        once shortly after boot.
      '';
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
        How to pick between multiple proxy outbounds:

        - "first": route through a single active outbound tagged "proxy".
          The first static outbound is used, or the first subscription
          outbound if only subscriptions are configured.
        - "selector": create a Clash-compatible selector outbound tagged
          "proxy" and keep all configured outbounds available for manual
          switching via the Clash API.
        - "urltest": create an automatic latency-testing outbound tagged
          "proxy" and keep all configured outbounds available so sing-box
          can periodically probe and switch to a faster one.

        clashApiPort is only used with "selector" or "urltest".
        urlTest.* options are only used with "urltest".
        Per-outbound tags are only individually meaningful with "selector"
        or "urltest".
      '';
      example = "urltest";
    };

    urlTest = {
      url = mkOption {
        type = types.str;
        default = "https://www.gstatic.com/generate_204";
        description = ''
          URL that sing-box fetches through each proxy to measure latency.
          Only used when selection = "urltest".

          Set this to a URL that is actually blocked in your region (e.g.
          "https://telegram.org") so that only proxies that bypass the
          blocking get selected. If left at the default, any responding proxy
          wins – including ones that might not unblock your target site.
        '';
        example = "https://telegram.org";
      };

      interval = mkOption {
        type = types.str;
        default = "3m";
        description = ''
          How often sing-box re-tests all outbounds. Accepts a Go duration
          string (e.g. "1m", "3m", "10m").
          Only used when selection = "urltest".
        '';
        example = "1m";
      };

      tolerance = mkOption {
        type = types.int;
        default = 50;
        description = ''
          Latency tolerance in milliseconds. The current proxy is only replaced
          when a competing one is faster by more than this value.

          Only used when selection = "urltest".
        '';
        example = 100;
      };
    };

    clashApiPort = mkOption {
      type = types.port;
      default = 9090;
      description = ''
        Port for the Clash-compatible REST API exposed by sing-box.
        Only used when selection is "selector" or "urltest". Ignored in
        "first" mode because there is no selector-style outbound to control.
      '';
      example = 9090;
    };
  };
}
