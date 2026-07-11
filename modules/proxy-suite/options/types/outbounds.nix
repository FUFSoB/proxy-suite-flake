# Subscription and outbound option type definitions.
{ lib, routingFields }:

let
  inherit (lib) mkOption types;

  subscriptionType = types.submodule {
    options = {
      tag = mkOption {
        type = types.strMatching "^[A-Za-z0-9][A-Za-z0-9._-]*$";
        description = ''
          Unique identifier for this subscription.
          Used as a prefix for all outbound tags generated from its proxy list,
          e.g. "my-sub" -> tags like "my-sub-Server-DE".

          This value is also used as the subscription cache filename stem under
          /var/lib/proxy-suite/subscriptions/<backend>/, so it must be a safe
          identifier.
        '';
        example = "community-list";
      };

      url = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Literal subscription URL. The response must be a base64-encoded
          newline-separated list of proxy URIs (standard v2rayN format) or
          a plain-text list of the same.

          This value is embedded in the Nix store. Prefer urlFile for private
          subscription links or tokens.
        '';
        example = "https://example.com/sub/token123";
      };

      urlFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Runtime path to a file containing the subscription URL.
          Intended for use with secret managers (sops-nix, agenix, etc.).
          The file is read at service start time and never lands in the Nix store.

          Set exactly one of urlFile or url for each subscription entry.
        '';
        example = "/run/secrets/proxy-subscription-url";
      };
    };
  };

  outboundType = types.submodule {
    options = {
      tag = mkOption {
        type = types.str;
        description = ''
          Outbound tag used in routing rules and multi-outbound selection.

          With selection = "selector" or "urltest", each outbound keeps its own
          tag and can be selected directly. With selection = "first", proxy-suite
          routes through a single active outbound tagged "proxy", so individual
          proxy tags are mainly useful for documentation and config structure.
        '';
        example = "vps-de";
      };

      urlFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Runtime path to a file containing the proxy URL.
          Intended for use with secret managers (sops-nix, agenix, etc.).
          The file is read at service start time and never lands in the Nix store.

          Set exactly one of urlFile, url, or json for each outbound.
        '';
        example = "/run/secrets/my-proxy-url";
      };

      url = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Literal proxy URL. Convenient for non-secret configs, but the URL
          will end up in the Nix store.

          Set exactly one of urlFile, url, or json for each outbound.
          Prefer urlFile for real credentials.
        '';
        example = "hy2://password@example.com:443?sni=example.com";
      };

      backend = mkOption {
        type = types.enum [
          "auto"
          "sing-box"
          "xray"
        ];
        default = "auto";
        description = ''
          Backend preference for this outbound when both SingBox and XRay are
          enabled. "auto" uses SingBox when the URL or JSON can be represented
          there and falls back to XRay for XRay-only transports such as XHTTP
          or ECH. Ignored by single-backend configurations.
        '';
        example = "xray";
      };

      singBoxJson = mkOption {
        type = types.nullOr types.attrs;
        default = null;
        description = ''
          Raw sing-box outbound configuration as a Nix attribute set.
          Embedded directly into the config at build time. The tag field
          is overridden by the outbound's tag option.

          Set exactly one of urlFile, url, singBoxJson, xrayJson, or json for
          each outbound.
          Use this when the proxy definition is easier to generate as native Nix
          than as a single URL string. Only valid with the SingBox backend.
        '';
        example = {
          type = "vless";
          server = "example.com";
          server_port = 443;
          uuid = "...";
        };
      };

      xrayJson = mkOption {
        type = types.nullOr types.attrs;
        default = null;
        description = ''
          Raw XRay outbound configuration as a Nix attribute set.
          Embedded directly into the config at build time. The tag field is
          overridden by the outbound's tag option.

          Set exactly one of urlFile, url, singBoxJson, xrayJson, or json for
          each outbound. Only valid with the XRay backend.
        '';
        example = {
          protocol = "vless";
          settings = {
            address = "example.com";
            port = 443;
            id = "...";
            encryption = "none";
          };
        };
      };

      json = mkOption {
        type = types.nullOr types.attrs;
        default = null;
        visible = false;
        description = ''
          Deprecated alias for singBoxJson. Use singBoxJson instead.
        '';
      };

      # Shorthand for attaching routing rules directly to an outbound definition.
      # Traffic matching these patterns is sent to this specific outbound.
      # Only meaningful when selection = "selector" or "urltest" (with "first",
      # all proxy traffic goes to the single "proxy" outbound anyway).
      routing = routingFields;
    };
  };
in
{
  inherit subscriptionType outboundType;
}
