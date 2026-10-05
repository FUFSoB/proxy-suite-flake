{
  config,
  lib,
  proxySuiteUpstream,
  ...
}:

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

    serverAliases = mkOption {
      type = types.listOf (types.strMatching "[^[:space:]]+");
      default = [ ];
      description = ''
        Other names and IPs of this host that clients reach through the tunnel, such as a
        TURN relay's name beside the site on `serverAddress`. Like `serverAddress`, they go
        direct on the listener ports instead of looping back through `routing.via`, which
        often cannot reach this host at all. List the IPs too: a client that resolves a name
        itself hands XRay the address, which no name rule matches. `domain:example.com`
        covers that name and every name under it, for a host behind a wildcard record.
      '';
      example = [
        "turn.example.com"
        "domain:example.com"
        "203.0.113.10"
        "2001:db8::10"
      ];
    };

    serverPorts = mkOption {
      type = types.listOf (types.either types.port (types.strMatching "[0-9]+-[0-9]+"));
      default = [ ];
      description = ''
        Ports of this host's other services that clients reach through the tunnel on
        `serverAddress` and `serverAliases`, such as mail, beside the listeners' own. Direct
        like those: a connection to this host from itself skips its firewall, so list only
        what the firewall already opens to the internet. TCP and UDP alike. Any other port on
        any address of this host is refused where the inbounds dial "direct" themselves; the
        addresses are read as the inbounds start, so restart them after one changes (DHCP).
        Without `routing.serverSource` these connections come from this host's own address,
        which its services may trust: a mail server that relays for its own host (Postfix's
        default `mynetworks`) relays for every inbound user then. Set `serverSource`, or keep
        such services from trusting this host's own addresses.
      '';
      example = literalExpression "config.networking.firewall.allowedTCPPorts";
    };

    accessLog = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Log every connection, with the user, their address and the site, to the journal of
        proxy-suite-inbounds: who went where, for anyone who can read the journal. On with
        `proxy.autoProxy` whatever this says, which learns from those lines.
      '';
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
      blockPrivate = bool true ''
        Block private and loopback addresses, so clients cannot reach this host's LAN or local
        services. Off, the LAN is open but this host is not. Either way, this host's own
        addresses (loopback, and its public ones as its interfaces carry them at start) are
        reachable only on the listener ports and `serverPorts`, whichever `via` a client takes.
      '';

      zapretDirect = bool true "Send zapret hostlist sites direct, so this host's zapret unblocks them. Only for the default `via`. With a direct listener or the XRay backend, only by IP: XRay matches names by what a client puts in its handshake, whatever address it connects to.";

      # Consumed in derived.nix (the addresses), rules/proxy-inbounds.nix and the inbounds'
      # start script (the interface).
      serverSource = {
        ipv4 = mkOption {
          type = types.nullOr (types.strMatching "([0-9]{1,3}\\.){3}[0-9]{1,3}/[0-9]{1,2}");
          default = null;
          example = "10.78.0.0/24";
          description = ''
            Range each inbound user gets an address from, for the connections they make to this
            host itself (`serverAddress`, `serverAliases`, `serverPorts`). Otherwise those come
            from this host's own address, and its services (mail, the web server, their rate
            limits and bans) see every user as one. They see neither the users' real addresses.
            The addresses sit on a dummy interface and reach nothing but this host. Pick a range
            nothing here routes or trusts. Users are numbered by their `order`, then name, from
            the range's second address: set `order` to keep each user's address as users come
            and go.
          '';
        };
        ipv6 = mkOption {
          type = types.nullOr (types.strMatching "[0-9a-fA-F:]*::/[0-9]{1,3}");
          default = null;
          example = "fd78:78:78::/64";
          description = ''
            The same for IPv6: a prefix written with "::", such as a ULA /64. Needed as well when
            `serverAliases` lists an IPv6 address, which is otherwise dialed from this host's own.
          '';
        };
        interface = mkOption {
          type = types.strMatching "[a-zA-Z0-9_-]{1,15}";
          default = "ps-self";
          description = "Dummy interface the `serverSource` addresses are put on.";
        };
      };
    };

    # Consumed by scripts/inbound_runtime.py, which merges the spool into the spec at start,
    # and by proxy-ctl, which writes the spool.
    runtime = {
      enable = mkEnableOption "" // {
        description = ''
          Users and listeners added at runtime with `proxy-ctl inbounds users add` and
          `inbounds add`, kept in `inbounds.d` in the state directory. Runtime users can be
          bound to any listener; declared users to runtime listeners only. A change restarts
          the inbounds, which drops every connection once. Anything a runtime listener could
          reach beyond its port is declared here: its ports, certificates, exits and
          fallbacks. Members of `userControl.group` need the "inbounds" scope.
        '';
      };

      ports = mkOption {
        type = types.listOf (types.either types.port (types.strMatching "[0-9]+-[0-9]+"));
        default = [ ];
        description = ''
          Ports runtime listeners may use, on any address: single ports and "from-to" ranges.
          Opened in the firewall (TCP and UDP) with `openFirewall`, and reachable through the
          tunnel like the listeners' own. Keep them clear of the declared listeners and of
          other services here.
        '';
        example = [
          8443
          "20000-20099"
        ];
      };

      vias = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Exits a runtime listener may pick with `via`, besides `routing.via` and "block":
          "proxy", "direct" or a `proxy.outbounds` tag, as in `routing.via`.
        '';
        example = [ "direct" ];
      };

      tlsCertificates = mkOption {
        type = types.attrsOf (
          types.submodule {
            options = {
              certificateFile = mkOption {
                type = types.str;
                description = "File with the PEM certificate chain.";
              };
              keyFile = mkOption {
                type = types.str;
                description = "File with the PEM private key.";
              };
              serverName = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "SNI in share links. `null`: `serverAddress`.";
              };
            };
          }
        );
        default = { };
        description = ''
          Certificates a runtime listener with TLS (trojan, hysteria2, `tls.enable`) may use,
          by name: it names one in `tls.certificate` (`--tls <name>`), never a file.
        '';
        example = literalExpression ''
          {
            main = {
              certificateFile = "/var/lib/acme/vpn.example.com/fullchain.pem";
              keyFile = "/var/lib/acme/vpn.example.com/key.pem";
            };
          }
        '';
      };

      fallbackDests = mkOption {
        type = types.listOf (types.either types.port types.str);
        default = [ ];
        description = ''
          `dest` values a runtime listener's fallbacks may use, such as a decoy site. A
          fallback to a `listener` must name another runtime listener. A runtime listener's
          `reality.dest` may be any public site on port 443; one on another port, on this host
          or on a private network must be listed here. Its `hysteria.masquerade` must be a
          public http(s) site, on port 80 or 443 unless its `host:port` is listed here.
        '';
        example = [ "127.0.0.1:8080" ];
      };
    };

    users = mkOption {
      type = types.attrsOf (types.submodule t.userModule);
      default = { };
      description = ''
        Inbound users, by name, which listeners accept by naming them in their `users`. Each
        listener takes the secret its protocol wants: `uuid`/`uuidFile` for vless and vmess,
        `password`/`passwordFile` for the others, the keys for AmneziaWG.
      '';
      example = literalExpression ''
        {
          phone = {
            order = 1;
            uuidFile = "/run/secrets/proxy-inbound-uuid";
          };
          laptop.order = 2;
        }
      '';
    };

    listeners = mkOption {
      type = types.attrsOf t.inboundType;
      default = { };
      description = "Server listeners, by tag.";
      # Each named user becomes the user, with their name: nothing past the options sees names.
      apply = lib.mapAttrs (
        tag: listener:
        listener
        // {
          users = map (
            name:
            (config.services.proxy-suite.inbounds.users.${name}
              or (throw "proxy-suite: inbounds listener '${tag}' names user '${name}', which inbounds.users does not define")
            )
            // {
              inherit name;
            }
          ) listener.users;
        }
      );
      example = literalExpression ''
        {
          vless-reality = {
            type = "vless";
            port = 443;
            users = [ "phone" ];
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
            users = [ "phone" "laptop" ];
            amneziaWg.mode = "lan";
          };
        }
      '';
    };
  };
}
