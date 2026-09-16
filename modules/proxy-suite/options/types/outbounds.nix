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

  detourOption =
    what:
    mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Tag of the outbound ${what} connects through: a proxy chain. Any outbound can be the hop,
        subscription entries, `warp`, `ssh-proxy` and AmneziaWG ones included. On hybrid, an
        outbound that runs on XRay can only chain through another XRay one. ShadowTLS works this
        way too: a `shadowtls` outbound in singBoxJson, and the shadowsocks one with detour naming it.
      '';
      example = "ru-vps";
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
      detour = detourOption "every entry of this subscription";
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
      detour = detourOption "this one";

      singBoxJson = nullAttrs "Raw sing-box outbound (sing-box backend); tag is overridden." {
        type = "vless";
        server = "example.com";
        server_port = 443;
      };

      xrayJson = nullAttrs "Raw XRay outbound (XRay backend); tag is overridden." {
        protocol = "vless";
        settings.address = "example.com";
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

      # Destinations sent to this outbound, whatever the selection.
      routing = routingFields;
    };
  };
in
{
  inherit subscriptionType outboundType;
}
