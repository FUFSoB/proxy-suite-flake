{
  lib,
  jq,
  hybridEnabled,
  xraySidecarRoutingMark,
}:

routingMark: xraySidecarBasePort: xrayDnsBridgePort:

lib.optionalString hybridEnabled ''
  XRAY_OUTBOUNDS_JSON='[]'
  XRAY_INBOUNDS_JSON='[]'
  XRAY_ROUTE_RULES_JSON='[]'
  XRAY_SIDECAR_NEXT_PORT=${toString xraySidecarBasePort}
  XRAY_SIDECAR_DNS_PORT=${toString xrayDnsBridgePort}

  _proxy_suite_add_sing_box_ob() {
    local ob="$1"
    OUTBOUNDS_JSON=$(${jq} --argjson ob "$ob" '. + [$ob]' <<< "$OUTBOUNDS_JSON")
  }

  # $1 a JSON array of XRay outbounds, each tagged. One jq pass for the lot: each gets a
  # loopback SOCKS inbound on the sidecar and stands in sing-box as a hop to it.
  _proxy_suite_add_xray_sidecar_obs() {
    local batch
    batch=$(${jq} -c \
      --argjson base "$XRAY_SIDECAR_NEXT_PORT" \
      --argjson mark ${
        if xraySidecarRoutingMark == null then "null" else toString xraySidecarRoutingMark
      } '
      to_entries | map(
        ($base + .key) as $port
        | ("proxy-suite-xray-" + ($port | tostring)) as $auth
        | .value.tag as $tag
        | {outbound: (.value
             ${lib.optionalString (
               xraySidecarRoutingMark != null
             ) "| .streamSettings.sockopt.mark = $mark"}
             | .streamSettings.sockopt.domainStrategy = (.streamSettings.sockopt.domainStrategy // "UseIP")),
           inbound: {tag: ($tag + "-inbound"), listen: "127.0.0.1", port: $port, protocol: "socks",
             settings: {auth: "password", udp: true, accounts: [{user: $auth, pass: $auth}]}},
           rule: {type: "field", inboundTag: [$tag + "-inbound"], outboundTag: $tag},
           hop: ({type: "socks", tag: $tag, server: "127.0.0.1", server_port: $port, version: "5",
             username: $auth, password: $auth}${
               lib.optionalString (routingMark != null) " + {routing_mark: ${toString routingMark}}"
             })})
      | {outbounds: map(.outbound), inbounds: map(.inbound), rules: map(.rule), hops: map(.hop)}
    ' <<< "$1")
    XRAY_SIDECAR_NEXT_PORT=$((XRAY_SIDECAR_NEXT_PORT + $(${jq} '.outbounds | length' <<< "$batch")))
    XRAY_OUTBOUNDS_JSON=$(${jq} -c --argjson b "$batch" '. + $b.outbounds' <<< "$XRAY_OUTBOUNDS_JSON")
    XRAY_INBOUNDS_JSON=$(${jq} -c --argjson b "$batch" '. + $b.inbounds' <<< "$XRAY_INBOUNDS_JSON")
    XRAY_ROUTE_RULES_JSON=$(${jq} -c --argjson b "$batch" '. + $b.rules' <<< "$XRAY_ROUTE_RULES_JSON")
    OUTBOUNDS_JSON=$(${jq} -c --argjson b "$batch" '. + $b.hops' <<< "$OUTBOUNDS_JSON")
  }

  # $1 one XRay outbound, $2 its tag.
  _proxy_suite_add_xray_sidecar_ob() {
    _proxy_suite_add_xray_sidecar_obs "$(${jq} -c --arg tag "$2" '[.tag = $tag]' <<< "$1")"
  }

  _proxy_suite_write_xray_sidecar_config() {
    if [ "$(${jq} 'length' <<< "$XRAY_OUTBOUNDS_JSON")" -eq 0 ]; then
      return 0
    fi
    ${jq} -n \
      --arg loglevel "$XRAY_LOGLEVEL" \
      --argjson dns_port "$XRAY_SIDECAR_DNS_PORT" \
      --argjson inbounds "$XRAY_INBOUNDS_JSON" \
      --argjson outbounds "$XRAY_OUTBOUNDS_JSON" \
      --argjson route_rules "$XRAY_ROUTE_RULES_JSON" \
      '
      {
        log: {
          loglevel: (if $loglevel == "" then "warning" else $loglevel end),
          access: "none"
        },
        dns: {
          servers: [
            {
              address: "127.0.0.1",
              port: $dns_port,
              queryStrategy: "UseIP",
              skipFallBack: true
            }
          ]
        },
        inbounds: $inbounds,
        outbounds: ($outbounds + [{protocol:"freedom",tag:"direct"}]),
        routing: {
          domainStrategy: "AsIs",
          rules: ($route_rules + [{type:"field",ip:["127.0.0.1"],port:$dns_port,outboundTag:"direct"}])
        }
      }' > "$RUNTIME_DIR/xray-sidecar.json"
  }
''
