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
        description = "Call platform the creator uses. VK has no joiner here.";
        example = "wbstream";
      };

      linkFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          File with the call link from the creator's log. `proxy-ctl wl join <name> <link>` sets
          one at runtime and takes priority. `null`: the joiner waits for that.
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
          Call platform. Each needs an account. "vk" only serves the upstream Android joiner app.
        '';
        example = "wbstream";
      };

      cookiesFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          File with the platform's cookies, as exported by the upstream desktop Creator. Read on
          first start only, since the login refreshes itself afterwards. `proxy-ctl wl auth
          <name>` replaces it at runtime (or asks for email and password on DION and Bitrix).
          `null`: the creator waits for that.
        '';
        example = "/run/secrets/whitelist-bypass-cookies-wbstream.json";
      };

      linkFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          File with a call link to rejoin. `null`: create a call once and keep reusing it, so
          the joiner needs the link only once. `proxy-ctl wl new <name>` starts a new call if the
          platform closed the old one.
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
          Where the traffic from this creator's joiner exits.
          - "direct": straight from this host, bypassing TUN and TProxy.
          - "proxy": through the local proxy and its routing.
        '';
      };

      resources = mkOption {
        type = types.enum [
          "moderate"
          "default"
          "unlimited"
        ];
        default = "moderate";
        description = "Memory budget: 64, 128 or 256 MB.";
      };
    };
  };
in
{
  options.services.proxy-suite.whitelistBypass = {
    enable = mkEnableOption "whitelist-bypass" // {
      description = ''
        Tunnel through video-call servers, which mobile internet whitelists let through
        ([whitelist-bypass](https://github.com/kulikov0/whitelist-bypass)). A creator on a free
        host serves one joiner on a censored one.
      '';
    };

    package = mkOption {
      type = types.package;
      default = proxySuiteUpstream.whitelist-bypass;
      defaultText = lib.literalMD "proxy-suite's `whitelist-bypass` (`pkgs/whitelist-bypass.nix`)";
      description = "whitelist-bypass package.";
    };

    joiners = mkOption {
      type = types.attrsOf joinerType;
      default = { };
      description = ''
        Joiners, each an outbound tagged with its name that tunnels through the call. Needs
        `proxy.enable`.
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
      description = "Creators, one per joiner device. Each logs the call link its joiner needs (also `proxy-ctl wl link`).";
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
