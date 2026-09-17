# The subset of NixOS's systemd unit options proxy-suite declares units with, merged
# the same way, so hosts without NixOS's systemd module can read them back.
{ lib }:

let
  inherit (lib) mkOption types;

  # As nixos/lib/systemd-lib.nix: lists concatenate, anything else must agree.
  unitOption = lib.mkOptionType {
    name = "systemd option";
    merge =
      loc: defs:
      let
        defs' = lib.filterOverrides defs;
      in
      if lib.any (def: lib.isList def.value) defs' then
        lib.concatMap (def: lib.toList def.value) defs'
      else
        lib.mergeEqualOption loc defs';
  };

  list = mkOption {
    type = types.listOf types.str;
    default = [ ];
  };
  lines = mkOption {
    type = types.lines;
    default = "";
  };
  section = mkOption {
    type = types.attrsOf unitOption;
    default = { };
  };
in
types.submodule {
  options = {
    enable = mkOption {
      type = types.bool;
      default = true;
    };
    description = mkOption {
      type = types.str;
      default = "";
    };
    after = list;
    before = list;
    wants = list;
    requires = list;
    bindsTo = list;
    partOf = list;
    conflicts = list;
    wantedBy = list;
    requiredBy = list;
    path = mkOption {
      type = types.listOf (types.either types.package types.str);
      default = [ ];
    };
    environment = mkOption {
      type = types.attrsOf (
        types.nullOr (
          types.oneOf [
            types.str
            types.path
            types.package
          ]
        )
      );
      default = { };
    };
    script = lines;
    preStart = lines;
    postStart = lines;
    preStop = lines;
    postStop = lines;
    startLimitIntervalSec = mkOption {
      type = types.nullOr types.int;
      default = null;
    };
    unitConfig = section;
    serviceConfig = section;
    timerConfig = section;
    pathConfig = section;
  };
}
