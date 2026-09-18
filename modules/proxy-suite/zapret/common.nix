# What both zapret engines need the same way: which units they must not run beside, the
# interfaces to keep out of NFQUEUE, and the per-app mark table's nft hooks.
{
  lib,
  pkgs,
  cfg,
  nft ? null,
  perAppZapretRulesFile ? null,
  # zapret v1 names its scripts proxy-suite-zapret, zapret2 proxy-suite-zapret2.
  scriptName ? "proxy-suite-zapret",
}:
let
  dropMarkTable = "${nft} delete table inet proxy_suite_per_app_zapret_mark 2>/dev/null || true";
in
{
  # Global AmneziaWG profiles only: an outbound one leaves the host's routes alone.
  awgServiceNames = map (name: "proxy-suite-awg-${name}.service") (
    builtins.attrNames (lib.filterAttrs (_: profile: profile.asOutbound == null) cfg.amneziaWg.profiles)
  );

  tunInterfaces = lib.unique (
    lib.optional (cfg.proxy.enable && cfg.proxy.tun.enable) cfg.proxy.tun.interface
    ++ lib.optional (cfg.proxy.enable && cfg.perAppRouting.tun.enable) cfg.perAppRouting.tun.interface
  );

  # The transparent backends steer the same packets; a per-app zapret instance replaces them.
  perAppConflicts = [
    "proxy-suite-tproxy.service"
    "proxy-suite-tun.service"
  ];

  perAppZapretMarkUpScript = pkgs.writeShellScript scriptName ''
    set -euo pipefail
    ${dropMarkTable}
    ${nft} -f ${perAppZapretRulesFile}
  '';

  perAppZapretMarkDownScript = pkgs.writeShellScript scriptName ''
    set -euo pipefail
    ${dropMarkTable}
  '';
}
