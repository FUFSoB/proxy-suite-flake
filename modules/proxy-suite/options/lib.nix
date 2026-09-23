# The option shapes this module declares over and over, in one place.
{ lib }:
let
  inherit (lib) mkOption types;
in
{
  list =
    description: example:
    mkOption {
      type = types.listOf types.str;
      default = [ ];
      inherit description example;
    };
  nullStr =
    description: example:
    mkOption {
      type = types.nullOr types.str;
      default = null;
      inherit description example;
    };
  # A WireGuard peer's host:port, IPv6 in brackets.
  endpoint =
    description:
    mkOption {
      type = types.nullOr (types.strMatching "(\\[[0-9A-Fa-f:.]+]|[^]:[]+):[0-9]+");
      default = null;
      example = "162.159.192.1:500";
      inherit description;
    };
  bool =
    default: description:
    mkOption {
      type = types.bool;
      inherit default description;
    };
  int =
    default: description:
    mkOption {
      type = types.int;
      inherit default description;
    };
  positiveInt =
    default: description:
    mkOption {
      type = types.ints.positive;
      inherit default description;
    };
  # An option path under services.proxy-suite, for the compatibility modules.
  path =
    path:
    [
      "services"
      "proxy-suite"
    ]
    ++ lib.splitString "." path;
}
