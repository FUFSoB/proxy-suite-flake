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
}:

let
  mkUserRuleStart =
    {
      name,
      nftFamily,
      nftTable,
      nftChain,
      sliceName,
      sliceLabel,
      markRule,
    }:
    pkgs.writeShellScript "proxy-suite-${name}-user-start" ''
      set -euo pipefail
      uid="$1"
      rule_comment_prefix="proxy-suite-${name}-user-$uid"
      mark_comment="$rule_comment_prefix-mark"
      cgroup_root="/sys/fs/cgroup/user.slice/user-$uid.slice/user@$uid.service"
      if ! [ -d "$cgroup_root" ]; then
        echo "proxy-suite: user cgroup root does not exist for uid $uid: $cgroup_root" >&2
        exit 1
      fi

      cgroup_dir=$(${findBin} "$cgroup_root" -type d -name ${lib.escapeShellArg sliceName} | ${headBin} -n1 || true)
      if [ -z "$cgroup_dir" ]; then
        echo "proxy-suite: ${sliceLabel} slice cgroup does not exist for uid $uid under $cgroup_root" >&2
        exit 1
      fi
      cgroup_path=''${cgroup_dir#/sys/fs/cgroup/}
      cgroup_level=$(printf '%s' "$cgroup_path" | ${awk} -F/ '{ print NF }')

      handles=$(${nft} -a list chain ${nftFamily} ${nftTable} ${nftChain} 2>/dev/null \
        | ${grepBin} -F "comment \"$rule_comment_prefix" \
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
    }:
    pkgs.writeShellScript "proxy-suite-${name}-user-stop" ''
      set -euo pipefail
      uid="$1"
      rule_comment_prefix="proxy-suite-${name}-user-$uid"
      handles=$(${nft} -a list chain ${nftFamily} ${nftTable} ${nftChain} 2>/dev/null \
        | ${grepBin} -F "comment \"$rule_comment_prefix" \
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
    nftChain = "output";
    sliceName = perAppTunSliceName;
    sliceLabel = "app TUN";
    markRule = "meta mark set ${toString perAppRoutingTun.fwmark} ct mark set ${toString perAppRoutingTun.fwmark}";
  };
  perAppTunUserRuleStop = mkUserRuleStop {
    name = "per-app-tun";
    nftFamily = "inet";
    nftTable = "proxy_suite_per_app_tun";
    nftChain = "output";
  };

  perAppTproxyUserRuleStart = mkUserRuleStart {
    name = "per-app-tproxy";
    nftFamily = "ip";
    nftTable = "proxy_suite_per_app_tproxy";
    nftChain = "output";
    sliceName = perAppTproxySliceName;
    sliceLabel = "app TProxy";
    markRule = "meta mark set ${toString perAppRoutingTproxy.fwmark} ct mark set ${toString perAppRoutingTproxy.fwmark}";
  };
  perAppTproxyUserRuleStop = mkUserRuleStop {
    name = "per-app-tproxy";
    nftFamily = "ip";
    nftTable = "proxy_suite_per_app_tproxy";
    nftChain = "output";
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
    perAppTunUserRuleStart
    perAppTunUserRuleStop
    perAppTproxyUserRuleStart
    perAppTproxyUserRuleStop
    perAppZapretUserRuleStart
    perAppZapretUserRuleStop
    ;
}
