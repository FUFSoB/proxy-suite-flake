# Routing rules added at runtime (`proxy-ctl proxy rules`): rendered from the routing scope's
# spool, then composed into each backend's route by the start scripts.
#
# routing.d/rules.json is the groups'; root renders it into routingRulesDir: rules.json
# checked (routing-render.jq), per rule rs/<name>.json (its domains and addresses) and
# dns/<name>.json (its domains alone) as sing-box source rule sets, and `structure`, what of
# them changes the config itself. A change to a rule's domains or addresses alone reaches a
# running sing-box through its rule set files, which it reloads; anything else, and any change
# on XRay, which has no rule sets, restarts the backends.
{ ctx }:

let
  inherit (ctx)
    lib
    pkgs
    cfg
    jq
    constants
    pureXrayEnabled
    ;
  inherit (constants) runtimeRoutingDir routingRulesDir;
  coreutils = "${pkgs.coreutils}/bin";

  renderJq = ./routing-render.jq;
  convertJq = ./routing-convert.jq;
  composeJq = ./routing-compose.jq;

  # Where sing-box finds geodata the configuration does not name; also how a geosite or geoip
  # gets checked before XRay is handed one (the two come from the same lists).
  geositeDir = "${cfg.geodata.singBox.geosite}/share/sing-box/rule-set";
  geoipDir = "${cfg.geodata.singBox.geoip}/share/sing-box/rule-set";

  # Root, over a spool the groups write: read through no symlink, 4 MiB at most, and checked
  # field by field. Under a lock: every backend's start script renders too. --sweep also
  # removes the rule sets of rules that are gone, which apply does once the backends that
  # watched them have restarted. The spool and output directories as arguments: for the checks.
  render = pkgs.writeShellScript "proxy-suite-core" ''
    set -euo pipefail
    SWEEP=false
    if [ "''${1:-}" = --sweep ]; then
      SWEEP=true
      shift
    fi
    SPOOL=''${1:-${lib.escapeShellArg runtimeRoutingDir}}
    OUT=''${2:-${lib.escapeShellArg routingRulesDir}}
    umask 022
    ${coreutils}/mkdir -p "$OUT/rs" "$OUT/dns"
    ${coreutils}/chmod 0755 "$OUT" "$OUT/rs" "$OUT/dns"
    exec 9> "$OUT/.lock"
    ${pkgs.util-linux}/bin/flock 9

    SRC='{}'
    if [ -f "$SPOOL/rules.json" ] && [ ! -L "$SPOOL/rules.json" ]; then
      SRC=$(${coreutils}/dd if="$SPOOL/rules.json" iflag=nofollow,nonblock,fullblock bs=4M count=1 status=none 2>/dev/null) || SRC='{}'
    fi
    # Slurped: an empty file, or several documents, is no rules rather than no output.
    if ! RULES=$(${jq} -c -s -f ${renderJq} <<< "$SRC" 2>/dev/null); then
      echo "proxy-suite: $SPOOL/rules.json is not valid JSON; no runtime routing rules apply" >&2
      RULES='[]'
    fi

    # Renamed in, and only when it changed: sing-box reloads a rule set on every new file.
    _put() {
      cat > "$1.tmp"
      ${coreutils}/chmod 644 "$1.tmp"
      if ${pkgs.diffutils}/bin/cmp -s "$1.tmp" "$1"; then
        rm -f "$1.tmp"
      else
        mv -f "$1.tmp" "$1"
      fi
    }
    printf '%s\n' "$RULES" | _put "$OUT/rules.json"
    KEEP=" "
    while IFS=$'\t' read -r NAME SET DNS; do
      printf '%s\n' "$SET" | _put "$OUT/rs/$NAME.json"
      printf '%s\n' "$DNS" | _put "$OUT/dns/$NAME.json"
      KEEP="$KEEP$NAME.json "
    done < <(${jq} -r '.[]
      | [.name,
         ({version: 1, rules: ([if .domains != [] then {domain_suffix: .domains} else empty end]
                               + [if .ips != [] then {ip_cidr: .ips} else empty end])} | tojson),
         ({version: 1, rules: [if .domains != [] then {domain_suffix: .domains} else empty end]} | tojson)]
      | @tsv' <<< "$RULES")
    if [ "$SWEEP" = true ]; then
      for F in "$OUT"/rs/*.json "$OUT"/dns/*.json; do
        [ -e "$F" ] || continue
        case "$KEEP" in
          *" ''${F##*/} "*) ;;
          *) rm -f "$F" ;;
        esac
      done
    fi
    ${jq} -c '${
      if pureXrayEnabled then
        "map(select(.disabled | not))"
      else
        "map(select(.disabled | not) | del(.domains, .ips))"
    }' <<< "$RULES" | _put "$OUT/structure"
  '';

  # The backends whose config holds the rules, with their runtime directories.
  consumers = [
    {
      unit = "proxy-suite-socks";
      dir = "${constants.runtimeDir}/proxy-suite-socks";
    }
    {
      unit = "proxy-suite-tun";
      dir = "${constants.runtimeDir}/proxy-suite-tun";
    }
    {
      unit = "proxy-suite-per-app-tun";
      dir = "${constants.runtimeDir}/proxy-suite-per-app-tun";
    }
  ];

  # proxy-suite-routing-apply, after every `proxy rules` change: a backend restarts only when
  # its config would change, the structure it started from (startBlock) no longer the one now.
  apply = pkgs.writeShellScript "proxy-suite-core" ''
    set -euo pipefail
    ${render}
    ${lib.concatMapStrings (c: ''
      if ${constants.systemctl} is-active --quiet ${c.unit} \
        && ! ${pkgs.diffutils}/bin/cmp -s ${lib.escapeShellArg "${routingRulesDir}/structure"} ${lib.escapeShellArg "${c.dir}/routing-structure"}; then
        ${constants.systemctl} restart ${c.unit}
      fi
    '') consumers}
    ${render} --sweep
  '';

  # In a start script, after the outbounds: sets RUNTIME_SECTIONS_JSON (routing-compose.jq's
  # $runtime) and USER_RULE_SETS_JSON, and writes $RUNTIME_DIR/routing-structure and
  # routing-skipped.json, the rules left out and why (for proxy-ctl, which anyone may read).
  startBlock = configFile: ''
    RUNTIME_SECTIONS_JSON='[]'
    USER_RULE_SETS_JSON='[]'
    RUNTIME_ROUTING_SKIPPED='[]'
    ${render}
    cp ${lib.escapeShellArg "${routingRulesDir}/structure"} "$RUNTIME_DIR/routing-structure"
    chmod 644 "$RUNTIME_DIR/routing-structure"
    RUNTIME_ROUTING_JSON=$(cat ${lib.escapeShellArg "${routingRulesDir}/rules.json"})
    if ${jq} -e 'any(.[]; .disabled | not)' <<< "$RUNTIME_ROUTING_JSON" >/dev/null; then
      MISSING_GEO_JSON=$(${jq} -r '[.[] | select(.disabled | not)
          | (.geosites[] | "geosite-" + .), (.geoips[] | "geoip-" + .)] | unique[]' <<< "$RUNTIME_ROUTING_JSON" \
        | while IFS= read -r GEO; do
            case "$GEO" in
              geosite-*) [ -e ${lib.escapeShellArg geositeDir}/"$GEO.srs" ] || printf '%s\n' "$GEO" ;;
              *) [ -e ${lib.escapeShellArg geoipDir}/"$GEO.srs" ] || printf '%s\n' "$GEO" ;;
            esac
          done | ${jq} -R . | ${jq} -cs .)
      # Slurped: a large subscription's tags outgrow one argument.
      ROUTING_TAGS_JSON=$(${jq} -c --slurpfile obs <(printf '%s' "$OUTBOUNDS_JSON") \
        --slurpfile groups <(printf '%s' "''${GROUP_TAGS_JSON:-[]}") \
        '[($obs[0][]?, .outbounds[]?) | .tag? | strings] + $groups[0] | unique' ${configFile})
      CONVERTED=$(${jq} -c \
        --arg backend ${if pureXrayEnabled then "xray" else "sing-box"} \
        --slurpfile tags <(printf '%s' "$ROUTING_TAGS_JSON") \
        --argjson rule_sets ${lib.escapeShellArg (builtins.toJSON (map (rs: rs.name) ctx.ruleSets))} \
        --slurpfile missing_geo <(printf '%s' "$MISSING_GEO_JSON") \
        --arg dir ${lib.escapeShellArg routingRulesDir} \
        --arg geosite_dir ${lib.escapeShellArg geositeDir} \
        --arg geoip_dir ${lib.escapeShellArg geoipDir} \
        --argjson urltest ${lib.boolToString (pureXrayEnabled && ctx.selectionMode == "urltest")} \
        -f ${convertJq} <<< "$RUNTIME_ROUTING_JSON")
      RUNTIME_SECTIONS_JSON=$(${jq} -c '.sections' <<< "$CONVERTED")
      USER_RULE_SETS_JSON=$(${jq} -c '.rule_sets' <<< "$CONVERTED")
      RUNTIME_ROUTING_SKIPPED=$(${jq} -c '.skipped' <<< "$CONVERTED")
      ${jq} -r '.[] | "proxy-suite: routing rule \(.name) left out: \(.why)"' <<< "$RUNTIME_ROUTING_SKIPPED" >&2
    fi
    printf '%s\n' "$RUNTIME_ROUTING_SKIPPED" > "$RUNTIME_DIR/routing-skipped.json.tmp"
    chmod 644 "$RUNTIME_DIR/routing-skipped.json.tmp"
    mv -f "$RUNTIME_DIR/routing-skipped.json.tmp" "$RUNTIME_DIR/routing-skipped.json"
  '';
in
{
  inherit
    render
    apply
    startBlock
    composeJq
    geositeDir
    geoipDir
    ;
}
