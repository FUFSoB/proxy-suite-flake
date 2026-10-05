# The generated configs through the backends' own checks: `xray run -test` and `sing-box
# check`. Nothing else catches a value a backend refuses (its whole start fails over one
# rule), only the string assertions that pin what we meant to write.
{
  pkgs,
  checkLib,
}:

let
  inherit (checkLib) evalProxySuite mkAssembly baseModule;
  inherit (pkgs) lib;

  proxy =
    backend:
    evalProxySuite [
      baseModule
      {
        services.proxy-suite = {
          killSwitch.enable = true;
          proxy = {
            backend = lib.mkForce backend;
            selection = "urltest";
            tproxy.enable = true;
            tun.enable = true;
            dns.fakeIp.enable = true;
          };
          perAppRouting = {
            enable = true;
            tun.enable = true;
            tproxy.enable = true;
          };
        };
      }
    ];
  # Its routing.default "direct" leaves out the proxied DNS bridge, and urltest's balancer.
  direct =
    backend:
    evalProxySuite [
      baseModule
      {
        services.proxy-suite.proxy = {
          backend = lib.mkForce backend;
          routing.default = "direct";
          tproxy.enable = true;
        };
      }
    ];
  inbounds = evalProxySuite [
    baseModule
    {
      services.proxy-suite.inbounds = {
        enable = true;
        serverAddress = "vpn.example.com";
        users.user.uuidFile = "/run/secrets/uuid";
        listeners.vless-in = {
          type = "vless";
          port = 443;
          users = [ "user" ];
          reality = {
            enable = true;
            serverNames = [ "www.microsoft.com" ];
            privateKeyFile = "/run/secrets/reality-key";
            publicKey = "public-key";
            shortIds = [ "0123abcd" ];
          };
        };
      };
    }
  ];

  configsOf =
    fixture: attrs:
    let
      configs = (mkAssembly fixture).configs;
    in
    map (attr: configs.${attr}) (builtins.filter (attr: configs ? ${attr}) attrs);
  proxyAttrs = [
    "tproxyFile"
    "tunFile"
    "perAppTunFile"
  ];

  xrayConfigs =
    configsOf (proxy "xray") proxyAttrs
    ++ configsOf (direct "xray") proxyAttrs
    ++ configsOf inbounds [ "proxyInboundsFile" ];
  singBoxConfigs =
    configsOf (proxy "sing-box") proxyAttrs ++ configsOf (direct "sing-box") proxyAttrs;

  xray = "${(proxy "xray").config.services.proxy-suite.proxy.xray.package}/bin/xray";
  singBox = "${(proxy "sing-box").config.services.proxy-suite.proxy.singBox.package}/bin/sing-box";
in
pkgs.runCommand "proxy-suite-backend-config-validation-check" { nativeBuildInputs = [ pkgs.jq ]; }
  ''
    export HOME=$PWD
    # The outbounds come at start: one of each kind the rules and balancers name stands in.
    for config in ${lib.escapeShellArgs xrayConfigs}; do
      jq '.outbounds += [{tag: "proxy-suite-ob-check", protocol: "freedom"}]
        | if any(.outbounds[]; .tag == "proxy") or (.routing.balancers // [] | any(.tag == "proxy")) then .
          else .outbounds += [{tag: "proxy", protocol: "freedom"}] end' "$config" > config.json
      if ! ${xray} run -test -format json -c config.json > log 2>&1; then
        echo "xray refuses $config:" >&2
        cat log >&2
        exit 1
      fi
    done
    for config in ${lib.escapeShellArgs singBoxConfigs}; do
      if ! ${singBox} check -c "$config" > log 2>&1; then
        echo "sing-box refuses $config:" >&2
        cat log >&2
        exit 1
      fi
    done
    touch "$out"
  ''
