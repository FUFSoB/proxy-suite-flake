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
        List of static proxy outbounds.
        Set exactly one of urlFile, url, singBoxJson, xrayJson, or the
        deprecated json field per entry. Backend-specific raw JSON fields are
        only valid with their matching backend.

        At least one outbound or one subscription is required when
        proxy.enable = true.
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
        under /var/lib/proxy-suite/subscriptions/<backend>/<tag>.json. Later restarts
        reuse the cache, so ordinary service restarts do not need network access.

        A systemd timer (proxy-suite-subscription-update) refreshes all caches
        on the interval set by subscriptionUpdateInterval and restarts the
        running proxy services after a successful refresh.
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

        Only used when proxy.subscriptions is non-empty. The timer also runs
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
        - "urltest": create automatic latency testing tagged "proxy" and
          keep all configured outbounds available so the active backend can
          periodically probe and switch to a faster one.

        proxy.singBox.clashApiPort is only used with "selector" or "urltest"
        on the SingBox backend. "selector" is SingBox-only. "urltest" maps to
        SingBox urltest or XRay observatory/balancer depending on backend.
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
          URL that the active backend fetches through each proxy to measure latency.
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
          How often the active backend re-tests all outbounds. Accepts a Go
          duration string (e.g. "1m", "3m", "10m").
          Only used when selection = "urltest".
        '';
        example = "1m";
      };
    };
  };
}
