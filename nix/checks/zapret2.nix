{
  pkgs,
  evalProxySuite,
  baseModule,
  mkProxyCtlDerived,
  mkBadFixture,
  mkFailingAssertions,
}:

let
  inherit (pkgs) lib;

  fixtures = import ./zapret2/fixtures.nix { inherit evalProxySuite baseModule; };
  inherit (fixtures)
    zapretDiscordYoutubeGlobal
    zapret2Global
    zapret2PerApp
    zapret2Tuned
    zapret2NoAuto
    ;

  envValue =
    fixture: serviceName: prefix:
    lib.removePrefix prefix (
      builtins.head (
        builtins.filter (
          value: lib.hasPrefix prefix value
        ) fixture.config.systemd.services.${serviceName}.serviceConfig.Environment
      )
    );

  globalService = "zapret-discord-youtube";
  perAppService = "proxy-suite-per-app-zapret";

  zapretBase = fixture: envValue fixture globalService "ZAPRET_BASE=";
  runtimeDir = fixture: serviceName: envValue fixture serviceName "ZAPRET_RW=";

  globalRuntime = runtimeDir zapret2Global globalService;
  perAppGlobalRuntime = runtimeDir zapret2PerApp globalService;
  perAppRuntime = runtimeDir zapret2PerApp perAppService;
  tunedRuntime = runtimeDir zapret2Tuned globalService;
  noAutoRuntime = runtimeDir zapret2NoAuto globalService;

  proxyCtlEnv = fixture: (mkProxyCtlDerived fixture).wrapperEnv;
