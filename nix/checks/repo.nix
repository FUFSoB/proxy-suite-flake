{
  pkgs,
  rg,
  generatedOptionsDoc,
  generatedReadmeDoc,
  readmeDocSource,
  trayModuleSource,
  tgWsProxyModuleSource,
  controlModuleSource,
}:

{
  no-secrets = pkgs.runCommand "proxy-suite-no-secrets-check" { } ''
    repo_root=${../../.}
    if ${rg} --pcre2 -n -I -H -S \
      -e '-----BEGIN (RSA|DSA|EC|OPENSSH|PGP) PRIVATE KEY-----' \
      -e 'ghp_[A-Za-z0-9]{36}' \
      -e 'github_pat_[A-Za-z0-9_]{20,}' \
      -e 'glpat-[A-Za-z0-9_-]{20,}' \
      -e 'xox[baprs]-[A-Za-z0-9-]{10,}' \
      -e 'AKIA[0-9A-Z]{16}' \
      -e 'AIza[0-9A-Za-z_-]{35}' \
      -e 'sk-(proj-)?[A-Za-z0-9_-]{20,}' \
      "$repo_root"; then
      echo "secret-like content detected in source tree" >&2
      exit 1
    fi
    touch "$out"
  '';

  options-doc =
    pkgs.runCommand "proxy-suite-options-doc-check" { nativeBuildInputs = [ pkgs.diffutils ]; }
      ''
        diff -u ${../../docs/options.md} ${generatedOptionsDoc}
        touch "$out"
      '';

  readme-doc =
    pkgs.runCommand "proxy-suite-readme-doc-check" { nativeBuildInputs = [ pkgs.diffutils ]; }
      ''
        diff -u ${../../README.md} ${generatedReadmeDoc}
        touch "$out"
      '';

  proxy-ctl-subscription-list =
    pkgs.runCommand "proxy-suite-proxy-ctl-subscription-list-check"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.gawk
          pkgs.jq
        ];
      }
      ''
        proxy_ctl="$TMPDIR/proxy-ctl"
        cat ${../../pkgs/proxy-ctl-lib.sh} ${../../pkgs/proxy-ctl.sh} > "$proxy_ctl"
        chmod +x "$proxy_ctl"

        mkdir -p cache
        printf '%s\n' '["plain","hybrid","bad"]' > tags.json
        printf '%s\n' '[{},{}]' > cache/plain.json
        printf '%s\n' '{"singBox":[{},{}],"xray":[{}]}' > cache/hybrid.json
        printf '%s\n' '{"singBox":[{}]}' > cache/bad.json

        env \
          SUB_TAGS_FILE="$PWD/tags.json" \
          SUB_CACHE_DIR="$PWD/cache" \
          CLASH_API="http://127.0.0.1:9090" \
          SELECTION="first" \
          PER_APP_ROUTING_ENABLED="0" \
          PER_APP_ROUTING_PROXYCHAINS_ENABLED="0" \
          PER_APP_ROUTING_TUN_ENABLED="0" \
          PER_APP_ROUTING_TPROXY_ENABLED="0" \
          PER_APP_ROUTING_ZAPRET_ENABLED="0" \
          PER_APP_ROUTING_PROFILES_FILE="$PWD/profiles.json" \
          PROXYCHAINS_CONFIG="$PWD/proxychains.conf" \
          PROXYCHAINS_QUIET_ARG="" \
          ROUTE_MODE_STATE_FILE="$PWD/route-mode" \
          DEFAULT_ROUTE_MODE="blacklist" \
          bash "$proxy_ctl" subscription list > output

        awk '$1 == "plain" { found = 1; if ($NF != "2") exit 1 } END { exit found ? 0 : 1 }' output
        awk '$1 == "hybrid" { found = 1; if ($NF != "3") exit 1 } END { exit found ? 0 : 1 }' output
        awk '$1 == "bad" { found = 1; if ($NF != "?") exit 1 } END { exit found ? 0 : 1 }' output

        touch "$out"
      '';

  readme-doc-source = builtins.seq (
    assert !(pkgs.lib.hasInfix "environment.systemPackages" readmeDocSource);
    assert !(pkgs.lib.hasInfix "packageByPattern" readmeDocSource);
    true
  ) (pkgs.writeText "proxy-suite-readme-doc-source-check" "ok");

  package-source = builtins.seq (
    assert !(pkgs.lib.hasInfix "../../pkgs/proxy-suite-tray.nix" trayModuleSource);
    assert !(pkgs.lib.hasInfix "../../pkgs/tg-ws-proxy.nix" tgWsProxyModuleSource);
    assert !(pkgs.lib.hasInfix "../../../pkgs/proxy-ctl.nix" controlModuleSource);
    true
  ) (pkgs.writeText "proxy-suite-package-source-check" "ok");
}
