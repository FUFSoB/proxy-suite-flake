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
        outbound can only chain through another XRay one.
      '';
      example = "ru-vps";
    };

  # What a link cannot say: per outbound, or for every entry of a subscription.
  fragmentOption =
    what:
    mkOption {
      type = types.nullOr (
        types.submodule {
          options = {
            packets = mkOption {
              type = types.strMatching "tlshello|[0-9]{1,5}(-[0-9]{1,5})?";
              default = "tlshello";
              description = ''"tlshello", the ClientHello alone, or which packets by number ("1-3").'';
            };
            length = mkOption {
              type = types.strMatching "[0-9]{1,5}(-[0-9]{1,5})?";
              default = "50-100";
              description = "Bytes per piece, or a range to draw from.";
            };
            interval = mkOption {
              type = types.strMatching "[0-9]{1,5}(-[0-9]{1,5})?";
              default = "10-20";
              description = "Milliseconds between pieces, or a range.";
            };
          };
        }
      );
      default = null;
      description = ''
        Split ${what} TLS ClientHello into pieces, against DPI that reads the server name in one
        packet. `{ }` for the defaults. XRay sends it through a freedom hop with these
        settings (with a `detour`, ahead of it); sing-box splits it its own way and ignores the
        numbers, and cannot split a REALITY one. Only for TLS over TCP; others are left as they are.
      '';
      example = { };
    };
  multiplexOption =
    what:
    mkOption {
      type = types.nullOr (
        types.submodule {
          options = {
            protocol = mkOption {
              type = types.enum [
                "h2mux"
                "smux"
                "yamux"
              ];
              default = "h2mux";
              description = "sing-box only: the multiplexer.";
            };
            maxConnections = mkOption {
              type = types.ints.between 1 64;
              default = 4;
              description = "sing-box only: connections to the server at most.";
            };
            padding = mkOption {
              type = types.bool;
              default = false;
              description = "sing-box only: pad the streams (the server must ask for it too).";
            };
            concurrency = mkOption {
              type = types.ints.between 1 1024;
              default = 8;
              description = "XRay only: streams per connection.";
            };
          };
        }
      );
      default = null;
      description = ''
        Carry ${what} connections over a few long-lived ones (vless, vmess, trojan,
        shadowsocks): fewer handshakes, so pages open faster on a slow link. The server must
        speak the same: sing-box's multiplexing (a sing-box inbound with `multiplex.enabled`) and
        XRay's Mux.Cool are not the same protocol. A proxy-suite server serves vless, vmess and
        trojan with XRay, which takes Mux.Cool: dial it with the XRay backend. XRay with XTLS
        Vision multiplexes UDP alone; XHTTP has its own (`proxy.xray.xhttpXmux`). `{ }` for
        the defaults.
      '';
      example = {
        protocol = "smux";
      };
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
      allowPrivateServers = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Keep entries whose server is a private address (10.0.0.0/8, 172.16.0.0/12,
          192.168.0.0/16, 100.64.0.0/10, fc00::/7), such as a subscription served on your own
          network. Entries pointing at this host (loopback, "localhost", unspecified) or at a
          link-local or multicast address are dropped either way: whoever serves the list picks
          the servers, and the fastest wins. Only literal addresses (and "localhost") are
          checked. For subscriptions added at runtime, see
          `proxy.runtimeSubscriptions.allowPrivateServers`.
        '';
      };
      allowInsecure = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Keep entries that turn certificate checks off (`insecure=1`, for hysteria2 and
          AnyTLS on sing-box), as for a provider with self-signed certificates. Anyone on the
          way can then stand in for those servers. Dropped otherwise. For subscriptions added
          at runtime, see `proxy.runtimeSubscriptions.allowInsecure`.
        '';
      };
      userAgent = mkOption {
        type = types.coercedTo types.str lib.singleton (
          types.nonEmptyListOf (types.strMatching "[ -~]{1,256}")
        );
        default = [ "v2rayN/6.0" ];
        description = ''
          User-Agent the subscription is fetched with. Panels pick what they serve by it: to
          v2rayN's, a list of links. Several are tried in order until one gets entries, for a
          panel that serves some clients a stub ("app not supported") instead. A change
          refetches the subscription.
        '';
        example = [
          "v2rayN/6.0"
          "Happ/1.0"
        ];
      };
      sendDeviceInfo = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Tell the server about this device, as Happ and v2RayTun do: its HWID (`x-hwid`), system,
          kernel version and architecture (`x-device-os`, `x-ver-os`, `x-device-model`). For a
          panel that limits devices by HWID and serves nothing without one. The HWID is derived
          from /etc/machine-id, which it does not give away; see `proxy.subscriptionHwidFile`.
        '';
      };
      fragment = fragmentOption "each entry's";
      multiplex = multiplexOption "each entry's";
      updateInterval = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          How often this subscription is refetched (systemd time span). `null`: as often as its
          server asks in its `profile-update-interval` header, but not more than hourly; without
          one, `proxy.subscriptionUpdateInterval`.
        '';
        example = "6h";
      };
    };
  };

  outboundType = types.submodule {
    options = {
      tag = mkOption {
        # `proxy-ctl proxy pin` reads "group/member" in a name.
        type = types.strMatching "[^/]+";
        description = "Unique name, used in routing rules, `detour` and `proxy-ctl`. Not \"proxy\", \"direct\" or \"block\", and without \"/\".";
        example = "vps-de";
      };

      url = nullStr "Proxy link. Ends up in the Nix store; prefer `urlFile`." "hy2://password@example.com:443?sni=example.com";
      urlFile = nullStr "File with the proxy link." "/run/secrets/my-proxy-url";
      detour = detourOption "this outbound";
      fragment = fragmentOption "the outbound's";
      multiplex = multiplexOption "the outbound's";

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

      shadowTls = mkOption {
        type = types.nullOr (
          types.submodule {
            options = {
              version = mkOption {
                type = types.enum [
                  1
                  2
                  3
                ];
                default = 3;
                description = "ShadowTLS protocol version, as the server runs it.";
              };
              serverName = mkOption {
                type = types.str;
                description = "SNI: the site whose TLS handshake the server borrows.";
                example = "www.microsoft.com";
              };
              password = nullStr "ShadowTLS password (version 2 and 3). Ends up in the Nix store; prefer `passwordFile`." "hunter2";
              passwordFile = nullStr "File with the ShadowTLS password." "/run/secrets/shadowtls-password";
              fingerprint = mkOption {
                type = types.nullOr types.str;
                default = "chrome";
                description = "Browser whose TLS ClientHello to imitate (uTLS). `null`: Go's own.";
              };
            };
          }
        );
        default = null;
        description = ''
          Dial this outbound (usually Shadowsocks, from `url`) through ShadowTLS to the same
          server and port, as a proxy-suite "shadowtls" listener and other ShadowTLS servers
          serve it. Its UDP then goes over the stream (UDP over TCP), which the server must take.
          sing-box only: not with the XRay backend, nor with `backend = "xray"` or `detour`.
        '';
        example = {
          serverName = "www.microsoft.com";
          passwordFile = "/run/secrets/shadowtls-password";
        };
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
          XRay-only transports (XHTTP, ECH, VLESS Encryption).
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