in
{
  assertions = [
    # The engine changes the implementation, not the unit names.
    (
      assert lib.hasInfix "zapret2" (zapretBase zapret2Global);
      assert !(lib.hasInfix "zapret2" (zapretBase zapretDiscordYoutubeGlobal));
      assert zapret2Global.config.systemd.services ? ${globalService};
      assert !(zapret2Global.config.systemd.services ? ${perAppService});
      true
    )

    # Both instances share the state directory.
    (
      assert envValue zapret2Global globalService "HOSTLIST_BASE=" == "/var/lib/proxy-suite/zapret2";
      assert
        zapret2Global.config.systemd.services.${globalService}.serviceConfig.StateDirectory
        == "proxy-suite";
      assert envValue zapret2PerApp perAppService "HOSTLIST_BASE=" == "/var/lib/proxy-suite/zapret2";
      true
    )

    # Two nfqws2 processes must not share a pidfile or a config.
    (
      assert envValue zapret2PerApp globalService "PIDDIR=" == "/run/proxy-suite-zapret";
      assert envValue zapret2PerApp perAppService "PIDDIR=" == "/run/proxy-suite-per-app-zapret";
      assert perAppGlobalRuntime != perAppRuntime;
      true
    )

    # `proxy-ctl zapret auto` only makes sense when something is learning.
    (
      assert (proxyCtlEnv zapret2Global).ZAPRET_AUTO_ENABLED == "1";
      assert (proxyCtlEnv zapretDiscordYoutubeGlobal).ZAPRET_AUTO_ENABLED == "0";
      assert (proxyCtlEnv zapret2Global).ZAPRET_STATE_DIR == "/var/lib/proxy-suite/zapret2";
      true
    )
  ];

  runtime =
    pkgs.runCommand "proxy-suite-zapret2-config-check"
      {
        nativeBuildInputs = [ pkgs.gnugrep ];
      }
      ''
        base=${zapretBase zapret2Global}

        # --- generated config -------------------------------------------------
        grep -qx 'MODE_FILTER=autohostlist' "${globalRuntime}/config"
        grep -qx 'AUTOHOSTLIST_FAIL_THRESHOLD=3' "${globalRuntime}/config"
        grep -qx 'AUTOHOSTLIST_FAIL_TIME=300' "${globalRuntime}/config"
        grep -qx 'AUTOHOSTLIST_RETRANS_THRESHOLD=3' "${globalRuntime}/config"
        grep -qx 'QNUM=300' "${globalRuntime}/config"
        grep -qx 'FWTYPE=nftables' "${globalRuntime}/config"
        grep -qx 'WS_USER=root' "${globalRuntime}/config"
        grep -qx 'DISABLE_IPV6=1' "${globalRuntime}/config"

        # The NFQUEUE window must exceed the retransmission threshold.
        grep -qx 'NFQWS2_TCP_PKT_OUT=9' "${globalRuntime}/config"
        grep -qx 'NFQWS2_TCP_PKT_IN=15' "${globalRuntime}/config"

        # Learning off means list mode, not "no lists".
        grep -qx 'MODE_FILTER=hostlist' "${noAutoRuntime}/config"

        # Tuned knobs reach the config, including the wider packet window.
        grep -qx 'AUTOHOSTLIST_FAIL_THRESHOLD=5' "${tunedRuntime}/config"
        grep -qx 'AUTOHOSTLIST_FAIL_TIME=120' "${tunedRuntime}/config"
        grep -qx 'AUTOHOSTLIST_DEBUGLOG=1' "${tunedRuntime}/config"
        grep -qx 'NFQWS2_TCP_PKT_OUT=10' "${tunedRuntime}/config"

        # Static filters only on hostlist profiles; the UDP profile stays list-free.
        grep -qF -- '<HOSTLIST> --hostlist-domains=pinned.example --hostlist-exclude-domains=excluded.example' "${tunedRuntime}/config"
        grep -qF -- '<HOSTLIST_NOAUTO> --hostlist-domains=pinned.example --hostlist-exclude-domains=excluded.example' "${tunedRuntime}/config"
        test "$(grep -oF -- '--hostlist-domains=pinned.example' "${tunedRuntime}/config" | wc -l)" = 2

        # --- per-app instance -------------------------------------------------
        # Wrapped apps opted in explicitly, so no hostlist gates them.
        grep -qx 'MODE_FILTER=none' "${perAppRuntime}/config"
        grep -qx 'FILTER_MARK=0x10000000' "${perAppRuntime}/config"
        grep -qx 'QNUM=201' "${perAppRuntime}/config"
        grep -qx 'DESYNC_MARK=0x8000000' "${perAppRuntime}/config"
        grep -qx 'DESYNC_MARK_POSTNAT=0x4000000' "${perAppRuntime}/config"
        grep -qx 'ZAPRET_NFT_TABLE=proxy_suite_per_app_zapret' "${perAppRuntime}/config"

        # The global instance must keep its hands off per-app traffic.
        hook="${perAppGlobalRuntime}/init.d/sysv/custom.d/50-proxy-suite-custom.sh"
        test "$(grep -c 'mark and 0x10000000 != 0 return' "$hook")" = 4
        grep -q 'nft insert rule inet $ZAPRET_NFT_TABLE prenat mark and 0x10000000 != 0 return' "$hook"

        # --- the command line nfqws2 receives ---
        # Expand <HOSTLIST> with zapret2's list.sh and let nfqws2 validate the result.
        export HOSTLIST_BASE="$PWD/lists"
        export ZAPRET_BASE="$base"
        mkdir -p "$HOSTLIST_BASE"
        touch "$HOSTLIST_BASE/zapret-hosts-auto.txt" \
              "$HOSTLIST_BASE/zapret-hosts-user.txt" \
              "$HOSTLIST_BASE/zapret-hosts-user-exclude.txt"

        . "${globalRuntime}/config"
        . "$base/common/base.sh"
        . "$base/common/list.sh"

        opt="--qnum=$QNUM $NFQWS2_OPT"
        filter_apply_hostlist_target opt

        printf '%s\n' "$opt" | tr ' ' '\n' | grep -qx -- "--hostlist-auto=$HOSTLIST_BASE/zapret-hosts-auto.txt"
        printf '%s\n' "$opt" | tr ' ' '\n' | grep -qx -- '--hostlist-auto-fail-threshold=3'
        printf '%s\n' "$opt" | tr ' ' '\n' | grep -qx -- '--hostlist-auto-fail-time=300'

        # --user is deliberately omitted: the sandbox is not root.
        "$base/nfq2/nfqws2" --dry-run --fwmark="$DESYNC_MARK" \
          --lua-init=@"$base/lua/zapret-lib.lua" \
          --lua-init=@"$base/lua/zapret-antidpi.lua" \
          --lua-init=@"$base/lua/zapret-auto.lua" \
          $opt

        touch "$out"
      '';
}
