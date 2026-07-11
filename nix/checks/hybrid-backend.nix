{
  pkgs,
  evalProxySuite,
  mkTProxyConfig,
  mkTunConfig,
  shellValueByPrefix,
  checkConstants,
}:

let
  fixtures = import ./hybrid-backend/fixtures.nix {
    inherit
      evalProxySuite
      mkTProxyConfig
      mkTunConfig
      shellValueByPrefix
      ;
  };

  inherit (fixtures)
    hybridBackendJqFilter
    hybridFixture
    hybridPerAppTunStartScript
    hybridStartScript
    hybridSubscriptionStartScript
    hybridSubscriptionUpdateScript
    hybridTproxyConfig
    hybridTunConfig
    hybridTunStartScript
    hybridXrayRawStartScript
    ;
in
{
  assertions = [
    # -- hybrid backend: sing-box frontend with XRay loopback sidecar --
    (
      let
        dnsBridgeInbound = builtins.head (
          builtins.filter (inbound: inbound.tag == "xray-dns-in") hybridTproxyConfig.inbounds
        );
        mixedInbound = builtins.head (
          builtins.filter (inbound: inbound.tag == "mixed-in") hybridTproxyConfig.inbounds
        );
        tproxyInbound = builtins.head (
          builtins.filter (inbound: inbound.tag == "tproxy-in") hybridTproxyConfig.inbounds
        );
        tunDnsBridgeInbound = builtins.head (
          builtins.filter (inbound: inbound.tag == "xray-dns-in") hybridTunConfig.inbounds
        );
        dnsBridgeRouteRule = builtins.head (
          builtins.filter (
            rule:
            (rule.action or "") == "hijack-dns" && (rule ? inbound) && builtins.elem "xray-dns-in" rule.inbound
          ) hybridTproxyConfig.route.rules
        );
      in
      assert hybridFixture.config.services.proxy-suite.proxy.singBox.enable;
      assert hybridFixture.config.services.proxy-suite.proxy.xray.enable;
      assert hybridTproxyConfig ? route;
      assert !(hybridTproxyConfig ? routing);
      assert dnsBridgeInbound.type == "direct";
      assert dnsBridgeInbound.listen == "127.0.0.1";
      assert dnsBridgeInbound.listen_port == checkConstants.xrayDnsBridgePorts.socks;
      assert mixedInbound.type == "mixed";
      assert tproxyInbound.type == "tproxy";
      assert tunDnsBridgeInbound.listen_port == checkConstants.xrayDnsBridgePorts.tun;
      assert
        dnsBridgeRouteRule.network == [
          "tcp"
          "udp"
        ];
      assert pkgs.lib.hasInfix "/bin/sing-box run -c" hybridStartScript;
      assert pkgs.lib.hasInfix "/bin/xray run -c" hybridStartScript;
      assert pkgs.lib.hasInfix "xray-sidecar.json" hybridStartScript;
      assert pkgs.lib.hasInfix
        "XRAY_SIDECAR_NEXT_PORT=${toString checkConstants.xraySidecarBasePorts.socks}"
        hybridStartScript;
      assert pkgs.lib.hasInfix "XRAY_SIDECAR_DNS_PORT=${toString checkConstants.xrayDnsBridgePorts.socks}"
        hybridStartScript;
      assert pkgs.lib.hasInfix
        "XRAY_SIDECAR_NEXT_PORT=${toString checkConstants.xraySidecarBasePorts.tun}"
        hybridTunStartScript;
      assert pkgs.lib.hasInfix "XRAY_SIDECAR_DNS_PORT=${toString checkConstants.xrayDnsBridgePorts.tun}"
        hybridTunStartScript;
      assert pkgs.lib.hasInfix
        "XRAY_SIDECAR_NEXT_PORT=${toString checkConstants.xraySidecarBasePorts.perAppTun}"
        hybridPerAppTunStartScript;
      assert pkgs.lib.hasInfix
        "XRAY_SIDECAR_DNS_PORT=${toString checkConstants.xrayDnsBridgePorts.perAppTun}"
        hybridPerAppTunStartScript;
      assert pkgs.lib.hasInfix "--backend sing-box" hybridStartScript;
      assert pkgs.lib.hasInfix "--backend xray" hybridStartScript;
      assert pkgs.lib.hasInfix "_proxy_suite_add_xray_sidecar_ob" hybridStartScript;
      assert pkgs.lib.hasInfix "hybrid XRay json sidecar" hybridXrayRawStartScript;
      assert pkgs.lib.hasInfix ''{type:"socks",tag:$tag,server:"127.0.0.1"'' hybridXrayRawStartScript;
      assert pkgs.lib.hasInfix "udp:true" hybridXrayRawStartScript;
      assert pkgs.lib.hasInfix "routing_mark:2" hybridXrayRawStartScript;
      assert pkgs.lib.hasInfix "sing_box_preserved_rules" hybridBackendJqFilter;
      assert pkgs.lib.hasInfix "xray-dns-in" hybridBackendJqFilter;
      assert pkgs.lib.hasInfix "--backend hybrid" hybridSubscriptionStartScript;
      assert pkgs.lib.hasInfix "--backend hybrid" hybridSubscriptionUpdateScript;
      assert pkgs.lib.hasInfix
        ''type == "object" and (.singBox | type == "array") and (.xray | type == "array")''
        hybridSubscriptionStartScript;
      assert pkgs.lib.hasInfix ".singBox" hybridSubscriptionStartScript;
      assert pkgs.lib.hasInfix ".xray[]" hybridSubscriptionStartScript;
      assert pkgs.lib.hasInfix "_proxy_suite_add_xray_sidecar_ob" hybridSubscriptionStartScript;
      true
    )
  ];
}
