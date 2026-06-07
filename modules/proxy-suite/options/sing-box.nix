# Core proxy options. Feature-area options live in sing-box-{outbounds,dns,tun,tproxy,routing}.nix.
{ lib, pkgs, ... }:

let
  inherit (lib) literalExpression mkOption mkEnableOption types;
in
{
  options.services.proxy-suite.proxy = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to configure and run the proxy backend services.
        This is disabled by default; enable it explicitly and choose exactly
        one backend with proxy.singBox.enable or proxy.xray.enable.
      '';
    };

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = ''
        Address for the local SOCKS5/HTTP inbound to bind to.
        This affects the proxy-suite-socks service.

        Use "0.0.0.0" only if you intentionally want to expose the proxy to
        other machines on your network.
      '';
      example = "127.0.0.1";
    };

    port = mkOption {
      type = types.port;
      default = 1080;
      description = ''
        Listen port for the local SOCKS5/HTTP proxy inbound provided by
        proxy-suite-socks. SingBox exposes SOCKS5 and HTTP on this port.
        XRay's Socks inbound also accepts SOCKS and HTTP.
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

        This affects the generated backend route final and DNS final in the
        config.
      '';
      example = true;
    };

    singBox = {
      enable = mkEnableOption "SingBox proxy backend";

      package = mkOption {
        type = types.package;
        default = pkgs.sing-box;
        defaultText = literalExpression "pkgs.sing-box";
        example = literalExpression "pkgs.sing-box";
        description = ''
          sing-box package used by proxy-suite systemd services.

          Override this to pin or test a specific sing-box build when upstream
          protocol behavior changes.
        '';
      };

      clashApiPort = mkOption {
        type = types.port;
        default = 9090;
        description = ''
          Port for the Clash-compatible REST API exposed by sing-box.
          Only used when proxy.selection is "selector" or "urltest". Ignored
          in "first" mode because there is no selector-style outbound to
          control.
        '';
        example = 9090;
      };

      urlTest.tolerance = mkOption {
        type = types.int;
        default = 50;
        description = ''
          Latency tolerance in milliseconds for sing-box urltest. The current
          proxy is only replaced when a competing one is faster by more than
          this value.

          Only used when proxy.selection = "urltest" and the SingBox backend
          is active.
        '';
        example = 100;
      };
    };

    xray = {
      enable = mkEnableOption "XRay proxy backend";

      package = mkOption {
        type = types.package;
        default = pkgs.xray;
        defaultText = literalExpression "pkgs.xray";
        example = literalExpression "pkgs.xray";
        description = ''
          XRay package used by proxy-suite systemd services.

          Override this to pin or test a specific XRay build when upstream
          protocol behavior changes.
        '';
      };
    };
  };
}
