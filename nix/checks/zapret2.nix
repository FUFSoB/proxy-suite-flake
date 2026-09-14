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
    zapret2Z2k
    zapret2NoFallback
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

  globalService = "proxy-suite-zapret";
  perAppService = "proxy-suite-per-app-zapret";

  zapretBase = fixture: envValue fixture globalService "ZAPRET_BASE=";
  runtimeDir = fixture: serviceName: envValue fixture serviceName "ZAPRET_RW=";

  globalRuntime = runtimeDir zapret2Global globalService;
  perAppGlobalRuntime = runtimeDir zapret2PerApp globalService;
  perAppRuntime = runtimeDir zapret2PerApp perAppService;
  tunedRuntime = runtimeDir zapret2Tuned globalService;
  noAutoRuntime = runtimeDir zapret2NoAuto globalService;
  z2kRuntime = runtimeDir zapret2Z2k globalService;
  cutoffProbe = zapret2Global.config.systemd.services.proxy-suite-zapret2-cutoff.serviceConfig.ExecStart;
  socksStart = fixture: fixture.config.systemd.services.proxy-suite-socks.serviceConfig.ExecStart;

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
      assert
        envValue zapret2PerApp perAppService "Z2K_STATE_DIR_OVERRIDE=" == "/var/lib/proxy-suite/zapret2/circular";
      true
    )

    # Two nfqws2 processes must not share a pidfile or a config.
    (
      assert envValue zapret2PerApp globalService "PIDDIR=" == "/run/proxy-suite-zapret";
      assert envValue zapret2PerApp perAppService "PIDDIR=" == "/run/proxy-suite-per-app-zapret";
      assert perAppGlobalRuntime != perAppRuntime;
      true
    )

    # The cutoff probe comes with zapret2, on a timer, and nfqws2 reads its maps.
    (
      assert zapret2Global.config.systemd.timers ? proxy-suite-zapret2-cutoff;
      assert !(zapretDiscordYoutubeGlobal.config.systemd.services ? proxy-suite-zapret2-cutoff);
      assert (proxyCtlEnv zapret2Global).ZAPRET_CUTOFF_ENABLED == "1";
      assert
        envValue zapret2Global globalService "Z2K_TCP16_ASN=" == "/var/lib/proxy-suite/zapret2/cutoff/asn.txt";
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
        nativeBuildInputs = [
          pkgs.gnugrep
          pkgs.lua
        ];
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

        # --- strategy sources -----------------------------------------------
        # nfqws2-keenetic by default; every source remembers strategies across restarts.
        grep -qx 'NFQWS2_PORTS_TCP=80,443,1984,2053,2083,2087,2096,5222,8443' "${globalRuntime}/config"
        grep -qx 'NFQWS2_PORTS_UDP=443,590-600,1400,3478-3481,5349,19294-19344,49152-65535' "${globalRuntime}/config"
        grep -qF -- '/files/lua/z2k-state-persist.lua' "${globalRuntime}/config"
        # Counted failures are stamped before the state layer reads them, so a
        # success on a busy host cannot undo every rotation.
        grep -qE -- 'fail-stamp\.lua --lua-init=@[^ ]+/z2k-state-persist\.lua' "${globalRuntime}/config"
        STAMP=$(grep -oE '/nix/store/[^ ]+-proxy-suite-zapret2-fail-stamp\.lua' "${globalRuntime}/config") lua -e '
          function automate_failure_counter(hrec, crec) if crec then crec.failure = true end return "orig" end
          function clock_getfloattime() return 42.5 end
          dofile(os.getenv("STAMP"))
          local hrec, crec = {}, {}
          assert(automate_failure_counter(hrec, crec, 2, 60) == "orig" and hrec.z2k_last_fail_ts == 42.5)
          hrec.z2k_last_fail_ts = 1
          automate_failure_counter(hrec, crec, 2, 60)
          assert(hrec.z2k_last_fail_ts == 1, "a duplicate failure is not counted, so not stamped")
        '
        # Every UDP fake carries a blob; zapret2 errors on each packet otherwise.
        grep -qF -- '--lua-desync=fake:blob=0x0000' "${globalRuntime}/config"
        if grep -qF -- '--lua-desync=fake:repeats=' "${globalRuntime}/config"; then exit 1; fi
        # autoHostlist fills what circular leaves unset; the source keeps its fails and time.
        grep -qF -- '--lua-desync=circular:fails=2:time=300:retrans=3:nld=2:maxseq=32768:inseq=4096:udp_out=4:udp_in=1:reset ' "${globalRuntime}/config"

        # z2k: its generator's pools, detectors and fake TTL; only the general profile learns.
        grep -qx 'NFQWS2_TCP_PKT_OUT=20' "${z2kRuntime}/config"
        grep -qx 'NFQWS2_UDP_PKT_IN=8' "${z2kRuntime}/config"
        grep -qx 'NFQWS2_PORTS_UDP=443,50000-50099,1400,3478-3481,5349,19294-19344' "${z2kRuntime}/config"
        grep -qF -- 'key=rkn_tcp:nld=2:failure_detector=z2k_fail_tls_alert:retrans=3:maxseq=32768:inseq=4096:udp_out=4:udp_in=1:reset' "${z2kRuntime}/config"
        grep -qF -- 'failure_detector=z2k_fail_quic_silence' "${z2kRuntime}/config"
        grep -qF -- ':fool=z2k_dynamic_ttl' "${z2kRuntime}/config"
        grep -qF -- '/extra_strats/TCP_Discord.txt <HOSTLIST> ' "${z2kRuntime}/config"
        test "$(grep -oF -- '<HOSTLIST>' "${z2kRuntime}/config" | wc -l)" = 1
        grep -qF -- '/lists/whitelist.txt --hostlist-exclude=/var/lib/proxy-suite/zapret2/zapret-hosts-user-exclude.txt' "${z2kRuntime}/config"

        # --- 16 KB cutoff ---------------------------------------------------
        # The whitelisted-name step runs ahead of rotation, in both sources.
        grep -qF -- '/files/lua/z2k-tcp16.lua' "${globalRuntime}/config"
        grep -qF -- 'blob=z2k_ch:optional:repeats=8:tcp_ts=-1000 --lua-desync=circular:fails=2:time=300' "${globalRuntime}/config"
        grep -qF -- 'blob=z2k_ch:optional:repeats=8:tcp_ts=-1000 --lua-desync=circular:fails=3:time=60:key=rkn_tcp' "${z2kRuntime}/config"
        # zapret2 leaves the probe's own connections alone, in every chain.
        test "$(grep -c 'ct mark and 0x2000000 != 0 return' "${globalRuntime}/init.d/sysv/custom.d/50-proxy-suite-custom.sh")" = 4

        # Cut-off networks without a name become the proxy's rule-set; named ones stay with zapret2.
        rules=$(grep -oE '/nix/store/[^ ]+-proxy-suite-zapret2 asn.txt' ${cutoffProbe} | cut -d' ' -f1)
        printf '# networks\n24940\n14061\n' >asn.txt
        printf '24940\t300.ya.ru\n' >sni.txt
        printf '# map\n24940\t5.9.0.0/16\n14061\t104.131.0.0/16\n14061\t2604:a880::/32\n7777\t1.2.0.0/16\n' >nets.txt
        test "$("$rules" asn.txt sni.txt nets.txt)" = '{"version":1,"rules":[{"ip_cidr":["104.131.0.0/16","2604:a880::/32"]}]}'
        printf '24940\t300.ya.ru\n14061\tad.adriver.ru\n' >sni.txt
        test "$("$rules" asn.txt sni.txt nets.txt)" = '{"version":1,"rules":[]}'

        # The probe is built from z2k's source and knows its tcp16 mode.
        detect=$(grep -o '/nix/store/[^:]*-z2k-detect-[^:/]*/bin' ${cutoffProbe} | head -n1)
        "$detect/z2k-detect" tcp16 -h 2>/dev/null

        # New maps restart only the zapret units this config installs.
        grep -qF 'try-restart proxy-suite-zapret.service' ${cutoffProbe}
        if grep -qF 'proxy-suite-per-app-zapret.service' ${cutoffProbe}; then exit 1; fi

        # The proxy carries what no name fixes, unless the fallback is off.
        grep -qF 'tag: "zapret-cutoff"' ${socksStart zapret2Global}
        if grep -qF 'zapret-cutoff' ${socksStart zapret2NoFallback}; then exit 1; fi

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
        # Expand <HOSTLIST> with zapret2's list.sh and let nfqws2 validate the result,
        # Lua included; the strategy state layer gets a writable directory.
        export HOSTLIST_BASE="$PWD/lists"
        export ZAPRET_BASE="$base"
        export Z2K_STATE_DIR_OVERRIDE="$PWD/circular"
        mkdir -p "$HOSTLIST_BASE" "$Z2K_STATE_DIR_OVERRIDE"
        touch "$HOSTLIST_BASE/zapret-hosts-auto.txt" \
              "$HOSTLIST_BASE/zapret-hosts-user.txt" \
              "$HOSTLIST_BASE/zapret-hosts-user-exclude.txt"

        dry_run() (
          . "$1/config"
          . "$base/common/base.sh"
          . "$base/common/list.sh"

          opt="--qnum=$QNUM $NFQWS2_OPT"
          filter_apply_hostlist_target opt
          # The service creates its state files; here they live in the sandbox.
          opt=$(printf '%s' "$opt" | sed "s|/var/lib/proxy-suite/zapret2/|$HOSTLIST_BASE/|g")
          printf '%s\n' "$opt" | tr ' ' '\n' >"$2"

          # --user is deliberately omitted: the sandbox is not root.
          "$base/nfq2/nfqws2" --dry-run --fwmark="$DESYNC_MARK" \
            --lua-init=@"$base/lua/zapret-lib.lua" \
            --lua-init=@"$base/lua/zapret-antidpi.lua" \
            --lua-init=@"$base/lua/zapret-auto.lua" \
            $opt
        )

        dry_run ${globalRuntime} global.args
        grep -qx -- "--hostlist-auto=$HOSTLIST_BASE/zapret-hosts-auto.txt" global.args
        grep -qx -- '--hostlist-auto-fail-threshold=3' global.args
        grep -qx -- '--hostlist-auto-fail-time=300' global.args

        dry_run ${z2kRuntime} z2k.args
        test "$(grep -cx -- "--hostlist-auto=$HOSTLIST_BASE/zapret-hosts-auto.txt" z2k.args)" = 1

        touch "$out"
      '';
}
