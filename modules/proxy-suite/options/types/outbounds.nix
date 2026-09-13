{ lib, routingFields }:

let
  inherit (lib) mkOption types;
  nullStr =
    description: example:
    mkOption {
      type = types.nullOr types.str;
      default = null;
      inherit description example;
    };
  nullAttrs =
    description: example:
    mkOption {
      type = types.nullOr types.attrs;
      default = null;
      inherit description example;
    };

  subscriptionType = types.submodule {
    options = {
      tag = mkOption {
        type = types.strMatching "^[A-Za-z0-9][A-Za-z0-9._-]*$";
        description = "Unique name; prefixes the tags of its outbounds and names its cache file.";
        example = "community-list";
      };
      url = nullStr "Subscription URL. Ends up in the Nix store; prefer urlFile." "https://example.com/sub/token123";
      urlFile = nullStr "Runtime path to the subscription URL." "/run/secrets/proxy-subscription-url";
    };
  };

  outboundType = types.submodule {
    options = {
      tag = mkOption {
        type = types.str;
        description = "Outbound tag, for routing rules and selection.";
        example = "vps-de";
      };

      url = nullStr "Proxy URL. Ends up in the Nix store; prefer urlFile." "hy2://password@example.com:443?sni=example.com";
      urlFile = nullStr "Runtime path to the proxy URL." "/run/secrets/my-proxy-url";

      singBoxJson = nullAttrs "Raw sing-box outbound (sing-box backend); tag is overridden." {
        type = "vless";
        server = "example.com";
        server_port = 443;
      };

      xrayJson = nullAttrs "Raw XRay outbound (XRay backend); tag is overridden." {
        protocol = "vless";
        settings.address = "example.com";
      };

      json = mkOption {
        type = types.nullOr types.attrs;
        default = null;
        visible = false;
        description = "Deprecated alias for singBoxJson.";
      };

      backend = mkOption {
        type = types.enum [
          "auto"
          "sing-box"
          "xray"
        ];
        default = "auto";
        description = ''
          Backend for this outbound when both run. "auto" prefers sing-box and falls back to XRay
          for XRay-only transports (XHTTP, ECH).
        '';
        example = "xray";
      };

      # Destinations sent to this outbound (selection "selector" or "urltest").
      routing = routingFields;
    };
  };
in
{
  inherit subscriptionType outboundType;
}
