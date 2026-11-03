# Autonomous systems routed by (`asns` in proxy.routing, its rules and the outbounds' routing,
# and the runtime rules' asn:N): each one's address list from the ipverse asn-ip dataset, as a
# sing-box source rule set in the state directory, through the proxy. sing-box reloads a list
# as it changes. XRay has no rule sets and takes the lists in at start (start-scripts.nix), so a
# change restarts it.
{
  lib,
  pkgs,
  cfg,
  derived,
}:

let
  fillTemplate = import ./lib/fill-template.nix;
  inherit (derived)
    localProxy
    declaredAsns
    asnPath
    pureXrayEnabled
    ;
  inherit (derived.constants)
    asnDir
    routingRulesDir
    unprivilegedServiceConfig
    serviceUser
    systemctl
    ;
  inherit (cfg.host) privileged;
  singBox = "${cfg.proxy.singBox.package}/bin/sing-box";

  inherit (localProxy) auth;
  passwordSource =
    if auth.passwordFile != null then
      auth.passwordFile
    else if auth.password != null then
      pkgs.writeText "proxy-suite-asn" auth.password
    else
      null;
  withProxyAuth = localProxy.authEnabled;

  # What sing-box reads until the first download: a list that matches nothing.
  emptySource = pkgs.writeText "proxy-suite-asn.json" (
    builtins.toJSON {
      version = 2;
      rules = [ ];
    }
  );

  fetchScript = pkgs.writeShellScript "proxy-suite-asn" (
    fillTemplate ./asn-fetch.template.sh {
      proxyHost = localProxy.hostPart;
      proxyPort = toString cfg.proxy.listener.port;
      proxyLogin = lib.optionalString withProxyAuth ''
        local login
        login=${lib.escapeShellArg auth.username}:"$(< "$CREDENTIALS_DIRECTORY/proxy-password")"
        login=''${login//\\/\\\\}
        printf 'proxy-user = "%s"\n' "''${login//\"/\\\"}"
      '';
      inherit singBox;
      asnDir = lib.escapeShellArg asnDir;
      baseUrl = "https://raw.githubusercontent.com/ipverse/asn-ip/master/as";
      # A system's announced prefixes: Amazon's run to some thousands.
      maxPrefixes = "20000";
      declaredAsns = lib.escapeShellArgs (map toString declaredAsns);
      routingRules = lib.escapeShellArg "${routingRulesDir}/rules.json";
      curl = "${pkgs.curl}/bin/curl";
      jq = "${pkgs.jq}/bin/jq";
      inherit (pkgs) coreutils diffutils;
    }
  );

  # As root, after every run: XRay restarted when a list it routes by has changed.
  applyScript = pkgs.writeShellScript "proxy-suite-asn-apply" ''
    [ -e ${lib.escapeShellArg "${asnDir}/.changed"} ] || exit 0
    rm -f ${lib.escapeShellArg "${asnDir}/.changed"}
    for unit in proxy-suite-socks proxy-suite-tun proxy-suite-per-app-tun; do
      if ${systemctl} is-active --quiet "$unit"; then
        ${systemctl} restart "$unit" || true
      fi
    done
  '';
in
{
  services.proxy-suite.internal = {
    # sing-box refuses to start on a missing rule set: an empty one stands in until the first
    # download, and is only copied where no file is yet. Runtime rules' ones are made at start.
    tmpfiles = [
      "d ${asnDir} 0755 ${if privileged then "${serviceUser} ${serviceUser}" else "- -"} -"
    ]
    ++ map (n: "C ${asnPath n} - - - - ${emptySource}") declaredAsns;

    services.proxy-suite-asn = {
      description = "proxy-suite - download the address lists of the routed autonomous systems";
      after = [
        "network-online.target"
        "proxy-suite-socks.service"
      ];
      wants = [ "network-online.target" ];
      serviceConfig = unprivilegedServiceConfig [ ] // {
        Type = "oneshot";
        ExecStart = fetchScript;
        # After a failed run too: the lists that did arrive count.
        ExecStopPost = lib.optional pureXrayEnabled "+${applyScript}";
        StateDirectory = "proxy-suite/asn";
        StateDirectoryMode = "0755";
        LoadCredential = lib.optional withProxyAuth "proxy-password:${passwordSource}";
      };
    };

    timers.proxy-suite-asn = {
      description = "Periodic proxy-suite autonomous system list download";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnActiveSec = "2m";
        OnUnitActiveSec = cfg.proxy.routing.asnUpdateInterval;
      };
    };
  };
}
