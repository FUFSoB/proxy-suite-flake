{
  config,
  lib,
  pkgs,
  proxySuiteUpstream,
  ...
}:

let
  inherit (lib)
    literalExpression
    literalMD
    mkOption
    types
    ;
  cfg = config.services.proxy-suite.geodata;
in
{
  # Shared by the client backends and the inbound service, so not under proxy.
  options.services.proxy-suite.geodata = {
    xray.assets = mkOption {
      type = types.nullOr types.package;
      default = pkgs.v2ray-rules-dat;
      defaultText = literalExpression "pkgs.v2ray-rules-dat";
      description = ''
        Package with share/v2ray/{geoip,geosite}.dat for XRay. `null`: XRay's built-in data,
        which only has countries, so a tag like "geoip:telegram" breaks XRay. Its geoip.dat also
        fills in the tags `singBox.geoip` lacks.
      '';
    };

    singBox = {
      geoip = mkOption {
        type = types.package;
        default = import ../../../pkgs/sing-geoip-extended.nix {
          inherit pkgs;
          geoipDat = "${
            if cfg.xray.assets != null then cfg.xray.assets else pkgs.v2ray-rules-dat
          }/share/v2ray/geoip.dat";
          singBox = proxySuiteUpstream.sing-box;
        };
        defaultText = literalMD ''
          `pkgs.sing-geoip` (countries), plus each tag of `xray.assets`' geoip.dat it lacks:
          telegram, google, cloudflare, private and the like (`pkgs/sing-geoip-extended.nix`)
        '';
        description = ''
          Package with share/sing-box/rule-set/geoip-NAME.srs. By default the same tags as XRay's
          geoip.dat, so "geoip:telegram" works on either backend.
        '';
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
