{
  pkgs,
  evalProxySuite,
  baseModule,
  mkRoutingRules,
  hasDirectDomain,
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
    zapret2Z2kTuned
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
  z2kTunedRuntime = runtimeDir zapret2Z2kTuned globalService;
  daemonStart = zapret2Global.config.systemd.services.${globalService}.serviceConfig.ExecStart;
  cutoffProbe =
    zapret2Global.config.systemd.services.proxy-suite-zapret2-cutoff.serviceConfig.ExecStart;
  socksStart = fixture: fixture.config.systemd.services.proxy-suite-socks.serviceConfig.ExecStart;
  directSync = builtins.head (
    lib.splitString " " zapret2Global.config.systemd.services.proxy-suite-zapret2-direct.serviceConfig.ExecStart
  );

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
        == "proxy-suite/zapret2";
      assert envValue zapret2PerApp perAppService "HOSTLIST_BASE=" == "/var/lib/proxy-suite/zapret2";
      assert
        envValue zapret2PerApp perAppService "Z2K_STATE_DIR_OVERRIDE="
        == "/var/lib/proxy-suite/zapret2/circular";
      true
    )

    # Root works in directories the zapret scope's group writes to: nfqws2 and the cutoff
    # probe write nowhere else, whatever a name there points at. The probe's own directory
    # is root's alone, apart from requests/.
    (
      let
        gc = zapret2Global.config.systemd.services.${globalService}.serviceConfig;
        pc = zapret2PerApp.config.systemd.services.${perAppService}.serviceConfig;
        cc = zapret2Global.config.systemd.services.proxy-suite-zapret2-cutoff.serviceConfig;
        sandboxed = c: c.ProtectSystem == "strict" && c.ProtectHome && c.PrivateTmp;
      in
      assert sandboxed gc && sandboxed pc && sandboxed cc;
      assert cc.StateDirectory == "proxy-suite/zapret2-cutoff" && cc.StateDirectoryMode == "0755";
      assert !(cc ? Group);
      assert builtins.any (lib.hasPrefix "d /var/lib/proxy-suite/zapret2-cutoff/requests ")
        zapret2Global.config.systemd.tmpfiles.rules;
      true
    )

    # Two nfqws2 processes must not share a pidfile or a config.
    (
      assert envValue zapret2PerApp globalService "PIDDIR=" == "/run/proxy-suite-zapret";
      assert envValue zapret2PerApp perAppService "PIDDIR=" == "/run/proxy-suite-per-app-zapret";
      assert perAppGlobalRuntime != perAppRuntime;
      true
    )

    # nfqws2 is the unit's supervised main process: if it dies, systemd sees it and
    # restarts it, instead of a oneshot staying active while the queue bypasses it.
    (
      let
        sc = zapret2PerApp.config.systemd.services.${perAppService}.serviceConfig;
        gc = zapret2Global.config.systemd.services.${globalService}.serviceConfig;
      in
      assert gc.Type == "notify" && sc.Type == "notify";
      assert gc.Restart == "on-failure" && sc.Restart == "on-failure";
      assert lib.hasSuffix "stop_fw" gc.ExecStopPost;
      assert builtins.length sc.ExecStopPost == 2;
      true
    )

    # The cutoff probe comes with zapret2, on a timer; z2k's nfqws2 reads its maps.
    (
      assert zapret2Global.config.systemd.timers ? proxy-suite-zapret2-cutoff;
      assert !(zapretDiscordYoutubeGlobal.config.systemd.services ? proxy-suite-zapret2-cutoff);
      assert (proxyCtlEnv zapret2Global).ZAPRET_CUTOFF_ENABLED == "1";
      assert
        envValue zapret2Z2k globalService "Z2K_TCP16_ASN=" == "/var/lib/proxy-suite/zapret2-cutoff/asn.txt";
      assert
        !(builtins.any (lib.hasPrefix "Z2K_TCP16_ASN=")
          zapret2Global.config.systemd.services.${globalService}.serviceConfig.Environment
        );
      true
    )

    # directSync sends zapret2's pinned domains direct, so zapret2 sees them; its excludes stay out.
    (
      let
        rules = mkRoutingRules zapret2Tuned;
      in
      assert hasDirectDomain rules "pinned.example";
      assert !(hasDirectDomain rules "excluded.example");
      assert !(hasDirectDomain (mkRoutingRules zapretDiscordYoutubeGlobal) "pinned.example");
      true
    )

    # The hosts zapret2 pins and learns at runtime are synced too, whenever a list changes.
    (
      assert zapret2Global.config.systemd.paths ? proxy-suite-zapret2-direct;
      assert
        zapret2Global.config.systemd.services.proxy-suite-zapret2-direct.serviceConfig.StateDirectoryMode
        == "0755";
      assert !(zapretDiscordYoutubeGlobal.config.systemd.services ? proxy-suite-zapret2-direct);
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
          pkgs.jq
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
        # Wider with detect.lua learning, to see a transfer stall past the 16 KB cutoff.
        grep -qx 'NFQWS2_TCP_PKT_IN=32' "${globalRuntime}/config"
        grep -qx 'NFQWS2_TCP_PKT_IN=15' "${tunedRuntime}/config"

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

        # Extra ports join every profile that tells its traffic by protocol, and the
        # queue, merged with what overlaps.
        grep -qF -- '--filter-tcp=443,80,1984,5222,8444 --filter-l7=http,tls,mtproto' "${tunedRuntime}/config"
        grep -qF -- '--filter-udp=443,27015-27030,50000-50100 --filter-l7=quic' "${tunedRuntime}/config"
        grep -qx 'NFQWS2_PORTS_TCP=80,443,1984,2053,2083,2087,2096,5222,8443-8444' "${tunedRuntime}/config"
        grep -qx 'NFQWS2_PORTS_UDP=443,590-600,1400,3478-3481,5349,19294-19344,27015-27030,49152-65535' "${tunedRuntime}/config"
        # A profile that does not check the protocol keeps its ports: on 5222 it splits anything.
        grep -qF -- '--filter-tcp=5222 --payload=unknown' "${z2kTunedRuntime}/config"
        grep -qF -- '--filter-tcp=80 ' "${z2kTunedRuntime}/config"
        grep -qF -- ' --new --filter-tcp=443,2053,2083,2087,2096,8443,8444 --filter-l7=tls ' "${z2kTunedRuntime}/config"

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
        # Every new host or switch reaches state.tsv, or a restart loses it; a z2k bump
        # that drops the setter must fail the start, not quietly lose switches again.
        grep -qE -- 'z2k-state-persist\.lua --lua-init=@[^ ]+-persist-every\.lua --lua-init=@[^ ]+-detect\.lua --lua-init=@[^ ]+-strategy-log\.lua' "${z2kRuntime}/config"
        EVERY=$(grep -oE '/nix/store/[^ ]+-persist-every\.lua' "${globalRuntime}/config") lua -e '
          local set, flushed, now = nil, 0, 1000
          local state = { rkn_tcp = { ["example.com"] = { strategy = 1 } } }
          z2k_state_persist = {
            _set_interval = function(n) set = n end,
            _state = function() return state end,
            flush = function() flushed = flushed + 1 end,
          }
          os.time = function() return now end
          function circular() return "verdict" end
          dofile(os.getenv("EVERY"))
          assert(set == 0)
          -- A switch whose write was skipped is written within a minute; no change, no write.
          state.rkn_tcp["example.com"].strategy = 2
          assert(circular() == "verdict" and flushed == 0)
          now = now + 60
          circular()
          assert(flushed == 1)
          now = now + 60
          circular()
          assert(flushed == 1)
          z2k_state_persist = { _set_interval = function() end }
          assert(not pcall(dofile, os.getenv("EVERY")))
        '
        # nld counts from the public suffix, so sites under co.uk no longer share a strategy;
        # the private section (github.io) stays one site, as before.
        PSL=$(grep -oE '/nix/store/[^ ]+-proxy-suite-zapret2-public-suffix-hostkey\.lua' "${z2kRuntime}/config") lua -e '
          function standard_hostkey() return "standard" end
          dofile(os.getenv("PSL"))
          local function key(host, nld, ip)
            return standard_hostkey({ arg = { nld = nld }, track = { hostname = host, hostname_is_ip = ip } })
          end
          for host, want in pairs({
            ["www.google.com"] = "google.com",
            ["rr1.sn-abc.googlevideo.com"] = "googlevideo.com",
            ["a.b.foo.co.uk"] = "foo.co.uk",
            ["co.uk"] = "co.uk",
            ["x.y.github.io"] = "github.io",
            ["WWW.Example.COM."] = "example.com",
            ["www.xn--80aswg.xn--p1ai"] = "xn--80aswg.xn--p1ai",
            ["a.www.ck"] = "www.ck",
            ["foo.bar.ck"] = "foo.bar.ck",
          }) do
            assert(key(host, "2") == want, host .. ": " .. tostring(key(host, "2")))
          end
          assert(key("a.b.foo.co.uk", "3") == "b.foo.co.uk")
          assert(key("1.2.3.4", "2", true) == "standard")
          assert(key("www.google.com", nil) == "standard")
        '
        # What nfqws2's learner and z2k's detector miss: flaky sites, stalled transfers,
        # unanswered ClientHellos, for learning and for rotation; and the verdicts the
        # proxy routes by: works, unfixable, blocked by address.
        mkdir -p detect
        touch detect/verdicts.tsv
        DETECT=$(grep -oE '/nix/store/[^ ]+-detect\.lua' "${z2kRuntime}/config") WORK="$PWD/detect" \
          PROXY_SUITE_ZAPRET2_VERDICTS="$PWD/detect/verdicts.tsv" lua ${./zapret2/detect-test.lua}
        # nfqws2 finds the verdicts file by its environment; the last profile watches
        # connections for addresses blocked outright.
        grep -qF '"PROXY_SUITE_ZAPRET2_VERDICTS=/var/lib/proxy-suite/zapret2/verdicts.tsv"' \
          <<<'${builtins.toJSON zapret2Z2k.config.systemd.services.proxy-suite-zapret.serviceConfig.Environment}'
        grep -qE -- " --new --filter-tcp=\* --out-range=<n2 --in-range=<n2 --payload=empty --lua-desync=ps_syn:fails=3:time=300:log'$" "${z2kRuntime}/config"
        # nfqws2-keenetic learns with detect.lua too: its own profile only reads the auto list.
        grep -qE -- " --new --filter-tcp=443 --filter-l7=tls --in-range=-s65536 --out-range=-s32768 --payload=all --lua-desync=ps_learn:auto=[^ ]+:exclude=[^ ]+/etc/nfqws2/lists/exclude.list,[^ ]+zapret-hosts-user-exclude.txt:" "${globalRuntime}/config"
        test "$(grep -oF -- '<HOSTLIST>' "${globalRuntime}/config" | wc -l)" = 0
        # Counted failures and switches, named by circular key and host; the switch
        # is the one that stuck, after the state layer's revert.
        LOG=$(grep -oE '/nix/store/[^ ]+-strategy-log\.lua' "${z2kRuntime}/config") lua -e '
          function automate_failure_counter(hrec, crec, fails)
            if crec.failure then return false end
            crec.failure = true
            hrec.failure_counter = (hrec.failure_counter or 0) + 1
            if hrec.failure_counter < fails then return false end
            hrec.failure_counter = nil
            return true
          end
          local revert = false
          function circular()
            local hrec = autostate.rkn_tcp["example.com"]
            local before = hrec.nstrategy
            if automate_failure_counter(hrec, {}, 2) then hrec.nstrategy = hrec.nstrategy % hrec.ctstrategy + 1 end
            if revert then hrec.nstrategy = before end
            return "verdict"
          end
          autostate = { rkn_tcp = { ["example.com"] = { nstrategy = 1, ctstrategy = 50 } } }
          dofile(os.getenv("LOG"))
          assert(circular() == "verdict")
          circular()
          automate_failure_counter(autostate.rkn_tcp["example.com"], { failure = true }, 2)
          revert = true
          circular()
          circular()
        ' 2>strategy.log
        diff - strategy.log <<'EOF'
        zapret2: rkn_tcp example.com: failure 1/2 on strategy 1/50
        zapret2: rkn_tcp example.com: switched from strategy 1 to 2/50
        zapret2: rkn_tcp example.com: failure 1/2 on strategy 2/50
        zapret2: rkn_tcp example.com: failed enough to switch, but stays on strategy 2/50: it worked moments ago, or that strategy is final
        EOF
        # Off, the log is gone; debug hands nfqws2 its own.
        if grep -qF -- 'strategy-log.lua' "${z2kTunedRuntime}/config"; then exit 1; fi
        grep -qF -- "NFQWS2_OPT='--debug=1 --bind-fix4 --bind-fix6 --ipcache-hostname=1 --lua-init=" "${z2kTunedRuntime}/config"
        # z2k's own daemon flags; the other source runs without the experimental name cache.
        grep -qF -- "NFQWS2_OPT='--bind-fix4 --bind-fix6 --ipcache-hostname=1 --lua-init=" "${z2kRuntime}/config"
        grep -qF -- "NFQWS2_OPT='--bind-fix4 --bind-fix6 --lua-init=" "${globalRuntime}/config"
        # Every UDP fake carries a blob; zapret2 errors on each packet otherwise.
        grep -qF -- '--lua-desync=fake:blob=0x0000' "${globalRuntime}/config"
        if grep -qF -- '--lua-desync=fake:repeats=' "${globalRuntime}/config"; then exit 1; fi
        # circular sees what it counts: incoming resets and replies on TCP, as many UDP
        # packets as udp_out; the strategies after it keep their own filters.
        grep -qF -- '--in-range=-s5556 --payload=tls_client_hello,mtproto_initial,tls_server_hello,empty,unknown --lua-desync=circular:' "${globalRuntime}/config"
        grep -qE -- ':reset --in-range=x --payload=tls_client_hello,mtproto_initial --lua-desync=fake:' "${globalRuntime}/config"
        grep -qE -- '--out-range=a --in-range=a --payload=[^ ]+ --lua-desync=circular:[^ ]+ --out-range=<n2 --in-range=x --lua-desync=fake:' "${globalRuntime}/config"
        # autoHostlist fills what circular leaves unset; the source keeps its fails and time.
        grep -qF -- '--lua-desync=circular:fails=2:time=300:retrans=3:nld=2:maxseq=32768:inseq=4096:udp_out=4:udp_in=1:reset ' "${globalRuntime}/config"

        # z2k: its generator's pools, detectors and fake TTL; only the general profile learns.
        grep -qx 'NFQWS2_TCP_PKT_OUT=20' "${z2kRuntime}/config"
        grep -qx 'NFQWS2_UDP_PKT_IN=8' "${z2kRuntime}/config"
        # Its Discord profile filters up to 50100, one port past its queue: the queue takes it.
        grep -qx 'NFQWS2_PORTS_UDP=443,1400,3478-3481,5349,19294-19344,50000-50100' "${z2kRuntime}/config"
        grep -qF -- 'key=rkn_tcp:nld=2:failure_detector=z2k_fail_tls_alert:retrans=3:maxseq=32768:inseq=4096:udp_out=4:udp_in=1:reset' "${z2kRuntime}/config"
        grep -qF -- 'failure_detector=z2k_fail_quic_silence' "${z2kRuntime}/config"
        grep -qF -- ':fool=z2k_dynamic_ttl' "${z2kRuntime}/config"
        # A --hostlist-auto profile wins every named flow, so the one that learns is
        # last and has no strategies; rkn_tcp reads what it learned and leaves
        # YouTube's hosts to yt_tcp/gv_tcp.
        grep -qF -- '/extra_strats/TCP_Discord.txt <HOSTLIST_NOAUTO> --hostlist-exclude=' "${z2kRuntime}/config"
        grep -qE -- '<HOSTLIST_NOAUTO> --hostlist-exclude=[^ ]+/extra_strats/TCP/YT/List.txt --hostlist-exclude=[^ ]+/extra_strats/TCP/YT_GV/List.txt --filter-tcp=' "${z2kRuntime}/config"
        # nfqws2's own learner, without extendedDetection.
        test "$(grep -oF -- '<HOSTLIST>' "${z2kTunedRuntime}/config" | wc -l)" = 1
        grep -qE -- " --new --filter-tcp=443,2053,2083,2087,2096,8443,8444 --filter-l7=tls --hostlist-exclude=[^ ]+/lists/whitelist.txt --hostlist-exclude=/var/lib/proxy-suite/zapret2/zapret-hosts-user-exclude.txt <HOSTLIST> --new --filter-tcp=\* " "${z2kTunedRuntime}/config"
        grep -qx 'NFQWS2_TCP_PKT_IN=15' "${z2kTunedRuntime}/config"
        # detect.lua's in its place by default: same ports, the same auto list and excludes,
        # and the server's packets past the 16 KB cutoff.
        test "$(grep -oF -- '<HOSTLIST>' "${z2kRuntime}/config" | wc -l)" = 0
        grep -qE -- " --new --filter-tcp=443,2053,2083,2087,2096,8443 --filter-l7=tls --in-range=-s65536 --out-range=-s32768 --payload=all --lua-desync=ps_learn:auto=/var/lib/proxy-suite/zapret2/zapret-hosts-auto.txt:exclude=[^ ]+/lists/whitelist.txt,/var/lib/proxy-suite/zapret2/zapret-hosts-user-exclude.txt:fails=3:time=300:inseq=4096:retrans=3:win=32:log --new --filter-tcp=\* " "${z2kRuntime}/config"
        grep -qx 'NFQWS2_TCP_PKT_IN=32' "${z2kRuntime}/config"
        grep -qF -- '/lists/whitelist.txt --hostlist-exclude=/var/lib/proxy-suite/zapret2/zapret-hosts-user-exclude.txt' "${z2kRuntime}/config"

        # proxy-ctl names state.tsv's rows by this map: keyed circulars by key, the
        # others by instance, a template's strategies under the profile importing it.
        jq -e '.rkn_tcp["1"] | map(split(":")[0]) == ["tls_client_hello_clone", "fake", "multisplit"]' "${z2kRuntime}/strategies.json"
        jq -e '.cf_extra == .rkn_tcp' "${z2kRuntime}/strategies.json"
        jq -e '.http_rkn["1"] == ["http_methodeol:payload=http_req:dir=out"]' "${z2kRuntime}/strategies.json"
        jq -e 'has("yt_tcp") and has("gv_tcp") and has("yt_quic")' "${z2kRuntime}/strategies.json"
        # QUIC to the sites rkn_tcp handles gets YouTube's QUIC strategies, after yt_quic,
        # and the silence detector that sees dead QUIC flows counts its failures.
        jq -e '.rkn_quic == .yt_quic' "${z2kRuntime}/strategies.json"
        grep -qE -- "key=yt_quic:[^']* --new [^']*/extra_strats/TCP/RKN/List.txt --hostlist=[^ ]+/extra_strats/TCP_Discord.txt <HOSTLIST_NOAUTO> --filter-udp=443 --filter-l7=quic [^']*key=rkn_quic:" "${z2kRuntime}/config"
        QS=$(grep -oE '/nix/store/[^ ]+-z2k-quic-silence\.lua' "${z2kRuntime}/config")
        grep -qF 'rkn_quic = true' "$QS"
        # Its first flight is no success, nor an answer to the silence detector: rotation moves.
        grep -qE -- "key=rkn_quic:" "${z2kRuntime}/config"
        grep -oE -- "--lua-desync=circular:[^ ]*key=rkn_quic:[^ ]*" "${z2kRuntime}/config" | grep -qF ':udp_in=4:'
        grep -oE -- "--lua-desync=circular:[^ ]*key=yt_quic:[^ ]*" "${z2kRuntime}/config" | grep -qF ':udp_in=1:'
        QS="$QS" lua -e '
          function standard_failure_detector() return "standard" end
          function pos_get(desync) return desync.n end
          dofile(os.getenv("QS"))
          local function reply(key, udp_in, n)
            local crec = {}
            z2k_fail_quic_silence({ dis = { udp = true }, outgoing = false, n = n, arg = { key = key, udp_in = udp_in } }, crec)
            return crec.z2k_quic_answered == true
          end
          assert(not reply("rkn_quic", "4", 2) and reply("rkn_quic", "4", 5))
          assert(not reply("yt_quic", "1", 1) and reply("yt_quic", "1", 2))
          assert(z2k_fail_quic_silence({ dis = { udp = true }, arg = { key = "rkn_tcp" } }, {}) == "standard")
        '
        jq -e 'keys == ["circular_1_1", "circular_3_1"]' "${globalRuntime}/strategies.json"
        if grep -qF 'strategy=' "${z2kRuntime}/strategies.json"; then exit 1; fi

        # z2k's Lua in its own order: ranges (repeats=6-10) resolve before its strategies fire.
        grep -qE -- 'z2k-fooling-ext\.lua --lua-init=@[^ ]+/z2k-range-rand\.lua --lua-init=@[^ ]+/z2k-modern-core\.lua' "${z2kRuntime}/config"

        # --- 16 KB cutoff ---------------------------------------------------
        # The whitelisted-name step runs ahead of rotation, in z2k only: ahead of the
        # nfqws2-keenetic strategies it broke hosts they reach on their own.
        grep -qF -- '/files/lua/z2k-tcp16.lua' "${z2kRuntime}/config"
        grep -qF -- 'blob=z2k_ch:optional:repeats=8:tcp_ts=-1000 --lua-desync=circular:fails=3:time=60:key=rkn_tcp' "${z2kRuntime}/config"
        if grep -qF -- 'z2k_sni_pick' "${globalRuntime}/config"; then exit 1; fi
        if grep -qF -- 'z2k-tcp16.lua' "${globalRuntime}/config"; then exit 1; fi
        # zapret2 leaves the probe's own connections alone, in every chain.
        test "$(grep -c 'ct mark and 0x2000000 != 0 return' "${globalRuntime}/init.d/sysv/custom.d/50-proxy-suite-custom.sh")" = 4

        # ts is checked for digits before arithmetic, which would run what a[$(...)] in it names.
        grep -qF -- '[[ $last =~ ^[0-9]+$ ]] || last=0' ${cutoffProbe}
        if grep -qF -- '$((now - $(cat ts' ${cutoffProbe}; then exit 1; fi
        # The group's probe request comes through requests/, not the directory root works in.
        grep -qF -- 'if [ -e requests/force ]; then' ${cutoffProbe}

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

        # --- directSync of runtime hosts --------------------------------------
        # Last before the final rule, and only where direct lists apply.
        grep -qF 'tag: "zapret-hosts"' ${socksStart zapret2Global}
        grep -qF 'all-proxy | all-bypass) ;;' ${socksStart zapret2Global}
        if grep -qF 'zapret-hosts' ${socksStart zapretDiscordYoutubeGlobal}; then exit 1; fi
        # What zapret2 cannot fix goes to the proxy, ahead of what it does.
        grep -qF 'tag: "zapret-unfixable"' ${socksStart zapret2Global}
        test "$(grep -n 'zapret-unfixable' ${socksStart zapret2Global} | head -n1 | cut -d: -f1)" -lt \
          "$(grep -n 'zapret-hosts' ${socksStart zapret2Global} | head -n1 | cut -d: -f1)"
        # Pinned hosts, and learned ones a strategy was seen working for, less the excluded;
        # IP literals as single addresses.
        mkdir -p direct-lists empty-lists out empty-out
        printf 'pinned.example\n# a comment\n\n' >direct-lists/zapret-hosts-user.txt
        printf 'Learned.Example\nexcluded.example\n203.0.113.7\n2001:db8::1\npinned.example\nunseen.example\n' >direct-lists/zapret-hosts-auto.txt
        printf 'excluded.example\n' >direct-lists/zapret-hosts-user-exclude.txt
        {
          printf 'works\tlearned.example\ttcp\trkn_tcp\t1\nworks\texcluded.example\ttcp\trkn_tcp\t1\n'
          printf 'works\t203.0.113.7\ttcp\trkn_tcp\t1\n'
          printf 'stalls\tunseen.example\tcutoff\t\t1\nworks\tunseen.example\ttcp\trkn_tcp\t2\n'
          printf 'unfixable\tchat.example\ttcp\trkn_tcp\t2\nunfixable\tdiscord.com\tudp\trkn_quic\t2\n'
          printf 'works\tdiscord.com\ttcp\trkn_tcp\t2\n'
          printf 'blocked\t149.154.167.99\tip\tx\t3\nblocked\t198.51.100.1\tip\tx\t3\nreachable\t198.51.100.1\tip\t\t4\n'
          printf 'unfixable\tretried.example\ttcp\t\t5\nretry\tretried.example\ttcp\tproxy-ctl\t6\n'
          printf 'unfixable\tBAD NAME\ttcp\t\t7\n'
        } >direct-lists/verdicts.tsv
        ${directSync} direct-lists out
        test "$(cat out/direct.json)" = '{"version":1,"rules":[{"domain_suffix":["learned.example","pinned.example"]},{"ip_cidr":["203.0.113.7/32"]}]}'
        # A site's TCP, or only its QUIC; addresses blocked outright.
        test "$(cat out/proxy.json)" = '{"version":1,"rules":[{"domain_suffix":["chat.example"]},{"network":["udp"],"port":[443],"domain_suffix":["discord.com"]},{"ip_cidr":["149.154.167.99/32"]}]}'
        # Unchanged, the files stay as they were: sing-box reloads on every rename.
        inode=$(stat -c %i out/direct.json)
        ${directSync} direct-lists out
        test "$(stat -c %i out/direct.json)" = "$inode"
        ${directSync} empty-lists empty-out
        test "$(cat empty-out/direct.json)" = '{"version":1,"rules":[]}'
        test "$(cat empty-out/proxy.json)" = '{"version":1,"rules":[]}'

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

        # --- store paths ------------------------------------------------------
        # Every path a config names is a build input. One that lost its string context
        # is missing from the closure, and from this sandbox under lazy trees.
        for config in ${globalRuntime}/config ${perAppRuntime}/config ${z2kRuntime}/config; do
          for path in $(grep -oE '/nix/store/[a-z0-9]{32}-[^ :"/]+' "$config" | sort -u); do
            test -e "$path" || { echo "$config names $path, which is not in the sandbox" >&2; exit 1; }
          done
        done

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

          # --user is deliberately omitted: the sandbox is not root. No globbing, as in
          # the launcher: --filter-tcp=* is nfqws2's.
          set -f
          "$base/nfq2/nfqws2" --dry-run --fwmark="$DESYNC_MARK" \
            --lua-init=@"$base/lua/zapret-lib.lua" \
            --lua-init=@"$base/lua/zapret-antidpi.lua" \
            --lua-init=@"$base/lua/zapret-auto.lua" \
            $opt
        )

        dry_run ${globalRuntime} global.args
        # detect.lua learns; the auto list is read like the others.
        if grep -q -- '^--hostlist-auto=' global.args; then exit 1; fi
        grep -qx -- "--hostlist=$HOSTLIST_BASE/zapret-hosts-auto.txt" global.args
        grep -q -- '^--lua-desync=ps_learn:' global.args

        # The supervised launcher execs nfqws2 with the command line the init script builds.
        printf '#!/bin/sh\nprintf "%%s\\n" "$@"\n' >fake-nfqws2
        chmod +x fake-nfqws2
        ZAPRET_RW=${globalRuntime} NFQWS2="$PWD/fake-nfqws2" ${daemonStart} >daemon.args
        head -n1 daemon.args | grep -qx -- '--user=root'
        # dry_run moved the state files into the sandbox, detect.lua's arguments with them.
        tail -n +6 daemon.args | sed "s|/var/lib/proxy-suite/zapret2/|$HOSTLIST_BASE/|g" | diff - global.args

        dry_run ${z2kRuntime} z2k.args
        # The learner is the last profile: nothing after it, and nfqws2's own autohostlist off.
        test "$(grep -cx -- "--hostlist-auto=$HOSTLIST_BASE/zapret-hosts-auto.txt" z2k.args)" = 0
        # Only ps_syn follows it, last: it takes connections before their data names them.
        test "$(sed -n '/^--lua-desync=ps_learn:/,$p' z2k.args | grep -c -- '^--new$')" = 1
        tail -n1 z2k.args | grep -q -- '^--lua-desync=ps_syn:'

        # Extra ports and --debug are options nfqws2 takes; nfqws2's own learner, tuned.
        dry_run ${tunedRuntime} tuned.args
        grep -qx -- "--hostlist-auto=$HOSTLIST_BASE/zapret-hosts-auto.txt" tuned.args
        grep -qx -- '--hostlist-auto-fail-threshold=5' tuned.args
        grep -qx -- '--hostlist-auto-fail-time=120' tuned.args
        dry_run ${z2kTunedRuntime} z2k-tuned.args >/dev/null
        test "$(grep -cx -- "--hostlist-auto=$HOSTLIST_BASE/zapret-hosts-auto.txt" z2k-tuned.args)" = 1
        # Nothing but ps_syn follows the learning profile, so no profile after it can lose
        # to it: ps_syn takes only what has no protocol yet, which the TLS learner never does.
        test "$(sed -n '/^--hostlist-auto=/,$p' z2k-tuned.args | grep -c -- '^--new$')" = 1
        test "$(sed -n '/^--hostlist-auto=/,$p' z2k-tuned.args | grep -c -- '^--lua-desync=')" = 1
        tail -n1 z2k-tuned.args | grep -q -- '^--lua-desync=ps_syn:'

        touch "$out"
      '';
}
