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
