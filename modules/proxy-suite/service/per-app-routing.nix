# App routing backend infrastructure (TUN, TProxy, zapret).
{
  lib,
  pkgs,
  cfg,
  singBoxCfg,
  perAppRoutingCfg,
  perAppRoutingTun,
  perAppRoutingTproxy,
  perAppZapretCfg,
  perAppTunChainFile,
  perAppTproxyRulesFile,
  perAppZapretRulesFile,
  ip,
  nft,
  awk,
  grepBin,
  findBin,
  headBin,
  seqBin,
  sleepBin,
}:

let
  perAppTunSliceName = "proxy-suite-per-app-tun.slice";
  perAppTproxySliceName = "proxy-suite-per-app-tproxy.slice";
  perAppZapretSliceName = "proxy-suite-per-app-zapret.slice";

  perAppRoutingProfileNames = map (profile: profile.name) perAppRoutingCfg.profiles;
  defaultPerAppRoutingProfiles = lib.optionals perAppRoutingCfg.createDefaultProfiles (
    [
      {
        name = "proxychains";
        route = "proxychains";
      }
    ]
    ++ lib.optionals perAppRoutingTun.enable [
      {
        name = "tun";
        route = "tun";
      }
    ]
    ++ lib.optionals perAppRoutingTproxy.enable [
      {
        name = "tproxy";
        route = "tproxy";
      }
    ]
    ++ lib.optionals (perAppZapretCfg.enable && cfg.zapret.enable) [
      {
        name = "zapret";
        route = "zapret";
      }
    ]
  );
  effectivePerAppRoutingProfiles =
    perAppRoutingCfg.profiles
    ++ builtins.filter (profile: !(builtins.elem profile.name perAppRoutingProfileNames)) defaultPerAppRoutingProfiles;
  effectivePerAppRoutingProfileNames = map (profile: profile.name) effectivePerAppRoutingProfiles;

  perAppRoutingProfilesFile = pkgs.writeText "proxy-suite-per-app-routing-profiles.json" (
    builtins.toJSON effectivePerAppRoutingProfiles
  );

  proxychainsConfigFile = pkgs.writeText "proxy-suite-proxychains.conf" ''
    strict_chain
    ${lib.optionalString perAppRoutingCfg.proxychains.quiet "quiet_mode"}
    ${lib.optionalString perAppRoutingCfg.proxychains.proxyDns "proxy_dns"}
    tcp_read_time_out 15000
    tcp_connect_time_out 8000

    [ProxyList]
    socks5 ${singBoxCfg.listenAddress} ${toString singBoxCfg.port}
  '';
  proxychainsQuietArg = lib.optionalString perAppRoutingCfg.proxychains.quiet "-q ";

  hasProxychainsProfiles = builtins.any (profile: profile.route == "proxychains") effectivePerAppRoutingProfiles;
  hasTunProfiles = builtins.any (profile: profile.route == "tun") effectivePerAppRoutingProfiles;
  hasTproxyProfiles = builtins.any (profile: profile.route == "tproxy") effectivePerAppRoutingProfiles;
  hasZapretProfiles = builtins.any (profile: profile.route == "zapret") effectivePerAppRoutingProfiles;

  perAppTunWaitForInterface = pkgs.writeShellScript "proxy-suite-per-app-tun-wait-for-interface" ''
    set -euo pipefail
    for _ in $(${seqBin} 1 50); do
      if ${ip} link show dev ${lib.escapeShellArg perAppRoutingTun.interface} >/dev/null 2>&1; then
        exit 0
      fi
      ${sleepBin} 0.1
    done
    echo "proxy-suite: app TUN interface ${perAppRoutingTun.interface} did not appear in time" >&2
    exit 1
  '';

  perAppTunUpScript = pkgs.writeShellScript "proxy-suite-per-app-tun-up" ''
    set -euo pipefail
    ${nft} delete table inet proxy_suite_per_app_tun 2>/dev/null || true
    ${nft} -f ${perAppTunChainFile}
    ${perAppTunWaitForInterface}
    ${ip} route replace default dev ${lib.escapeShellArg perAppRoutingTun.interface} table ${toString perAppRoutingTun.routeTable}
    ${ip} rule add fwmark ${toString perAppRoutingTun.fwmark} table ${toString perAppRoutingTun.routeTable} 2>/dev/null || true
  '';

  perAppTunDownScript = pkgs.writeShellScript "proxy-suite-per-app-tun-down" ''
    set -euo pipefail
    ${nft} delete table inet proxy_suite_per_app_tun 2>/dev/null || true
    ${ip} route del default dev ${lib.escapeShellArg perAppRoutingTun.interface} table ${toString perAppRoutingTun.routeTable} 2>/dev/null || true
    ${ip} rule del fwmark ${toString perAppRoutingTun.fwmark} table ${toString perAppRoutingTun.routeTable} 2>/dev/null || true
  '';

  perAppTproxyUpScript = pkgs.writeShellScript "proxy-suite-per-app-tproxy-up" ''
    set -euo pipefail
    ${nft} delete table ip proxy_suite_per_app_tproxy 2>/dev/null || true
    ${nft} -f ${perAppTproxyRulesFile}
    ${ip} route replace local default dev lo table ${toString perAppRoutingTproxy.routeTable}
    ${ip} rule add fwmark ${toString perAppRoutingTproxy.fwmark} table ${toString perAppRoutingTproxy.routeTable} 2>/dev/null || true
  '';

  perAppTproxyDownScript = pkgs.writeShellScript "proxy-suite-per-app-tproxy-down" ''
    set -euo pipefail
    ${nft} delete table ip proxy_suite_per_app_tproxy 2>/dev/null || true
    ${ip} route del local default dev lo table ${toString perAppRoutingTproxy.routeTable} 2>/dev/null || true
    ${ip} rule del fwmark ${toString perAppRoutingTproxy.fwmark} table ${toString perAppRoutingTproxy.routeTable} 2>/dev/null || true
  '';

  # Generate a "start" script that adds a per-user cgroup nftables mark rule.
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

  # Generate a "stop" script that removes all per-user cgroup nftables mark rules.
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

  mkAnchorService = sliceName: desc: {
    description = desc;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Slice = sliceName;
      ExecStart = "${pkgs.coreutils}/bin/true";
      ExecStop = "${pkgs.coreutils}/bin/true";
    };
  };
in
{
  inherit
    perAppTunSliceName
    perAppTproxySliceName
    perAppZapretSliceName
    perAppTunUpScript
    perAppTunDownScript
    perAppTproxyUpScript
    perAppTproxyDownScript
    perAppTunUserRuleStart
    perAppTunUserRuleStop
    perAppTproxyUserRuleStart
    perAppTproxyUserRuleStop
    perAppZapretUserRuleStart
    perAppZapretUserRuleStop
    mkAnchorService
    effectivePerAppRoutingProfiles
    effectivePerAppRoutingProfileNames
    perAppRoutingProfilesFile
    proxychainsConfigFile
    proxychainsQuietArg
    hasProxychainsProfiles
    hasTunProfiles
    hasTproxyProfiles
    hasZapretProfiles
    ;
}
