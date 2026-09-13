{ lib, pkgs, ... }:

let
  inherit (lib) literalExpression mkOption types;
in
{
  # Shared by the client backends and the inbound service, so not under proxy.
  options.services.proxy-suite.geodata = {
    xray.assets = mkOption {
      type = types.nullOr types.package;
      default = pkgs.v2ray-rules-dat;
      defaultText = literalExpression "pkgs.v2ray-rules-dat";
      description = ''
        Package with share/v2ray/{geoip,geosite}.dat for every XRay process. Null uses XRay's own
        country-only data, where a tag like "geoip:telegram" stops XRay from starting.
      '';
    };

    singBox = {
      geoip = mkOption {
        type = types.package;
        default = pkgs.sing-geoip;
        defaultText = literalExpression "pkgs.sing-geoip";
        description = "Package with share/sing-box/rule-set/geoip-NAME.srs (country codes by default).";
      };

      geosite = mkOption {
        type = types.package;
        default = pkgs.sing-geosite;
        defaultText = literalExpression "pkgs.sing-geosite";
        description = "Package with share/sing-box/rule-set/geosite-NAME.srs.";
      };
    };
  };
}
