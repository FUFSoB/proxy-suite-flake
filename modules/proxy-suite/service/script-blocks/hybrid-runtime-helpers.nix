{ ctx }:

let
  inherit (ctx)
    lib
    jq
    hybridEnabled
    xraySidecarRoutingMark
    ;
in

routingMark: xraySidecarPort: xrayDnsBridgePort:

lib.optionalString hybridEnabled ''
  XRAY_OUTBOUNDS_JSON='[]'
  XRAY_CLIENTS_JSON='[]'
  XRAY_ROUTE_RULES_JSON='[]'
  XRAY_SIDECAR_PORT=${toString xraySidecarPort}
  XRAY_SIDECAR_DNS_PORT=${toString xrayDnsBridgePort}
  # Client ids: this run's random prefix plus a counter, so every sidecar outbound has its
  # own and no other local user can guess one.
  XRAY_SIDECAR_SECRET=$(cat /proc/sys/kernel/random/uuid)
  XRAY_SIDECAR_NEXT_ID=0

  _proxy_suite_add_sing_box_ob() {
    local ob="$1"
    OUTBOUNDS_JSON=$(${jq} --argjson ob "$ob" '. + [$ob]' <<< "$OUTBOUNDS_JSON")
  }

  # $1 a JSON array of XRay outbounds, each tagged. One jq pass for the lot: each gets a
  # client on the sidecar's one loopback VLESS inbound, routed to it by its email, and
  # stands in sing-box as a hop to it. VLESS rather than SOCKS: UDP rides the stream
  # (XUDP) with the client id, where SOCKS UDP datagrams carry no user to route by.
  _proxy_suite_add_xray_sidecar_obs() {
    local batch
    batch=$(${jq} -c \
      --argjson next "$XRAY_SIDECAR_NEXT_ID" \
      --arg secret "$XRAY_SIDECAR_SECRET" \
      --argjson port "$XRAY_SIDECAR_PORT" \
      --argjson mark ${
        if xraySidecarRoutingMark == null then "null" else toString xraySidecarRoutingMark
      } '
      def hex12: [range(11; -1; -1) as $i | (. / pow(16; $i) | floor) % 16 | "0123456789abcdef"[.:. + 1]] | add;
      to_entries | map(
        ($secret[:24] + ($next + .key | hex12)) as $id
        | .value.tag as $tag
        | {outbound: (.value
             ${lib.optionalString (
               xraySidecarRoutingMark != null
             ) "| .streamSettings.sockopt.mark = $mark"}
             | .streamSettings.sockopt.domainStrategy = (.streamSettings.sockopt.domainStrategy // "UseIP")),
           client: {id: $id, email: $tag},
           rule: {type: "field", inboundTag: ["sidecar-in"], user: [$tag], outboundTag: $tag},
           hop: ({type: "vless", tag: $tag, server: "127.0.0.1", server_port: $port, uuid: $id,
             packet_encoding: "xudp"}${
               lib.optionalString (routingMark != null) " + {routing_mark: ${toString routingMark}}"
             })})
      | {outbounds: map(.outbound), clients: map(.client), rules: map(.rule), hops: map(.hop)}
    ' <<< "$1")
    XRAY_SIDECAR_NEXT_ID=$((XRAY_SIDECAR_NEXT_ID + $(${jq} '.outbounds | length' <<< "$batch")))
    # Through a file, not --argjson: a big subscription's batch outgrows the kernel's
    # 128 KiB limit on one argument.
    XRAY_OUTBOUNDS_JSON=$(${jq} -c --slurpfile b <(printf '%s' "$batch") '. + $b[0].outbounds' <<< "$XRAY_OUTBOUNDS_JSON")
    XRAY_CLIENTS_JSON=$(${jq} -c --slurpfile b <(printf '%s' "$batch") '. + $b[0].clients' <<< "$XRAY_CLIENTS_JSON")
    XRAY_ROUTE_RULES_JSON=$(${jq} -c --slurpfile b <(printf '%s' "$batch") '. + $b[0].rules' <<< "$XRAY_ROUTE_RULES_JSON")
    OUTBOUNDS_JSON=$(${jq} -c --slurpfile b <(printf '%s' "$batch") '. + $b[0].hops' <<< "$OUTBOUNDS_JSON")
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
      --argjson port "$XRAY_SIDECAR_PORT" \
      --slurpfile clients <(printf '%s' "$XRAY_CLIENTS_JSON") \
      --slurpfile outbounds <(printf '%s' "$XRAY_OUTBOUNDS_JSON") \
      --slurpfile route_rules <(printf '%s' "$XRAY_ROUTE_RULES_JSON") \
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
        inbounds: [
          {
            tag: "sidecar-in",
            listen: "127.0.0.1",
            port: $port,
            protocol: "vless",
            settings: {clients: $clients[0], decryption: "none"}
          }
        ],
        outbounds: ($outbounds[0] + [{protocol:"freedom",tag:"direct"}]),
        routing: {
          domainStrategy: "AsIs",
          rules: ($route_rules[0] + [{type:"field",ip:["127.0.0.1"],port:$dns_port,outboundTag:"direct"}])
        }
      }' > "$RUNTIME_DIR/xray-sidecar.json"
  }
''
