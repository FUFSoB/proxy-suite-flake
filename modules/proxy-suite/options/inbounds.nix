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
  inherit (import ./lib.nix { inherit lib; }) bool;
in
{
  options.services.proxy-suite.inbounds = {
    enable = mkEnableOption "server inbounds, which accept proxy clients from outside";

    package = mkOption {
      type = types.package;
      default = proxySuiteUpstream.xray;
      defaultText = literalMD "proxy-suite's `xray` (`pkgs/xray.nix`)";
      example = literalExpression "pkgs.xray";
      description = "XRay package that runs the inbounds, whichever client backend is used.";
    };

    serverAddress = mkOption {
      type = types.nullOr (types.strMatching "[^[:space:]]+");
      default = null;
      description = "Public address for share links. `null`: detect the uplink IPv4.";
      example = "vpn.example.com";
    };

    openFirewall = bool true "Open the firewall for every listener not on loopback.";
    shareLinks = bool true "Generate client share links for `proxy-ctl inbounds link`. Readable by root, and by `userControl.group` with the secrets scope.";

    subscriptions = {
      enable = mkEnableOption "" // {
        description = ''
          Generate a subscription per user, with their links from every listener, in
          /run/proxy-suite-inbounds/subscriptions/<token>. Serve that directory with a web server.
          Needs `shareLinks`.
        '';
      };

      group = mkOption {
        type = types.str;
        default = "nginx";
        description = "Group of the web server that serves the subscription files.";
        example = "caddy";
      };

      baseUrl = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Public URL of the subscription directory, used by `proxy-ctl inbounds sub`.";
        example = "https://vpn.example.com/sub";
      };
    };

    # Mirrors proxy.routing, for traffic arriving from outside instead of from this host.
    routing = {
      via = mkOption {
        type = types.str;
        default = "proxy";
        description = ''
          Where client traffic exits by default. Each listener can override it.
          - "proxy": through the local proxy and its current pick (needs `proxy.enable`).
          - an outbound tag from `proxy.outbounds`: always that one (`url`, `urlFile` or `xrayJson` only).
          - "direct": straight from this host.
          - "block": dropped.
        '';
        example = "direct";
      };

      proxy = t.routingFields "that clients always reach through the local proxy, whatever the listener's `via`";

      blockRu = bool true ''Block Russian destinations (geosite "category-ru", geoip "ru").'';
      blockPrivate = bool true "Block private and loopback addresses, so clients cannot reach this host's LAN or local services.";

      zapretDirect = bool true "Send zapret hostlist sites direct, so this host's zapret unblocks them. Only for the default `via`.";
    };

    listeners = mkOption {
      type = types.attrsOf t.inboundType;
      default = { };
      description = "Server listeners, by tag.";
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
          # `proxy-ctl inbounds link home phone` prints a vpn:// link; add --config for the .conf.
          home = {
            type = "amneziawg";
            port = 51820;
            users = [ { name = "phone"; } { name = "laptop"; } ];
            amneziaWg.mode = "lan";
          };
        }
      '';
    };
  };
}
