# Shared AmneziaWG plumbing: bringing an interface up the way both the client profiles
# (./amnezia-wg.nix) and the server listeners (./amnezia-wg-inbounds.nix) need it.
{
  lib,
  pkgs,
  awgCfg,
}:
{
  # The kernel module is optional; userspace works without it.
  modprobe = lib.optionalString (awgCfg.kernelModulePackage != null) ''
    ${pkgs.kmod}/bin/modprobe amneziawg 2>/dev/null || true
  '';

  # `implementation` is a shell word holding "userspace" or "kernel", `config` the .conf path.
  # The 3.1 kernel module dropped RandomTrailers packets with ranged H1-H3 (seen on 20260812);
  # userspace carries the fix, so a profile that needs it asks for userspace by name.
  awgQuickUp = implementation: config: ''
    if [[ "${implementation}" == userspace ]]; then
      WG_QUICK_FORCE_USERSPACE_IMPLEMENTATION=1 \
        WG_QUICK_USERSPACE_IMPLEMENTATION=${awgCfg.userspacePackage}/bin/amneziawg-go \
        ${awgCfg.toolsPackage}/bin/awg-quick up ${config}
    else
      WG_QUICK_USERSPACE_IMPLEMENTATION=${awgCfg.userspacePackage}/bin/amneziawg-go \
        ${awgCfg.toolsPackage}/bin/awg-quick up ${config}
    fi
  '';
}
