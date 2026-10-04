{
  pkgs,
  rg,
  evalProxySuite,
  generatedOptionsDoc,
  generatedReadmeDoc,
  readmeDocSource,
  tgWsProxyModuleSource,
  controlModuleSource,
}:

let
  fillTemplate = import ../../modules/proxy-suite/lib/fill-template.nix;
  # Every proxy-ctl CLI check runs against the same disabled-feature defaults; only the
  # files and the feature under test differ.
  perAppRoutingOff = ''
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
  '';
  # The start script's outbound blocks, reading the runtime spool from obd/ in the build dir.
  outboundScriptBlocks =
    groups:
    import ../../modules/proxy-suite/service/script-blocks/outbounds.nix {
      lib = pkgs.lib;
      inherit pkgs;
      jq = "${pkgs.jq}/bin/jq";
      proxyCfg = {
        selectionExclude = [ "ex" ];
        inherit groups;
        priority = { };
        urlTest = {
          url = "https://t";
          interval = "3m";
        };
      };
      selectionMode = "urltest";
      hybridEnabled = false;
      # Relative: the build directory.
      pinnedOutboundFile = "pinned";
      runtimeOutboundsDir = "obd";
      singBoxCfg.urlTest.tolerance = 50;
      sshProxyCfg = null;
      warpCfg = null;
      torCfg = null;
      whitelistBypassJoiners = [ ];
      awgOutbounds = null;
      # The start script checks for symlinks in the spool; here it is only this build's.
      constants.readSourceFunction = _: ''
        _proxy_suite_read_source() { cat -- "$1"; }
      '';
      pureXrayEnabled = false;
      collapseNamedOutbounds = null;
      backend = null;
      backendArg = "--backend sing-box";
      xraySidecarRoutingMark = null;
      # A runtime .url outbound would need the parsers; the checks only drop JSON ones.
      python3 = "false";
      parserScriptsPythonPath = "";
      buildOutboundPy = "";
      mkSubscriptionBlock = null;
      mkSubscriptionLoadHelperBlock = null;
      runtimeSubscriptionsBlock = null;
    };
