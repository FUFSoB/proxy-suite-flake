{ lib, ... }:

let
  inherit (lib) mkOption types;
in
{
  # Heavy helpers proxy-ctl can do without; nix-on-droid leaves them out by default.
  options.services.proxy-suite.tools = {
    lnav.enable = mkOption {
      type = types.bool;
      default = true;
      defaultText = lib.literalMD "`true`, `false` on nix-on-droid";
      description = ''
        Follow `proxy-ctl logs` in lnav. Without it they follow in less.
      '';
    };

    curlImpersonate.enable = mkOption {
      type = types.bool;
      default = true;
      defaultText = lib.literalMD "`true`, `false` on nix-on-droid";
      description = ''
        Probe with curl-impersonate (`proxy-ctl proxy auto probe`, and autoProxy), which
        presents a browser's TLS fingerprint. Without it probes use plain curl, which some
        bot protection refuses, so a working exit can be judged blocked.
      '';
    };
  };
}
