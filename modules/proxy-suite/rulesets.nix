# proxy.routing.ruleSets: downloaded by the service user into the state directory, where
# sing-box reads them as local rule sets and reloads each one when its file changes.
{
  lib,
  pkgs,
  cfg,
  derived,
}:

let
  fillTemplate = import ./lib/fill-template.nix;
  inherit (derived) ruleSets localProxy;
  inherit (derived.constants) ruleSetsDir unprivilegedServiceConfig serviceUser;
  inherit (cfg.host) privileged;
  singBox = "${cfg.proxy.singBox.package}/bin/sing-box";
  curl = "${pkgs.curl}/bin/curl";

  inherit (localProxy) auth;
  passwordSource =
    if auth.passwordFile != null then
      auth.passwordFile
    else if auth.password != null then
      pkgs.writeText "proxy-suite-rulesets" auth.password
    else
      null;
  withProxyAuth = lib.any (rs: rs.detour == "proxy") ruleSets && localProxy.authEnabled;

  # What sing-box reads until the first download: a rule set that matches nothing.
  emptySource = pkgs.writeText "proxy-suite-rulesets.json" (
    builtins.toJSON {
      version = 3;
      rules = [ ];
    }
  );
  emptyBinary = pkgs.runCommand "proxy-suite-rulesets.srs" { } ''
    ${singBox} rule-set compile --output "$out" ${emptySource}
  '';

  fetchScript = pkgs.writeShellScript "proxy-suite-rulesets" (
    fillTemplate ./rulesets-fetch.template.sh {
      proxyHost = localProxy.hostPart;
      proxyPort = toString cfg.proxy.listener.port;
      proxyLogin = lib.optionalString withProxyAuth ''
        local login
        login=${lib.escapeShellArg auth.username}:"$(< "$CREDENTIALS_DIRECTORY/proxy-password")"
        login=''${login//\\/\\\\}
        printf 'proxy-user = "%s"\n' "''${login//\"/\\\"}"
      '';
      coreutils = pkgs.coreutils;
      inherit curl singBox;
      jq = pkgs.jq;
      fetchRuleSets = lib.concatMapStrings (rs: ''
        fetch ${
          lib.escapeShellArgs [
            rs.name
            rs.url
            rs.path
            rs.dnsPath
            rs.format
            rs.detour
          ]
        }
      '') ruleSets;
    }
  );
in
{
  services.proxy-suite.internal = {
    # sing-box refuses to start on a missing rule set: an empty one stands in until the first
    # download, and is only copied where no file is yet.
    tmpfiles = [
      "d ${ruleSetsDir} 0755 ${if privileged then "${serviceUser} ${serviceUser}" else "- -"} -"
    ]
    ++ lib.concatMap (rs: [
      "C ${rs.path} - - - - ${if rs.format == "binary" then emptyBinary else emptySource}"
      "C ${rs.dnsPath} - - - - ${emptySource}"
    ]) ruleSets;

    services.proxy-suite-rulesets = {
      description = "proxy-suite - download routing rule sets";
      after = [
        "network-online.target"
        "proxy-suite-socks.service"
      ];
      wants = [ "network-online.target" ];
      serviceConfig =
        unprivilegedServiceConfig [ ]
        # Through the proxy curl looks nothing up itself (socks5h).
        // lib.optionalAttrs (lib.any (rs: rs.detour == "direct") ruleSets) (
          derived.constants.killSwitchOwnLookups pkgs
        )
        // {
          Type = "oneshot";
          ExecStart = fetchScript;
          StateDirectory = "proxy-suite/rulesets";
          StateDirectoryMode = "0755";
          LoadCredential = lib.optional withProxyAuth "proxy-password:${passwordSource}";
        };
    };

    timers.proxy-suite-rulesets = {
      description = "Periodic proxy-suite rule set download";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnActiveSec = "1m";
        OnUnitActiveSec = cfg.proxy.routing.ruleSetUpdateInterval;
      };
    };
  };
}
