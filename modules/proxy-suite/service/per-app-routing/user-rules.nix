# Per-user cgroup nftables mark-rule scripts for per-app routing backends.
{
  lib,
  pkgs,
  perAppRoutingTun,
  perAppRoutingTproxy,
  perAppZapretCfg,
  perAppTunSliceName,
  perAppTproxySliceName,
  perAppZapretSliceName,
  nft,
  awk,
  grepBin,
  findBin,
  headBin,
  systemctl,
}:

let
  # The hold: what a per-app slice sends unmarked is turned away, in a table no backend
  # touches, so a backend restart or crash holds the apps rather than letting them out
  # directly. It goes with the user's unit, not its restart, and mirrors the route's exceptions.
  holdTable = "proxy_suite_per_app_hold";
  # nftables.nix's RESERVED_IP and RESERVED_IP6, which the TUN and TProxy chains leave alone.
  reserved4 = [
    "10.0.0.0/8"
    "100.64.0.0/10"
    "127.0.0.0/8"
    "169.254.0.0/16"
    "172.16.0.0/12"
    "192.0.0.0/24"
    "224.0.0.0/4"
    "240.0.0.0/4"
    "255.255.255.255/32"
  ];
  reserved6 = [
    "::/128"
    "::1/128"
    "::ffff:0:0/96"
    "fc00::/7"
    "fe80::/10"
    "ff00::/8"
  ];
  nftSet = items: "{ ${lib.concatStringsSep ", " items} }";
  # As shell words in double quotes, printed one per line: a mark of "$mark" is the shell's.
  # Every route marks lookups wherever the resolver is, loopback's too. `allow`: what goes
  # unmarked, in either family.
  mkHoldBodies =
    {
      # The marks the route's packets carry, as shell text (a number, or "$mark").
      marks,
      allow,
    }:
    let
      # Not merely "no mark": since Linux 5.17 CAP_NET_RAW sets one (ping -m), so a held app
      # could mark its way out. A kernel AmneziaWG interface's own encapsulated packets keep
      # the app's socket with the interface's FwMark: the via route lists that mark too.
      unmarked = "meta mark != { ${lib.concatStringsSep ", " marks} }";
      reject = "reject with icmpx admin-prohibited";
      allow4 = builtins.filter (cidr: !lib.hasInfix ":" cidr) allow;
      allow6 = builtins.filter (lib.hasInfix ":") allow;
      bodies = [
        "${unmarked} meta l4proto { tcp, udp } th dport 53 ${reject}"
        "${unmarked} ct direction != reply ip daddr != ${nftSet allow4} ${reject}"
        "${unmarked} ct direction != reply ip6 daddr != ${nftSet allow6} ${reject}"
      ];
    in
    "printf '%s\\n' ${lib.concatMapStringsSep " " (body: "\"${body}\"") bodies}";
  tunHold =
    mark:
    mkHoldBodies {
      marks = [ mark ];
      allow = reserved4 ++ reserved6 ++ perAppRoutingTun.localSubnets;
    };
  tproxyHold =
    mark:
    mkHoldBodies {
      marks = [ mark ];
      allow = reserved4 ++ reserved6 ++ perAppRoutingTproxy.localSubnets;
    };
  # Deletes the rules of one comment from a chain, if the table is there.
  dropRulesByComment = table: chain: comment: ''
    handles=$(${nft} -a list chain ${table} ${chain} 2>/dev/null \
      | ${grepBin} -F "comment \"${comment}\"" \
      | ${awk} '{ print $NF }' || true)
    if [ -n "$handles" ]; then
      while IFS= read -r handle; do
        [ -n "$handle" ] || continue
        ${nft} delete rule ${table} ${chain} handle "$handle" || true
      done <<< "$handles"
    fi
  '';
  # `prelude` runs first and may set what the rest reads: a template whose instance carries
  # more than the uid turns its $1 into the uid and sets the shell variables that `nftTable`,
  # `markRule` and `sliceNameArg` (the slice's name, as shell text) then name.
  mkUserRuleStart =
    {
      name,
      nftFamily,
      nftTable,
      nftChain,
      sliceName ? null,
      sliceNameArg ? lib.escapeShellArg sliceName,
      sliceLabel,
      markRule,
      prelude ? "",
      # Shell text printing the hold's rule bodies (mkHoldBodies); null: no hold.
      hold ? null,
    }:
    pkgs.writeShellScript "proxy-suite-per-app" ''
      set -euo pipefail
      ${prelude}
      uid="$1"
      if ! [[ $uid =~ ^[0-9]+$ ]]; then
        echo "proxy-suite: '$uid' is not a uid" >&2
        exit 1
      fi
      rule_comment_prefix="proxy-suite-${name}-user-$uid"
      mark_comment="$rule_comment_prefix-mark"
      cgroup_root="/sys/fs/cgroup/user.slice/user-$uid.slice/user@$uid.service"
      if ! [ -d "$cgroup_root" ]; then
        echo "proxy-suite: user cgroup root does not exist for uid $uid: $cgroup_root" >&2
        exit 1
      fi

      # The user owns this subtree and names its directories, quotes and semicolons included:
      # only a path nft reads as the one quoted string below, never one that closes the quote
      # and runs nft commands of its own as root. systemd's names never need more.
      cgroup_dir=$(${findBin} "$cgroup_root" -type d -name ${sliceNameArg} \
        | ${grepBin} -E '^[A-Za-z0-9@._:+,=\\/-]+$' | ${headBin} -n1 || true)
      if [ -z "$cgroup_dir" ]; then
        echo "proxy-suite: ${sliceLabel} slice cgroup does not exist for uid $uid under $cgroup_root" >&2
        exit 1
      fi
      cgroup_path=''${cgroup_dir#/sys/fs/cgroup/}
      cgroup_level=$(printf '%s' "$cgroup_path" | ${awk} -F/ '{ print NF }')
      ${lib.optionalString (hold != null) ''
        # The hold first: from here on, nothing of the app leaves unmarked.
        hold_comment="$rule_comment_prefix-hold"
        ${dropRulesByComment "inet ${holdTable}" "output" "$hold_comment"}
        {
          printf '%s\n' "add table inet ${holdTable}" \
            "add chain inet ${holdTable} output { type filter hook output priority filter; policy accept; }"
          # In a subshell: `hold` may be a case statement over several lines.
          (
            ${hold}
          ) | while IFS= read -r body; do
            printf 'add rule inet ${holdTable} output socket cgroupv2 level %s "%s" %s comment "%s"\n' \
              "$cgroup_level" "$cgroup_path" "$body" "$hold_comment"
          done
        } | ${nft} -f -
      ''}

      handles=$(${nft} -a list chain ${nftFamily} ${nftTable} ${nftChain} 2>/dev/null \
        | ${grepBin} -F "comment \"$rule_comment_prefix-mark\"" \
        | ${awk} '{ print $NF }' || true)
      if [ -n "$handles" ]; then
        while IFS= read -r handle; do
          [ -n "$handle" ] || continue
          ${nft} delete rule ${nftFamily} ${nftTable} ${nftChain} handle "$handle" || true
        done <<< "$handles"
      fi

      printf '%s\n' \
        "add rule ${nftFamily} ${nftTable} ${nftChain} socket cgroupv2 level $cgroup_level \"$cgroup_path\" ${markRule} comment \"$mark_comment\"" \
        | ${nft} -f -
    '';

  mkUserRuleStop =
    {
      name,
      nftFamily,
      nftTable,
      nftChain,
      prelude ? "",
      # Whether the start put a hold in (mkUserRuleStart).
      hold ? false,
      # The unit this runs in, as shell text.
      unitName ? ''"proxy-suite-${name}-user@$uid.service"'',
    }:
    pkgs.writeShellScript "proxy-suite-per-app" ''
      set -euo pipefail
      ${prelude}
      uid="$1"
      rule_comment_prefix="proxy-suite-${name}-user-$uid"
      ${lib.optionalString hold ''
        # Its restart (the backend's restart or crash, through Requires=, or a switch) keeps the
        # hold, a job of that type until the stop half is done: the app waits for its marking.
        if ! ${systemctl} list-jobs --no-legend ${unitName} \
          | ${awk} '$3 == "restart" { found = 1 } END { exit !found }'; then
          ${dropRulesByComment "inet ${holdTable}" "output" "$rule_comment_prefix-hold"}
        fi
      ''}
      handles=$(${nft} -a list chain ${nftFamily} ${nftTable} ${nftChain} 2>/dev/null \
        | ${grepBin} -F "comment \"$rule_comment_prefix-mark\"" \
        | ${awk} '{ print $NF }' || true)
      if [ -n "$handles" ]; then
        while IFS= read -r handle; do
          [ -n "$handle" ] || continue
          ${nft} delete rule ${nftFamily} ${nftTable} ${nftChain} handle "$handle" || true
        done <<< "$handles"
      fi
    '';

  perAppTunUserRuleStart = mkUserRuleStart {
    name = "per-app-tun";
    nftFamily = "inet";
    nftTable = "proxy_suite_per_app_tun";
    # Not "output": both of that chain's paths into the marking rules jump here.
    nftChain = "app_mark";
    sliceName = perAppTunSliceName;
    sliceLabel = "app TUN";
    markRule = "meta mark set ${toString perAppRoutingTun.fwmark} ct mark set ${toString perAppRoutingTun.fwmark}";
    hold = tunHold (toString perAppRoutingTun.fwmark);
  };
  perAppTunUserRuleStop = mkUserRuleStop {
    name = "per-app-tun";
    nftFamily = "inet";
    nftTable = "proxy_suite_per_app_tun";
    nftChain = "app_mark";
    hold = true;
  };

  perAppTproxyUserRuleStart = mkUserRuleStart {
    name = "per-app-tproxy";
    nftFamily = "inet";
    nftTable = "proxy_suite_per_app_tproxy";
    nftChain = "app_mark";
    sliceName = perAppTproxySliceName;
    sliceLabel = "app TProxy";
    markRule = "meta mark set ${toString perAppRoutingTproxy.fwmark} ct mark set ${toString perAppRoutingTproxy.fwmark}";
    hold = tproxyHold (toString perAppRoutingTproxy.fwmark);
  };
  perAppTproxyUserRuleStop = mkUserRuleStop {
    name = "per-app-tproxy";
    nftFamily = "inet";
    nftTable = "proxy_suite_per_app_tproxy";
    nftChain = "app_mark";
    hold = true;
  };

  perAppZapretUserRuleStart = mkUserRuleStart {
    name = "per-app-zapret";
    nftFamily = "inet";
    nftTable = "proxy_suite_per_app_zapret_mark";
    nftChain = "output";
    sliceName = perAppZapretSliceName;
    sliceLabel = "app zapret";
    markRule = "meta mark set meta mark or ${toString perAppZapretCfg.filterMark} ct mark set ct mark or ${toString perAppZapretCfg.filterMark}";
  };
  perAppZapretUserRuleStop = mkUserRuleStop {
    name = "per-app-zapret";
    nftFamily = "inet";
    nftTable = "proxy_suite_per_app_zapret_mark";
    nftChain = "output";
  };
in
{
  inherit
    mkUserRuleStart
    mkUserRuleStop
    mkHoldBodies
    tunHold
    tproxyHold
    ;
  inherit
    perAppTunUserRuleStart
    perAppTunUserRuleStop
    perAppTproxyUserRuleStart
    perAppTproxyUserRuleStop
    perAppZapretUserRuleStart
    perAppZapretUserRuleStop
    ;
}
