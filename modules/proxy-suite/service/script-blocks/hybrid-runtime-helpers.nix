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

  _proxy_suite_next_xray_sidecar_port() {
    local port="$XRAY_SIDECAR_NEXT_PORT"
    XRAY_SIDECAR_NEXT_PORT=$((XRAY_SIDECAR_NEXT_PORT + 1))
    printf '%s\n' "$port"
  }

  _proxy_suite_add_xray_sidecar_ob() {
    local ob="$1" tag="$2" port auth inbound_tag sing_ob inbound route_rule
    port="$(_proxy_suite_next_xray_sidecar_port)"
    auth="proxy-suite-xray-$port"
    inbound_tag="$tag-inbound"
    ob=$(${jq} \
      --arg tag "$tag" \
      --argjson mark ${toString xraySidecarRoutingMark} \
      '.tag = $tag
       | .streamSettings = (.streamSettings // {})
       | .streamSettings.sockopt = (.streamSettings.sockopt // {})
       | .streamSettings.sockopt.mark = $mark
       | .streamSettings.sockopt.domainStrategy = (.streamSettings.sockopt.domainStrategy // "UseIP")' \
      <<< "$ob")
    XRAY_OUTBOUNDS_JSON=$(${jq} --argjson ob "$ob" '. + [$ob]' <<< "$XRAY_OUTBOUNDS_JSON")
    inbound=$(${jq} -n \
      --arg tag "$inbound_tag" \
      --arg auth "$auth" \
      --argjson port "$port" \
      '{tag:$tag,listen:"127.0.0.1",port:$port,protocol:"socks",settings:{auth:"password",udp:true,accounts:[{user:$auth,pass:$auth}]}}')
    XRAY_INBOUNDS_JSON=$(${jq} --argjson inbound "$inbound" '. + [$inbound]' <<< "$XRAY_INBOUNDS_JSON")
    route_rule=$(${jq} -n \
      --arg inbound "$inbound_tag" \
      --arg outbound "$tag" \
      '{type:"field",inboundTag:[$inbound],outboundTag:$outbound}')
    XRAY_ROUTE_RULES_JSON=$(${jq} --argjson rule "$route_rule" '. + [$rule]' <<< "$XRAY_ROUTE_RULES_JSON")
    sing_ob=$(${jq} -n \
      --arg tag "$tag" \
      --arg auth "$auth" \
      --argjson port "$port" \
      '{type:"socks",tag:$tag,server:"127.0.0.1",server_port:$port,version:"5",username:$auth,password:$auth${
        lib.optionalString (routingMark != null) ",routing_mark:${toString routingMark}"
      }}')
    OUTBOUNDS_JSON=$(${jq} --argjson ob "$sing_ob" '. + [$ob]' <<< "$OUTBOUNDS_JSON")
  }

  _proxy_suite_write_xray_sidecar_config() {
    if [ "$(${jq} 'length' <<< "$XRAY_OUTBOUNDS_JSON")" -eq 0 ]; then
      return 0
    fi
    ${jq} -n \
      --arg loglevel "$XRAY_LOGLEVEL" \
      --arg bind_interface "$XRAY_TUN_BIND_INTERFACE" \
      --argjson dns_port "$XRAY_SIDECAR_DNS_PORT" \
      --argjson inbounds "$XRAY_INBOUNDS_JSON" \
      --argjson outbounds "$XRAY_OUTBOUNDS_JSON" \
      --argjson route_rules "$XRAY_ROUTE_RULES_JSON" \
      '
      def bind_xray_sidecar($interface):
        if $interface == "" then
          .
        else
          .streamSettings = (.streamSettings // {})
          | .streamSettings.sockopt = (.streamSettings.sockopt // {})
          | if (.streamSettings.sockopt.interface? // "") == "" then
              .streamSettings.sockopt.interface = $interface
            else
              .
            end
        end;
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
        outbounds: (($outbounds | map(bind_xray_sidecar($bind_interface))) + [{protocol:"freedom",tag:"direct"}]),
        routing: {
          domainStrategy: "AsIs",
          rules: ($route_rules + [{type:"field",ip:["127.0.0.1"],port:$dns_port,outboundTag:"direct"}])
        }
      }' > "$RUNTIME_DIR/xray-sidecar.json"
  }
''
