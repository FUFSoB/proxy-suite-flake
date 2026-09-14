# Cloudflare WARP: the AmneziaWG profile and, without a configFile, wgcf registration.
{
  lib,
  pkgs,
  cfg,
  derived,
}:

let
  w = derived.warpCfg;
  listener = cfg.proxy.listener;
  auth = listener.auth;
  host =
    if
      builtins.elem listener.address [
        "0.0.0.0"
        "::"
      ]
    then
      "127.0.0.1"
    else
      listener.address;
  hostPart = if lib.hasInfix ":" host then "[${host}]" else host;
  passwordSource =
    if auth.passwordFile != null then
      auth.passwordFile
    else if auth.password != null then
      pkgs.writeText "proxy-suite-warp-proxy-password" auth.password
    else
      null;
  userinfo = lib.optionalString (auth.username != null && passwordSource != null) ''
    userinfo=$(${pkgs.jq}/bin/jq -rn --arg u ${lib.escapeShellArg auth.username} \
      --rawfile p ${lib.escapeShellArg passwordSource} '"\($u | @uri):\($p | rtrimstr("\n") | @uri)@"')
  '';

  registerScript = pkgs.writeShellScript "proxy-suite-warp-register" ''
    set -euo pipefail
    [ -s wgcf-profile.conf ] && exit 0

    register() {
      [ -s wgcf-account.toml ] || wgcf register --accept-tos
      wgcf generate
    }

    ${
      if cfg.proxy.enable then
        ''
          # The API is blocked in some countries, so the local proxy goes first. It may
          # still be coming up, as when a switch restarts it alongside this unit.
          for _ in {1..30}; do
            (exec 3<>/dev/tcp/${host}/${toString listener.port}) 2>/dev/null && break
            sleep 1
          done
          userinfo=
          ${userinfo}
          HTTPS_PROXY="socks5://''${userinfo}${hostPart}:${toString listener.port}" register || register
          ${lib.optionalString w.asOutbound "${pkgs.systemd}/bin/systemctl --no-block try-restart proxy-suite-socks.service"}
        ''
      else
        "register"
    }
  '';
in
{
  services.proxy-suite.amneziaWg.profiles = lib.mkIf w.asAmneziaWg {
    warp.configFile = w.profilePath;
  };

  systemd.services = lib.mkIf w.autoRegister {
    proxy-suite-warp = {
      description = "proxy-suite - register a Cloudflare WARP device with wgcf";
      after = [ "network-online.target" ] ++ lib.optional cfg.proxy.enable "proxy-suite-socks.service";
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.wgcf ];
      # Retried until it registers. Not a oneshot: a slow or failed registration must not
      # hold up or fail a switch.
      startLimitIntervalSec = 0;
      serviceConfig = {
        Type = "simple";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = 30;
        StateDirectory = "proxy-suite/warp";
        StateDirectoryMode = "0700";
        WorkingDirectory = "/var/lib/proxy-suite/warp";
        UMask = "0077";
        ExecStart = registerScript;
      };
    };

    # Only pulls registration in: a simple unit gives the profile no ordering guarantee.
    proxy-suite-awg-warp = lib.mkIf w.asAmneziaWg {
      wants = [ "proxy-suite-warp.service" ];
    };
  };
}
