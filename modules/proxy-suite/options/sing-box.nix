# Core sing-box options. Feature-area options live in sing-box-{outbounds,dns,tun,tproxy,routing}.nix.
{ lib, ... }:

let
  inherit (lib) mkOption mkEnableOption types;
in
{
  options.services.proxy-suite.singBox = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to configure and run sing-box services for proxy-suite.
        When disabled, sing-box services and generated sing-box configs are
        skipped even if proxy-suite itself is enabled.
      '';
    };

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = ''
        Address for the SOCKS5/HTTP mixed inbound to bind to.
        This affects the always-on proxy-suite-socks service.

        Use "0.0.0.0" only if you intentionally want to expose the proxy to
        other machines on your network.
      '';
      example = "127.0.0.1";
    };

    port = mkOption {
      type = types.port;
      default = 1080;
      description = ''
        Listen port for the always-on SOCKS5/HTTP mixed inbound provided by
        proxy-suite-socks.
      '';
      example = 1080;
    };

    auth = {
      username = mkOption {
        type = types.nullOr (types.strMatching "[^[:space:]]+");
        default = null;
        description = ''
          Optional username for the local SOCKS5/HTTP mixed inbound.

          Set this together with exactly one of auth.password or
          auth.passwordFile to require clients to authenticate before using the
          local proxy. Leave unset to keep the local proxy unauthenticated.
        '';
        example = "proxy-user";
      };

      password = mkOption {
        type = types.nullOr (types.strMatching "[^[:space:]]+");
        default = null;
        description = ''
          Optional inline password for the local SOCKS5/HTTP mixed inbound.
          Convenient for testing, but the password ends up in the Nix store.

          Prefer auth.passwordFile for real deployments.
        '';
        example = "change-me";
      };

      passwordFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Runtime path to a file containing the local proxy password.
          Intended for use with secret managers so the password stays out of
          the Nix store. The file is read when proxy-suite-socks starts.

          If perAppRouting.proxychains.enable is also used, keep this password
          as a single non-whitespace token so it can be written to the
          proxychains-ng config format. The generated proxychains config is
          readable by members of userControl.group.
        '';
        example = "/run/secrets/proxy-suite-local-proxy-password";
      };
    };

    proxyByDefault = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether traffic that does not match any explicit routing rule should
        go through the proxy or go direct.

        This affects sing-box route.final and dns.final in the generated
        config.
      '';
      example = true;
    };
  };
}
