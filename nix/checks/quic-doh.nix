# proxy.dns.browserDoh (Firefox's canary, DNS over HTTPS servers blocked on the TUN and TProxy)
# and proxy.routing.blockQuic (QUIC refused on its way to an outbound that carries UDP badly):
# what the configs hold, and (runtime) the backend filters over real configs, which the
# backends then accept.
{
  checkLib,
  pkgs,
}:

let
  inherit (checkLib)
    ok
    evalProxySuite
    baseModule
    mkTunConfig
    ;
  inherit (pkgs) lib;

  fixture =
    backend: settings:
    evalProxySuite [
      baseModule
      {
        services.proxy-suite.proxy = lib.recursiveUpdate {
          backend = lib.mkForce backend;
          tun.enable = true;
        } settings;
      }
    ];
  canary = "use-application-dns.net";
  singBoxCanary =
    cfg: lib.any (r: (r.domain or [ ]) == [ canary ] && r.rcode == "NXDOMAIN") cfg.dns.rules;
  xrayCanary =
    cfg:
    lib.any (
      ob:
      ob.tag == "dns-out"
      && lib.any (r: (r.domain or [ ]) == [ "full:${canary}" ] && r.rCode == 3) ob.settings.rules
    ) cfg.outbounds;

  singBoxDefault = mkTunConfig (fixture "sing-box" { });
  singBoxAllow = mkTunConfig (fixture "sing-box" { dns.browserDoh = "allow"; });
  singBoxBlock = mkTunConfig (fixture "sing-box" { dns.browserDoh = "block"; });
  xrayDefault = mkTunConfig (fixture "xray" { });
  xrayBlock = mkTunConfig (fixture "xray" { dns.browserDoh = "block"; });

  # The filters as the start scripts build them, with blockQuic.
  filter =
    pureXrayEnabled:
    pkgs.writeText "proxy-suite-quic-filter.jq" (
      import ../../modules/proxy-suite/service/script-blocks/backend-jq-filter.nix {
        inherit lib pureXrayEnabled;
        selectionMode = "urltest";
        proxyInboundsGuardPrivate = false;
        blockQuic = true;
      }
    );
  singBoxPackage = (fixture "sing-box" { }).config.services.proxy-suite.proxy.singBox.package;
  xrayPackage = (fixture "xray" { }).config.services.proxy-suite.proxy.xray.package;

  runtime =
    pkgs.runCommand "proxy-suite-quic-check"
      {
        nativeBuildInputs = [ pkgs.jq ];
      }
      ''
        set -eu
        export HOME=$PWD
        # sing-box: a VLESS exit, hysteria2 (UDP of its own), an AmneziaWG hop (by its source), a
        # group of only those two, zapret2's "QUIC through the proxy", a probe listener's pin.
        cat > sb.json <<'JSON'
        {"outbounds":[{"type":"direct","tag":"direct"},{"type":"block","tag":"block"}],
         "dns":{"rules":[]},"route":{"final":"proxy",
         "rule_set":[{"type":"inline","tag":"user:x","rules":[{"domain_suffix":["a.example"]}]}],
         "rules":[
          {"network":["tcp","udp"],"port":53,"action":"hijack-dns"},{"action":"sniff"},
          {"rule_set":["user:x"],"outbound":"vless-de"},
          {"domain_suffix":["yt.example"],"outbound":"direct"},
          {"domain_suffix":["t.example"],"outbound":"hy"},
          {"ip_cidr":["10.9.0.0/16"],"outbound":"awg-home"},
          {"network":["udp"],"port":[443],"domain_suffix":["z2.example"],"outbound":"proxy"},
          {"domain_suffix":["fast.example"],"outbound":"natgroup"},
          {"inbound":["mixed-in"],"domain_suffix":["probe.example"],"outbound":"vless-de"}]}}
        JSON
        OBS='[{"type":"selector","tag":"proxy","outbounds":["vless-de","hy"]},
          {"type":"socks","tag":"vless-de","server":"192.0.2.1","server_port":1080},
          {"type":"hysteria2","tag":"hy","server":"192.0.2.2","server_port":443,"password":"p","tls":{"enabled":true,"server_name":"h.example"}},
          {"type":"socks","tag":"awg-home","server":"127.0.0.1","server_port":20000},
          {"type":"urltest","tag":"natgroup","outbounds":["hy","awg-home"]}]'
        jq --slurpfile obs <(echo "$OBS") --slurpfile probe_inbounds <(echo '[]') --slurpfile probe_pin_rules <(echo '[]') \
          --slurpfile autoproxy_rule_sets <(echo '[]') --slurpfile autoproxy_rules <(echo '[]') \
          --argjson auth_enabled false --arg user "" --arg password "" --argjson route_enabled false \
          --slurpfile route_rules <(echo '[]') --arg route_final proxy --arg dns_final remote --argjson clear_dns_rules false \
          --slurpfile outbound_sources <(echo '{"awg-home":"awg"}') -f ${filter false} sb.json > out-sb.json
        jq -e '
          .route.rules as $r
          | ($r | map(.rule_set? == ["user:x"]) | index(true)) as $at
          | def twin($m): any($r[]; .type? == "logical" and .action == "reject" and .rules[0] == $m
                                    and .rules[1] == {network: ["udp"], port: [443]});
          twin({rule_set: ["user:x"]})
          and (twin({domain_suffix: ["yt.example"]}) | not)
          and (twin({domain_suffix: ["t.example"]}) | not)
          and (twin({ip_cidr: ["10.9.0.0/16"]}) | not)
          and (twin({domain_suffix: ["fast.example"]}) | not)
          and ([$r[] | select(.type? == "logical" and .action == "reject")] | length) == 1
          # The twin just before its rule; the final "proxy" carries UDP badly: a catch-all last.
          and $r[$at - 1].type == "logical" and $r[-1] == {network: ["udp"], port: [443], action: "reject"}
        ' out-sb.json > /dev/null
        ${singBoxPackage}/bin/sing-box check -c out-sb.json

        # XRay: a balancer, a WireGuard exit, a direct rule; the final through the balancer.
        cat > xr.json <<'JSON'
        {"outbounds":[{"protocol":"freedom","tag":"direct"},{"protocol":"blackhole","tag":"block"},
          {"protocol":"socks","tag":"proxy-suite-ob-de","settings":{"servers":[{"address":"192.0.2.1","port":1080}]}},
          {"protocol":"wireguard","tag":"proxy-suite-ob-wg","settings":{"secretKey":"aGVsbG8gd29ybGQgaGVsbG8gd29ybGQgaGVsbG8gd28=",
            "peers":[{"publicKey":"aGVsbG8gd29ybGQgaGVsbG8gd29ybGQgaGVsbG8gd28=","endpoint":"192.0.2.3:51820"}]}}],
         "routing":{"balancers":[{"tag":"proxy","selector":["proxy-suite-ob-"]}],"rules":[
          {"type":"field","ruleTag":"user:x","domain":["domain:a.example"],"outboundTag":"proxy-suite-ob-de"},
          {"type":"field","ruleTag":"custom-proxy-ip","ip":["8.8.8.0/24"],"outboundTag":"proxy-suite-ob-wg"},
          {"type":"field","ruleTag":"direct-domain","domain":["domain:ru"],"outboundTag":"direct"},
          {"type":"field","ruleTag":"proxy-domain","domain":["domain:p.example"],"balancerTag":"proxy"},
          {"type":"field","ruleTag":"final-default","network":"tcp,udp","balancerTag":"proxy"}]}}
        JSON
        jq --slurpfile obs <(echo '[]') --argjson auth_enabled false --arg user "" --arg password "" \
          --argjson route_enabled false --slurpfile route_rules <(echo '[]') --arg route_final proxy --arg dns_final "" \
          --arg xray_loglevel "" --arg xray_single_proxy_tag "" --argjson xray_tun_dns_runtime false \
          --argjson host_addresses '[]' --slurpfile outbound_sources <(echo '{}') -f ${filter true} xr.json > out-xr.json
        jq -e '
          [.routing.rules[] | [.ruleTag, (.outboundTag // .balancerTag), .network, .port]]
          == [["user:x:quic", "block", "udp", "443"], ["user:x", "proxy-suite-ob-de", null, null],
              ["custom-proxy-ip", "proxy-suite-ob-wg", null, null], ["direct-domain", "direct", null, null],
              ["proxy-domain:quic", "block", "udp", "443"], ["proxy-domain", "proxy", null, null],
              ["final-quic", "block", "udp", "443"], ["final-default", "proxy", "tcp,udp", null]]
        ' out-xr.json > /dev/null
        ${xrayPackage}/bin/xray run -test -c out-xr.json
        touch "$out"
      '';
in
{
  inherit runtime;
  assertions = [
    # Firefox's canary has no address by default, on either backend; "allow" leaves it be.
    (ok (singBoxCanary singBoxDefault && !singBoxCanary singBoxAllow))
    (ok (xrayCanary xrayDefault))
    # "block": what the TUN and TProxy send to a DNS over HTTPS server, and its list declared.
    (ok (
      lib.any (
        r:
        (r.rule_set or [ ]) == [ "geosite-category-doh" ]
        && r.outbound == "block"
        && lib.elem "tun-in" r.inbound
      ) singBoxBlock.route.rules
      && lib.any (rs: rs.tag == "geosite-category-doh") singBoxBlock.route.rule_set
      && !(lib.any (rs: rs.tag == "geosite-category-doh") singBoxDefault.route.rule_set)
    ))
    (ok (
      lib.any (
        r:
        (r.ruleTag or "") == "block-doh"
        && r.domain == [ "geosite:category-doh" ]
        && lib.elem "tun-in" r.inboundTag
        && r.outboundTag == "block"
      ) xrayBlock.routing.rules
    ))
  ];
}