in
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
        diff -ru ${../../docs/options} ${generatedOptionsDoc}
        # A package default without defaultText renders as a store derivation.
        if grep -rn '<derivation ' ${generatedOptionsDoc}; then
          echo "package option without defaultText" >&2
          exit 1
        fi
        touch "$out"
      '';

  readme-doc =
    pkgs.runCommand "proxy-suite-readme-doc-check" { nativeBuildInputs = [ pkgs.diffutils ]; }
      ''
        diff -u ${../../README.md} ${generatedReadmeDoc}
        touch "$out"
      '';

  # The usage guides are hand-written; what can go stale in them is checked here. Every
  # ```nix block that sets services.proxy-suite (in the guides, their examples/ and the
  # README) must evaluate, with no proxy-suite assertion or warning, from its copy in
  # docs/usage/.snippets (nix/usage-snippets.nix), which must match it. Every relative link
  # must reach a file, and its #anchor an <a id> there.
  usage-docs =
    let
      inherit (pkgs) lib;
      usageDir = ../../docs/usage;
      usageSnippets = import ../usage-snippets.nix { inherit lib; };
      inherit (usageSnippets) guides snippets;
      guideText = name: builtins.readFile (usageDir + "/${name}");

      snippetDir = ../.. + "/${usageSnippets.dir}";
      committed = lib.optionals (builtins.pathExists snippetDir) (
        builtins.attrNames (builtins.readDir snippetDir)
      );
      outdated = "is out of date, run `nix run .#update-docs`";

      # Every visible option's value, so a wrong type fails too. Packages are skipped:
      # forcing one evaluates its whole build graph. Removed options throw when read.
      plain =
        value:
        if lib.isDerivation value then
          null
        else if builtins.isAttrs value then
          lib.mapAttrs (_: plain) value
        else if builtins.isList value then
          map plain value
        else
          value;
      visibleValues =
        opts: cfg:
        lib.mapAttrs (
          name: opt: if lib.isOption opt then plain cfg.${name} else visibleValues opt cfg.${name}
        ) (lib.filterAttrs (name: opt: name != "_module" && (opt.visible or true) != false) opts);
      snippetProblems =
        snippet:
        let
          path = snippetDir + "/${snippet.file}";
          eval = evalProxySuite [
            (import path)
            { system.stateVersion = "26.05"; }
          ];
          inherit (eval) config;
          failed = map (a: a.message) (builtins.filter (a: !a.assertion) config.assertions);
          own = builtins.filter (lib.hasPrefix "proxy-suite:") (failed ++ config.warnings);
        in
        if !builtins.elem snippet.file committed || builtins.readFile path != snippet.text then
          [ "${snippet.where}: ${usageSnippets.dir}/${snippet.file} ${outdated}" ]
        else
          builtins.addErrorContext "while evaluating ${snippet.where}" (
            builtins.deepSeq (visibleValues eval.options.services.proxy-suite config.services.proxy-suite) (
              map (message: "${snippet.where}: ${message}") own
            )
          );
      leftover = map (file: "${usageSnippets.dir}/${file}: no nix block for it, ${outdated}") (
        lib.subtractLists (map (snippet: snippet.file) snippets) committed
      );

      # [text](target) and [text](target#anchor), except absolute URLs.
      links =
        text:
        builtins.filter (link: !lib.hasInfix "://" (builtins.head link)) (
          builtins.filter builtins.isList (builtins.split "]\\(([^)#]*)(#[^)]*)?\\)" text)
        );
      linkProblems =
        name:
        lib.concatMap (
          link:
          let
            target = builtins.head link;
            anchor = builtins.elemAt link 1;
            path = if target == "" then usageDir + "/${name}" else usageDir + "/${dirOf name}/${target}";
            where = "docs/usage/${name}: ${target}${if anchor == null then "" else anchor}";
          in
          if !builtins.pathExists path then
            [ "${where}: no such file" ]
          else if
            anchor != null && !lib.hasInfix "<a id=\"${lib.removePrefix "#" anchor}\">" (builtins.readFile path)
          then
            [ "${where}: no such anchor" ]
          else
            [ ]
        ) (links (guideText name));

      problems = leftover ++ lib.concatMap snippetProblems snippets ++ lib.concatMap linkProblems guides;
    in
    pkgs.runCommand "proxy-suite-usage-docs-check" { } (
      if problems == [ ] then
        ''touch "$out"''
      else
        ''
          printf '%s\n' ${lib.escapeShellArgs problems} >&2
          exit 1
        ''
    );

  # The tree as `nix fmt` leaves it; the generated usage snippets are left as written.
  nix-format =
    pkgs.runCommand "proxy-suite-nix-format-check" { nativeBuildInputs = [ pkgs.nixfmt ]; }
      ''
        cd ${
          pkgs.lib.fileset.toSource {
            root = ../..;
            fileset = pkgs.lib.fileset.difference (pkgs.lib.fileset.fileFilter (
              file: file.hasExt "nix"
            ) ../..) (pkgs.lib.fileset.maybeMissing ../../docs/usage/.snippets);
          }
        }
        find . -name '*.nix' -print0 | xargs -0 nixfmt --check
        touch "$out"
      '';

  # Pyflakes and bugbear over every script and front end, as ruff.toml configures them.
  python-lint =
    pkgs.runCommand "proxy-suite-python-lint-check" { nativeBuildInputs = [ pkgs.ruff ]; }
      ''
        cd ${
          pkgs.lib.fileset.toSource {
            root = ../..;
            fileset = pkgs.lib.fileset.unions [
              ../../ruff.toml
              (pkgs.lib.fileset.fileFilter (file: file.hasExt "py") ../..)
            ];
          }
        }
        ruff check --no-cache .
        touch "$out"
      '';

  proxy-ctl-subscription-list =
    pkgs.runCommand "proxy-suite-proxy-ctl-subscription-list-check"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.coreutils
          pkgs.gawk
          pkgs.jq
        ];
      }
      ''
        proxy_ctl=${../../pkgs/proxy-ctl/proxy_ctl.py}

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
          ${perAppRoutingOff}          python3 "$proxy_ctl" proxy subs list > output
        # The old spelling still dispatches.
        env SUB_TAGS_FILE="$PWD/tags.json" SUB_CACHE_DIR="$PWD/cache" \
          python3 "$proxy_ctl" subscription list | cmp - output

        awk '$1 == "plain" { found = 1; if ($NF != "2") exit 1 } END { exit found ? 0 : 1 }' output
        awk '$1 == "hybrid" { found = 1; if ($NF != "3") exit 1 } END { exit found ? 0 : 1 }' output
        awk '$1 == "bad" { found = 1; if ($NF != "?") exit 1 } END { exit found ? 0 : 1 }' output

        touch "$out"
      '';

  proxy-ctl-outbounds =
    pkgs.runCommand "proxy-suite-proxy-ctl-outbounds-check"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.coreutils
          pkgs.curl
          pkgs.gawk
          pkgs.gnugrep
          pkgs.jq
        ];
      }
      (
        fillTemplate ./repo/proxy-ctl-outbounds.template.sh {
          proxyCtl = ../../pkgs/proxy-ctl/proxy_ctl.py;
          inherit perAppRoutingOff;
        }
      );

  proxy-ctl-zapret-auto =
    pkgs.runCommand "proxy-suite-proxy-ctl-zapret-auto-check"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.coreutils
          pkgs.gawk
          pkgs.gnugrep
        ];
      }
      (
        fillTemplate ./repo/proxy-ctl-zapret-auto.template.sh {
          proxyCtl = ../../pkgs/proxy-ctl/proxy_ctl.py;
        }
      );

  proxy-ctl-complete =
    pkgs.runCommand "proxy-suite-proxy-ctl-complete-check"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.coreutils
          pkgs.gawk
          pkgs.gnugrep
          pkgs.jq
        ];
      }
      (
        fillTemplate ./repo/proxy-ctl-complete.template.sh {
          proxyCtl = ../../pkgs/proxy-ctl/proxy_ctl.py;
          bashCompletion = ../../pkgs/proxy-ctl/completions/proxy-ctl.bash;
          zsh = pkgs.zsh;
          zshCompletion = ../../pkgs/proxy-ctl/completions/_proxy-ctl;
          fish = pkgs.fish;
          fishCompletion = ../../pkgs/proxy-ctl/completions/proxy-ctl.fish;
        }
      );

  proxy-ctl-where =
    pkgs.runCommand "proxy-suite-proxy-ctl-where-check"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.jq
        ];
      }
      (fillTemplate ./repo/proxy-ctl-where.template.sh { proxyCtl = ../../pkgs/proxy-ctl/proxy_ctl.py; });

  # autoProxy slowness routing: sampler and judge.
  autoproxy-slowness =
    pkgs.runCommand "proxy-suite-autoproxy-slowness-check" { nativeBuildInputs = [ pkgs.jq ]; }
      (
        fillTemplate ./repo/autoproxy-slowness.template.sh {
          slowSampleJq = ../../modules/proxy-suite/autoproxy-slow-sample.jq;
          slowJudgeJq = ../../modules/proxy-suite/autoproxy-slow-judge.jq;
        }
      );

  # autoProxy probe order: one exit per network first, bad exits last; and the
  # strikes that make an exit bad.
  autoproxy-rounds =
    pkgs.runCommand "proxy-suite-autoproxy-rounds-check" { nativeBuildInputs = [ pkgs.jq ]; }
      (
        fillTemplate ./repo/autoproxy-rounds.template.sh {
          roundsJq = ../../modules/proxy-suite/autoproxy-rounds.jq;
          strikeJq = ../../modules/proxy-suite/autoproxy-strike.jq;
        }
      );

  # `proxy-ctl proxy auto forget|clear`, as the runner applies them.
  autoproxy-edit =
    pkgs.runCommand "proxy-suite-autoproxy-edit-check"
      {
        nativeBuildInputs = [ pkgs.jq ];
      }
      (
        fillTemplate ./repo/autoproxy-edit.template.sh {
          editJq = ../../modules/proxy-suite/autoproxy-edit.jq;
        }
      );

  # A probe that exits 0 printing nothing: jq reads "" as no input at all, so the
  # "error" guard downstream saw "" instead of "error" and let it through to
  # `--argjson r ""`, which failed every autoProxy run until the state changed.
  # The helper is taken from the module, so it is the code the runner really uses.
  autoproxy-probe-json =
    pkgs.runCommand "proxy-suite-autoproxy-probe-json-check"
      {
        nativeBuildInputs = [
          pkgs.jq
          pkgs.gnused
          pkgs.coreutils
        ];
      }
      ''
        sed -n '/^probe_json() {$/,/^}$/p' ${../../modules/proxy-suite/autoproxy-run.template.sh} > helper.sh
        test -s helper.sh

        mkdir -p stub
        printf '%s\n' '#!/bin/sh' 'exit 0' > stub/proxy-ctl
        chmod +x stub/proxy-ctl
        export PATH="$PWD/stub:$PATH"

        set -euo pipefail
        . ./helper.sh
        # $out is the derivation's; the helper's own "out" is local to it.
        res=$(probe_json --exits direct example.test)
        test "$res" = '{}'
        # What the callers ask, and what used to come back empty.
        test "$(jq -r '.verdict // "error"' <<<"$res")" = error
        # And an update() built from it still runs.
        jq -e -n --argjson r "$res" '$r == {}' > /dev/null

        touch "$out"
      '';

  # Per-user inbound traffic collection; `proxy-ctl inbounds stats` is in proxy-ctl-unit.
  inbound-stats =
    pkgs.runCommand "proxy-suite-inbound-stats-check"
      {
        nativeBuildInputs = [ pkgs.jq ];
      }
      (
        fillTemplate ./repo/inbound-stats.template.sh {
          statsAddJq = ../../modules/proxy-suite/inbound-stats-add.jq;
        }
      );

  # Proxy chains, resolved at start once subscription entries exist.
  outbound-detours =
    pkgs.runCommand "proxy-suite-outbound-detours-check"
      {
        nativeBuildInputs = [ pkgs.jq ];
      }
      (
        fillTemplate ./repo/outbound-detours.template.sh {
          detoursJq = ../../modules/proxy-suite/outbound-detours.jq;
        }
      );

  # `proxy-ctl proxy outbounds disable` markers, as the start script reads them.
  outbound-disabled =
    let
      mkSelection =
        groups:
        let
          inherit (outboundScriptBlocks groups) selectionBlocks;
        in
        pkgs.writeShellScript "outbound-selection" ''
          set -euo pipefail
          ${selectionBlocks}
        '';
      selection = mkSelection { };
      # Resolved at start as the runtime ones are; `g` holds b and a, in that order.
      grouped = mkSelection {
        g = {
          outbounds = [
            "b"
            "a"
          ];
          subscriptions = [ ];
          match = [ ];
          strategy = "failover";
          failback = true;
          interval = null;
        };
      };
    in
    pkgs.runCommand "proxy-suite-outbound-disabled-check" { nativeBuildInputs = [ pkgs.jq ]; } (
      fillTemplate ./repo/outbound-disabled.template.sh {
        inherit grouped selection;
      }
    );

  # The spool is group-writable and the backend privileged: a runtime JSON outbound naming a program
  # or a file to read or write is left out, and a runtime AmneziaWG port must be a port.
  runtime-outbound-spool =
    let
      loadRuntime = pkgs.writeShellScript "runtime-outbounds" ''
        set -euo pipefail
        OUTBOUNDS_JSON='[]'
        ${(outboundScriptBlocks { }).runtimeOutboundBlocks}
        printf '%s' "$OUTBOUNDS_JSON" > outbounds.json
      '';
    in
    pkgs.runCommand "proxy-suite-runtime-outbound-spool-check" { nativeBuildInputs = [ pkgs.jq ]; } ''
      mkdir obd
      echo '{"type": "socks", "server": "127.0.0.1", "server_port": 1080}' > obd/ok.json
      echo '{"type": "vless", "server": "h", "transport": {"type": "ws", "path": "/x"}}' > obd/ws.json
      echo '{"type": "tor", "executable_path": "/tmp/x"}' > obd/tor.json
      echo '{"type": "ssh", "server": "h", "private_key_path": "/root/.ssh/id_ed25519"}' > obd/ssh.json
      echo '{"type": "vless", "server": "h", "tls": {"enabled": true, "certificate_path": "/etc/shadow"}}' > obd/cert.json
      ${loadRuntime} 2> err
      cat err
      jq -e '[.[].tag] == ["ok", "ws"]' outbounds.json > /dev/null
      grep -q "runtime outbound 'tor' names local files or programs (executable_path, type: tor)" err
      grep -q "runtime outbound 'ssh' names local files or programs (private_key_path)" err
      grep -q "runtime outbound 'cert' names local files or programs (certificate_path)" err
      touch "$out"
    '';

  proxy-ctl-amneziawg =
    pkgs.runCommand "proxy-suite-proxy-ctl-amneziawg-check"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.jq
        ];
      }
      (
        fillTemplate ./repo/proxy-ctl-amneziawg.template.sh {
          proxyCtl = ../../pkgs/proxy-ctl/proxy_ctl.py;
          bash = pkgs.bash;
        }
      );

  readme-doc-source = builtins.seq (
    assert !(pkgs.lib.hasInfix "environment.systemPackages" readmeDocSource);
    assert !(pkgs.lib.hasInfix "packageByPattern" readmeDocSource);
    true
  ) (pkgs.writeText "proxy-suite-readme-doc-source-check" "ok");

  package-source = builtins.seq (
    assert !(pkgs.lib.hasInfix "../../pkgs/tg-ws-proxy.nix" tgWsProxyModuleSource);
    assert !(pkgs.lib.hasInfix "../../../pkgs/proxy-ctl.nix" controlModuleSource);
    true
  ) (pkgs.writeText "proxy-suite-package-source-check" "ok");
}
