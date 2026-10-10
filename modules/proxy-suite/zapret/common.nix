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
  derived = import ../derived.nix { inherit lib cfg; };
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
    # AmneziaWG outbound interfaces, and those apps run through: what enters them is a
    # tunnel's inside. Desync there would send its fakes out the uplink, past the tunnel.
    # (A trailing * is nft's wildcard; the iptables rules make it +.)
    ++ map (ob: ob.interface) derived.awgInterfaceOutbounds
    ++ lib.optional derived.awgRuntimeIfaceOutbounds "${derived.constants.awgRuntimeIfacePrefix}*"
    ++ lib.optional derived.perAppViaProfiles "${derived.constants.awgAppIfacePrefix}*"
    # TProxy reroutes local apps' packets out lo to the backend's listener; desync there
    # corrupts the handshake the backend reads, like on a TUN.
    ++ lib.optional (
      cfg.proxy.enable && (cfg.proxy.tproxy.enable || cfg.perAppRouting.tproxy.enable)
    ) "lo"
  );

  # The transparent backends steer the same packets; a per-app zapret instance replaces them.
  # The zapret units run as root: capabilities bounded to what the init scripts and nfqws
  # use, and no new privileges (nfqws narrows itself further).
  daemonSandbox = lib.optionalAttrs cfg.host.privileged {
    NoNewPrivileges = true;
    CapabilityBoundingSet = [
      "CAP_NET_ADMIN"
      "CAP_NET_RAW"
      "CAP_SETUID"
      "CAP_SETGID"
      "CAP_SETPCAP"
      "CAP_SYS_MODULE"
      "CAP_CHOWN"
      "CAP_FOWNER"
      "CAP_DAC_OVERRIDE"
      "CAP_KILL"
    ];
    LockPersonality = true;
    RestrictRealtime = true;
  };
  # The per-app instance's ExecStartPre: it has nothing to add under a global mode, which
  # it never displaces (constants.refuseUnderGlobal); those take it down as they start.
  perAppRefuseUnderGlobal =
    derived.constants.refuseUnderGlobal pkgs
      derived.perAppGlobalModes."proxy-suite-per-app-zapret";

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
