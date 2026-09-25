{ lib, routingFields }:

let
  inherit (lib) mkOption types;
  inherit (import ../lib.nix { inherit lib; }) nullStr;
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
        Tag of an outbound that ${what} connects through (a proxy chain). Any outbound works,
        including subscription entries, `warp`, `ssh-proxy` and AmneziaWG. On hybrid, an XRay
        outbound can only chain through another XRay one. For ShadowTLS, put a `shadowtls`
        outbound in `singBoxJson` and point the shadowsocks outbound's `detour` at it.
      '';
      example = "ru-vps";
    };

  subscriptionType = types.submodule {
    options = {
      tag = mkOption {
        type = types.strMatching "^[A-Za-z0-9][A-Za-z0-9._-]*$";
        description = "Unique name, used as a prefix for the tags of its outbounds.";
        example = "community-list";
      };
      url = nullStr "Subscription URL. Ends up in the Nix store; prefer `urlFile`." "https://example.com/sub/token123";
      urlFile = nullStr "File with the subscription URL." "/run/secrets/proxy-subscription-url";
      detour = detourOption "every entry of this subscription";
    };
  };

  outboundType = types.submodule {
    options = {
      tag = mkOption {
        type = types.str;
        description = "Unique name, used in routing rules, `detour` and `proxy-ctl`. Not \"proxy\", \"direct\" or \"block\".";
        example = "vps-de";
      };

      url = nullStr "Proxy link. Ends up in the Nix store; prefer `urlFile`." "hy2://password@example.com:443?sni=example.com";
      urlFile = nullStr "File with the proxy link." "/run/secrets/my-proxy-url";
      detour = detourOption "this outbound";

      singBoxJson =
        nullAttrs "Raw sing-box outbound JSON, instead of `url` (sing-box backend). Its tag is replaced."
          {
            type = "vless";
            server = "example.com";
            server_port = 443;
          };

      xrayJson =
        nullAttrs "Raw XRay outbound JSON, instead of `url` (XRay backend). Its tag is replaced."
          {
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
          Which engine runs this outbound on the hybrid backend. "auto" uses sing-box, or XRay for
          XRay-only transports (XHTTP, ECH).
        '';
        example = "xray";
      };

      routing = routingFields "always sent to this outbound, whatever the selection";
    };
  };
in
{
  inherit subscriptionType outboundType;
}
