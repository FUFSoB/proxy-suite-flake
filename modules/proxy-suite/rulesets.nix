# proxy.routing.ruleSets: downloaded by the service user into the state directory, where
# sing-box reads them as local rule sets and reloads each one when its file changes.
{
  lib,
  pkgs,
  cfg,
  derived,
}:

let
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

  fetchScript = pkgs.writeShellScript "proxy-suite-rulesets" ''
    set -uo pipefail
    proxy=(--proxy socks5h://${localProxy.hostPart}:${toString cfg.proxy.listener.port})
    ${lib.optionalString withProxyAuth ''
      proxy+=(--proxy-user ${lib.escapeShellArg auth.username}:"$(< "$CREDENTIALS_DIRECTORY/proxy-password")")
    ''}
    failed=0

    # A download replaces the file only once sing-box has read it back, so a bad one never
    # reaches the backend; a failed one keeps what was there. Its domain rules go to the copy
    # DNS rules read.
    fetch() {
      local name=$1 url=$2 path=$3 dns=$4 format=$5 detour=$6 tmp dnsTmp
      local args=(--fail --silent --show-error --location --max-time 120 --max-filesize 64M)
      [ "$detour" = proxy ] && args+=("''${proxy[@]}")
      tmp=$(${pkgs.coreutils}/bin/mktemp "$path.XXXXXX") || { failed=1; return; }
      dnsTmp=$(${pkgs.coreutils}/bin/mktemp "$dns.XXXXXX") || { rm -f "$tmp"; failed=1; return; }
      if ${curl} "''${args[@]}" --output "$tmp" "$url" && valid "$tmp" "$format" &&
        domains "$tmp" "$format" > "$dnsTmp" && valid "$dnsTmp" source; then
        chmod 0644 "$tmp" "$dnsTmp"
        mv -f "$dnsTmp" "$dns"
        mv -f "$tmp" "$path"
        echo "rule set $name: updated"
      else
        rm -f "$tmp" "$dnsTmp"
        echo "rule set $name: not updated from $url; keeping the one it has" >&2
        failed=1
      fi
    }
    valid() {
      if [ "$2" = binary ]; then
        ${singBox} rule-set decompile --output /dev/null "$1" 2>/dev/null
      else
        ${singBox} rule-set compile --output /dev/null "$1" 2>/dev/null
      fi
    }
    domains() {
      if [ "$2" = binary ]; then
        ${singBox} rule-set decompile --output /dev/stdout "$1"
      else
        cat "$1"
      fi | ${pkgs.jq}/bin/jq '.rules = [(.rules // [])[]
        | select((.type // "default") == "default"
          and (has("domain") or has("domain_suffix") or has("domain_keyword") or has("domain_regex")))
        | del(.ip_cidr, .ip_is_private)]'
    }

    ${lib.concatMapStrings (rs: ''
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
    '') ruleSets}
    exit "$failed"
  '';
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
      serviceConfig = unprivilegedServiceConfig [ ] // {
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
