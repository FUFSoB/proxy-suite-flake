{ ctx }:

let
  fillTemplate = import ../../lib/fill-template.nix;
  inherit (ctx)
    lib
    jq
    hybridEnabled
    xraySidecarRoutingMark
    ;
in

routingMark: xraySidecarPort: xrayDnsBridgePort:

lib.optionalString hybridEnabled (
  fillTemplate ./hybrid-runtime-helpers.template.sh {
    sidecarPort = toString xraySidecarPort;
    dnsBridgePort = toString xrayDnsBridgePort;
    inherit jq;
    sidecarMark = if xraySidecarRoutingMark == null then "null" else toString xraySidecarRoutingMark;
    setSidecarMark = lib.optionalString (
      xraySidecarRoutingMark != null
    ) "| .streamSettings.sockopt.mark = $mark";
    hopRoutingMark = lib.optionalString (
      routingMark != null
    ) " + {routing_mark: ${toString routingMark}}";
  }
)
