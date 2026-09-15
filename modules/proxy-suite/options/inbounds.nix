{ lib, proxySuiteUpstream, ... }:

let
  inherit (lib)
    literalExpression
    literalMD
    mkEnableOption
    mkOption
    types
    ;
  t = import ./types.nix { inherit lib; };
  bool =
    default: description:
    mkOption {
      type = types.bool;
      inherit default description;
    };
in
{
  options.services.proxy-suite.inbounds = {
    enable = mkEnableOption "server inbounds that accept proxy connections from outside";

    package = mkOption {
      type = types.package;
      default = proxySuiteUpstream.xray;
      defaultText = literalMD "proxy-suite's `xray` (`pkgs/xray.nix`)";
      example = literalExpression "pkgs.xray";
      description = "XRay package serving the inbounds, whatever the client-side backend.";
    };

    serverAddress = mkOption {
      type = types.nullOr (types.strMatching "[^[:space:]]+");
      default = null;
      description = "Public address clients connect to, used in share links. Null detects the uplink IPv4.";
      example = "vpn.example.com";
    };

    openFirewall = bool true "Open every non-loopback listener port.";
    shareLinks = bool true "Write client share links for `proxy-ctl inbounds link` (root, and userControl.group with the secrets scope).";

    subscriptions = {
      enable = mkEnableOption "" // {
        description = ''
          Write one subscription file per user (their links from every listener, base64) to
          /run/proxy-suite-inbounds/subscriptions/<token>. Serve that directory with a web server;
          see the README.
        '';
      };

      group = mkOption {
        type = types.str;
        default = "nginx";
        description = "Group allowed to read the subscription files: the web server serving them.";
        example = "caddy";
      };

      baseUrl = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "URL the subscription directory is served at, for `proxy-ctl inbounds sub`.";
        example = "https://vpn.example.com/sub";
      };
    };

    # Mirrors proxy.routing, for traffic arriving from outside instead of from this host.
    routing = {
      via = mkOption {
        type = types.str;
        default = "proxy";
        description = ''
          Default egress of inbound traffic; listeners can override it:
          - "proxy": through the local proxy and its current selection (needs proxy.enable).
          - a proxy.outbounds tag: pinned to that server (url, urlFile or xrayJson outbounds only).
          - "direct": out from this machine.
          - "block": dropped.
        '';
        example = "direct";
      };

      proxy = t.routingFields;

      blockRu = bool true ''Block Russian destinations (geosite "category-ru", geoip "ru").'';
      blockPrivate = bool true "Block private and loopback destinations, so clients cannot reach this host's LAN or local services.";

      zapretDirect = bool true "Send zapret's hostlist destinations direct, so this host's zapret unblocks them (default via only).";
    };

    listeners = mkOption {
      type = types.attrsOf t.inboundType;
      default = { };
      description = "Listeners by tag.";
      example = literalExpression ''
        {
          vless-reality = {
            type = "vless";
            port = 443;
            users = [ { uuidFile = "/run/secrets/proxy-inbound-uuid"; } ];
            flow = "xtls-rprx-vision";
            reality = {
              enable = true;
              serverNames = [ "www.microsoft.com" ];
              privateKeyFile = "/run/secrets/proxy-inbound-reality-key";
              publicKey = "jNXH...";
              shortIds = [ "0123abcd" ];
            };
          };
        }
      '';
    };
  };
}
