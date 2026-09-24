{ lib, proxySuiteUpstream, ... }:

let
  inherit (lib) mkEnableOption mkOption types;

  joinerType = types.submodule {
    options = {
      platform = mkOption {
        type = types.enum [
          "wbstream"
          "telemost"
          "dion"
          "bitrix"
        ];
        description = "Call platform the creator on the other end uses. VK has no Linux joiner.";
        example = "wbstream";
      };

      linkFile = mkOption {
        type = types.str;
        description = ''
          Runtime path to the call link the creator printed (or wrote to its state directory):
          a WB Stream room id, a Telemost link, a DION event slug or a Bitrix conference link.
        '';
        example = "/run/secrets/whitelist-bypass-link";
      };
    };
  };

  creatorType = types.submodule {
    options = {
      platform = mkOption {
        type = types.enum [
          "wbstream"
          "telemost"
          "dion"
          "bitrix"
          "vk"
        ];
        description = ''
          Call platform. Every one needs an account: "vk" only serves the upstream Android app,
          the rest a joiner of this module too.
        '';
        example = "wbstream";
      };

      cookiesFile = mkOption {
        type = types.str;
        description = ''
          Runtime path to the platform's cookies, as the upstream desktop Creator exports them.
          Copied into the state directory on first start only: DION and Bitrix rotate their
          refresh token into that copy, and a stale one would kill the session. Delete
          `<stateDir>/whitelist-bypass/<name>.cookies.json` to take a new export.
        '';
        example = "/run/secrets/whitelist-bypass-cookies-wbstream.json";
      };

      linkFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Runtime path to the call to rejoin. Null rejoins the last call written to
          `<stateDir>/whitelist-bypass/<name>.link`, and creates one on first start: the link
          stays the same across restarts, so the joiner needs it only once.
        '';
        example = "/run/secrets/whitelist-bypass-link";
      };

      upstream = mkOption {
        type = types.enum [
          "direct"
          "proxy"
        ];
        default = "direct";
        description = ''
          Where the joiner's traffic leaves.
          - "direct": from this host, past TUN and TProxy (it runs as proxy-suite-daemon).
          - "proxy": through the local proxy listener (proxy.listener, with its auth), and so
            its outbounds and routing.
        '';
      };

      resources = mkOption {
        type = types.enum [
          "moderate"
          "default"
          "unlimited"
        ];
        default = "moderate";
        description = "Buffer sizes and Go memory limit: 64, 128 or 256 MB.";
      };
    };
  };
in
{
  options.services.proxy-suite.whitelistBypass = {
    enable = mkEnableOption ''
      tunnels through the media servers of video calls, which mobile internet whitelists let
      through ([whitelist-bypass](https://github.com/kulikov0/whitelist-bypass)). A creator on a
      free host serves exactly one joiner on a censored one'';

    package = mkOption {
      type = types.package;
      default = proxySuiteUpstream.whitelist-bypass;
      defaultText = lib.literalMD "proxy-suite's `whitelist-bypass` (`pkgs/whitelist-bypass.nix`)";
      description = "whitelist-bypass package with the headless creators and joiners.";
    };

    joiners = mkOption {
      type = types.attrsOf joinerType;
      default = { };
      description = ''
        Joiners, each an outbound tagged with its name: a loopback SOCKS5 listener that tunnels
        through the call. Needs proxy.enable.
      '';
      example = {
        wl = {
          platform = "wbstream";
          linkFile = "/run/secrets/whitelist-bypass-link";
        };
      };
    };

    creators = mkOption {
      type = types.attrsOf creatorType;
      default = { };
      description = "Creators, one per joiner device. The link each uses is in its log.";
      example = {
        phone = {
          platform = "wbstream";
          cookiesFile = "/run/secrets/whitelist-bypass-cookies-wbstream.json";
          upstream = "proxy";
        };
      };
    };
  };
}
