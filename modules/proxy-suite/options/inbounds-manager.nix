{ config, lib, ... }:

let
  inherit (lib)
    literalExpression
    mkEnableOption
    mkOption
    types
    ;
  cfg = config.services.proxy-suite.inbounds;
  listenType = types.strMatching "([[][0-9A-Fa-f:.]+[]]|[0-9.]+|localhost):[0-9]{1,5}";
  # scripts/inbound_manager.py's EVENTS.
  events = [
    "user.created"
    "user.deleted"
    "user.updated"
    "user.enabled"
    "user.disabled"
    "user.reset"
    "user.activated"
    "user.traffic"
    "user.expiring"
    "user.ip-limit"
  ];
in
{
  # Consumed by scripts/inbound_manager.py (manager.json, service/inbounds-manager.nix) and
  # scripts/inbound_policy.py (the spec's "manager").
  options.services.proxy-suite.inbounds.manager = {
    enable = mkEnableOption "" // {
      description = ''
        The inbound manager, a daemon that keeps the users' policies (`inbounds.users.<name>.policy`,
        and what it is told at runtime): who is switched off, whose time ran out, who used up
        their traffic, how many addresses and how much speed each may have. It applies them to
        the running inbounds without a restart, answers an HTTP+JSON API for proxy-ctl and bots,
        serves subscriptions with the traffic and expiry clients show, and calls webhooks.
        Users and listeners added through it need `inbounds.runtime`.
      '';
    };

    interval = mkOption {
      type = types.ints.between 5 3600;
      default = 30;
      description = "Seconds between two rounds of counting traffic and checking the policies.";
    };

    api = {
      group = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Group that may use the API socket, /run/proxy-suite-inbounds-manager/api.sock: all of
          it, every user's secrets included. `null`: `userControl.group` when it has the
          "inbounds" scope, root only otherwise.
        '';
        example = "vpn-admins";
      };
      listen = mkOption {
        type = types.nullOr listenType;
        default = null;
        description = ''
          Address and port the API also listens on over TCP, for a bot on another host. Plain
          HTTP: put it on loopback behind a TLS proxy. Needs `tokensFile`; the firewall is not
          opened for it.
        '';
        example = "127.0.0.1:9180";
      };
      tokensFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          File with the bearer tokens the TCP API takes, one per line, "name:token" or the token
          alone. Read at start.
        '';
        example = "/run/secrets/inbounds-manager-tokens";
      };
    };

    subscriptions = {
      enable = mkOption {
        type = types.bool;
        default = cfg.shareLinks;
        defaultText = literalExpression "config.services.proxy-suite.inbounds.shareLinks";
        description = ''
          Serve each user's subscription from /run/proxy-suite-inbounds-manager/sub.sock, with the
          headers clients read their traffic, allowance and expiry from (subscription-userinfo),
          a title and an update interval. The token is the last part of the path, the same
          as the static files' (`inbounds.subscriptions`), so their URLs keep working:
          ```nix
          services.nginx.virtualHosts."vpn.example.com".locations."/sub/".proxyPass =
            "http://unix:/run/proxy-suite-inbounds-manager/sub.sock:";
          ```
        '';
      };
      group = mkOption {
        type = types.str;
        default = cfg.subscriptions.group;
        defaultText = literalExpression "config.services.proxy-suite.inbounds.subscriptions.group";
        description = "Group of the web server that connects to the subscription socket.";
      };
      listen = mkOption {
        type = types.nullOr listenType;
        default = null;
        description = "Address and port the subscriptions are also served on over TCP, for a web server that cannot reach the socket.";
        example = "127.0.0.1:9181";
      };
      profileTitle = mkOption {
        type = types.str;
        default = "{user}";
        description = "The profile's name in clients; {user} is the user's.";
        example = "My VPN ({user})";
      };
      updateInterval = mkOption {
        type = types.nullOr types.ints.positive;
        default = 12;
        description = "Hours between clients' updates of the subscription (profile-update-interval).";
      };
      supportUrl = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Where clients send users for help (support-url), such as a Telegram link.";
        example = "https://t.me/my_vpn_support";
      };
      webPageUrl = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "The service's page (profile-web-page-url).";
      };
    };

    speedLimits = {
      enable = mkEnableOption "" // {
        description = ''
          Speed limits (`policy.speedLimit`). XRay marks the sockets its exits dial for a limited
          user with the user's slot, which proxy-suite's XRay build carries a patch for
          (pkgs/patches/xray-user-level-mark.patch), and nftables polices each mark's
          traffic both ways. AmneziaWG peers are policed by their tunnel address. Needs root.
        '';
      };
      slots = mkOption {
        type = types.ints.between 1 65535;
        default = 512;
        description = "How many users may have a speed limit at once: an XRay user level each.";
      };
    };

    deleteExpiredAfter = mkOption {
      type = types.nullOr (types.strMatching "[0-9]+[mhdw]");
      default = null;
      description = ''
        Delete runtime users this long after their `expiresAt`, as `proxy-ctl inbounds users rm`
        would: their secrets, policy and subscription go. A number with m, h, d or w. Users
        declared in the config stay. `null`: never.
      '';
      example = "30d";
    };

    ipLimit.banTime = mkOption {
      type = types.ints.positive;
      default = 600;
      description = "Seconds an address past a user's `ipLimit` is banned for.";
    };

    notify = {
      trafficPercent = mkOption {
        type = types.listOf (types.ints.between 1 100);
        default = [
          80
          100
        ];
        description = "Shares of the traffic allowance used that send a user.traffic event, once per period.";
      };
      expiryDays = mkOption {
        type = types.listOf types.ints.positive;
        default = [
          3
          1
        ];
        description = "Days before the expiry that send a user.expiring event.";
      };
    };

    webhooks = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            url = mkOption {
              type = types.str;
              description = "URL the events are POSTed to as JSON: {event, user, at, data}.";
            };
            events = mkOption {
              type = types.listOf (types.enum events);
              default = [ ];
              description = "Events to send. Empty: all of them.";
            };
            secretFile = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "File with a secret: each body is signed, X-Proxy-Suite-Signature: sha256=<HMAC-SHA256 hex>.";
            };
          };
        }
      );
      default = [ ];
      description = ''
        Where to tell about users created, deleted, updated, switched off (with why) and back
        on, their traffic reset, their term started on their first connection (user.activated), thresholds of their allowance, coming expiries and addresses
        banned past their ipLimit. Retried a few times; a hook that stays down misses them.
      '';
      example = literalExpression ''
        [ { url = "http://127.0.0.1:8088/proxy-suite"; secretFile = "/run/secrets/hook"; } ]
      '';
    };
  };
}
