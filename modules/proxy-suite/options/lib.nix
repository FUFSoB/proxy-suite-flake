# The option shapes this module declares over and over, in one place.
{ lib }:
let
  inherit (lib) mkOption types;

  octet = "(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])";
  ipv4 = "(${octet}\\.){3}${octet}";
  ipv4Prefix = "/(3[0-2]|[12]?[0-9])";
  # Loose on the groups (nft and ip reject a malformed one), strict on the characters.
  ipv6 = "[0-9A-Fa-f]{0,4}(:[0-9A-Fa-f]{0,4}){2,7}(:${ipv4})?";
  ipv6Prefix = "/(12[0-8]|1[01][0-9]|[1-9]?[0-9])";
  # A readable name in docs and errors in place of the pattern.
  matching =
    description: pattern:
    types.strMatching pattern
    // {
      inherit description;
    };
in
{
  # Interface names, addresses and CIDRs go into nft rules and scripts as they are: catch
  # typos early. An interface name is the kernel's (15 bytes at most), no leading "." or "-".
  interfaceType = matching "network interface name" "[A-Za-z0-9_][A-Za-z0-9_.+-]{0,14}";
  ipv4CidrType = matching "IPv4 CIDR" "${ipv4}${ipv4Prefix}";
  ipv6CidrType = matching "IPv6 CIDR" "${ipv6}${ipv6Prefix}";
  addressOrCidrType = matching "IPv4 or IPv6 address or CIDR" "(${ipv4}(${ipv4Prefix})?|${ipv6}(${ipv6Prefix})?)";
  # A listen address: an IP or a host name.
  hostType = matching "IP address or host name" "[A-Za-z0-9._:-]+";

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
