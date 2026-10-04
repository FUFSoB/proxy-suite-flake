# Strategy sources for nfqws2, both pinned flake inputs.
{
  lib,
  pkgs,
  sources,
}:

let
  fillTemplate = import ../lib/fill-template.nix;
  inherit (lib)
    concatStringsSep
    filter
    hasPrefix
    replaceStrings
    splitString
    trim
    ;

  words = s: filter (w: w != "") (splitString " " (replaceStrings [ "\n" "\t" ] [ " " " " ] s));

  # The text between start and the next stop. Split, not a regex: std::regex overflows
  # its stack on files this size. A pinned file that stopped matching must fail the
  # build, not render an empty profile.
  between =
    what: start: stop: text:
    let
      parts = splitString start text;
    in
    if builtins.length parts != 2 then
      throw "proxy-suite: expected one `${start}` in ${what}; did a flake input bump change its format?"
    else
      builtins.head (splitString stop (builtins.elemAt parts 1));

  # The same for a fix to a pinned file: one that no longer applies must fail the build.
  patch =
    what: from: to: text:
    if lib.hasInfix from text then
      replaceStrings [ from ] [ to ] text
    else
      throw "proxy-suite: expected `${from}` in ${what}; did a flake input bump change it?";

  keenetic =
    let
      src = sources.nfqws2-keenetic;
      conf = builtins.readFile "${src}/etc/nfqws2/nfqws2.conf";
      quoted = name: between "nfqws2.conf" "\n${name}=\"" "\"" conf;
      bare = name: between "nfqws2.conf" "\n${name}=" "\n" conf;
      # The strategy blocks carry "# Strategy N" comment lines inside the quotes.
      args =
        name:
        concatStringsSep " " (
          words (
            concatStringsSep "\n" (filter (l: !(hasPrefix "#" (trim l))) (splitString "\n" (quoted name)))
          )
        );
      lists = "--hostlist=${src}/etc/nfqws2/lists/user.list --hostlist-exclude=${src}/etc/nfqws2/lists/exclude.list";
      circular = "--lua-desync=circular:fails=2:time=300:retrans=3:nld=2";
      tcpPayload = "--payload=tls_client_hello,mtproto_initial";
      udpPayload = "--payload=wireguard_initiation,wireguard_response,wireguard_cookie,stun,discord_ip_discovery,mtproto_initial,unknown";
    in
    {
      # Its init script's order. QUIC reads the learned list but never adds to it:
      # browsers retry over TCP. The UDP profile carries no SNI, so no lists.
      #
      # circular counts failures on the packets Lua is handed, and nfqws2 hands it no
      # incoming ones by default. As shipped it never saw a reset or a server's reply
      # (only a silent drop rotated TCP), and on UDP, behind <n2, only the first packet
      # of the udp_out it waits for: UDP never rotated. circular gets them now, as in
      # zapret2's manual, and the strategies after it keep their own filters. The NFQUEUE
      # window still bounds what reaches Lua.
      profiles = [
        # Its first UDP strategy's fake has no blob, which zapret2 rejects on every
        # packet; nfqws1's default for unknown UDP was 64 zero bytes.
        (lib.pipe (args "NFQWS_ARGS_UDP") [
          (patch "NFQWS_ARGS_UDP" "--lua-desync=fake:repeats=6:strategy=1"
            "--lua-desync=fake:blob=0x${lib.fixedWidthString 128 "0" ""}:repeats=6:strategy=1"
          )
          (patch "NFQWS_ARGS_UDP" "--out-range=<n2 ${udpPayload} ${circular}"
            "--out-range=a --in-range=a ${udpPayload} ${circular} --out-range=<n2 --in-range=x"
          )
        ])
        "${args "NFQWS_ARGS_QUIC"} <HOSTLIST_NOAUTO> ${lists}"
        # No 16 KB cutoff name step: its fake ClientHello ahead of these strategies
        # broke every host on a line where the strategies alone work. Its HTTP strategy
        # has no strategy=N, so circular must not take http_req: it would skip it.
        "${
          patch "NFQWS_ARGS" "${tcpPayload} ${circular}"
            "--in-range=-s5556 ${tcpPayload},tls_server_hello,empty,unknown ${circular} --in-range=x ${tcpPayload}"
            (args "NFQWS_ARGS")
        } <HOSTLIST> ${lists}"
      ];
      blobArgs = map (replaceStrings [ "@/opt/etc/nfqws2/" ] [ "@${src}/etc/nfqws2/" ]) (
        filter (hasPrefix "--blob=") (words (quoted "NFQWS_BASE_ARGS"))
      );
      luaInit = [ ];
      daemonArgs = [ ];
      ports = {
        tcp = bare "TCP_PORTS";
        udp = replaceStrings [ ":" ] [ "-" ] (bare "UDP_PORTS");
      };
      window = { };
    };

  z2k =
    let
      src = sources.z2k;
      generator = builtins.readFile "${src}/lib/config_official.sh";
      ports = name: between "config_official.sh" "\n${name}=\"" "\"" generator;
      # Its silence detector, the only one that sees a dead QUIC flow (it sends less, not
      # more), knows the YouTube pools alone; rkn_quic (z2k-profiles.template.sh) joins them.
      # It took any reply for an answer, but DPI that lets the server's first flight through
      # and drops the rest leaves a flow dead with a reply or two (every Discord host): such
      # a flow neither failed nor, past udp_in, succeeded, and rotation never moved. A flow
      # is answered now past udp_in replies, as the success detector judges it.
      quicSilence = pkgs.writeText "z2k-quic-silence.lua" (
        lib.pipe (builtins.readFile "${src}/files/lua/z2k-quic-silence.lua") [
          (patch "z2k-quic-silence.lua" "local Z2K_QUIC_POOLS = { yt_quic = true, gv_quic = true }"
            "local Z2K_QUIC_POOLS = { yt_quic = true, gv_quic = true, rkn_quic = true }"
          )
          (patch "z2k-quic-silence.lua"
            "    if not desync.outgoing then\n        crec.z2k_quic_answered = true\n"
            "    if not desync.outgoing then\n        if (pos_get(desync, 'n') or 0) > (tonumber(desync.arg.udp_in) or 1) then crec.z2k_quic_answered = true end\n"
          )
        ]
      );
    in
    {
      # Its S99zapret2 order. z2k-range-rand resolves the ranges its strategies
      # write (repeats=6-10); without it nfqws2 sends each fake once.
      luaInit =
        map (name: if name == "z2k-quic-silence" then quicSilence else "${src}/files/lua/${name}.lua")
          [
            "z2k-alert"
            "z2k-quic-silence"
            "z2k-tcp16"
            "z2k-fooling-ext"
            "z2k-range-rand"
            "z2k-modern-core"
          ];
      # As its S99zapret2 runs nfqws2: a connection without SNI (some TVs and apps, a
      # SYN before the ClientHello its syndata strategies act on) takes the name last
      # seen on that IP, so it still meets its site's profile and strategy.
      daemonArgs = [ "--ipcache-hostname=1" ];
      ports = {
        tcp = ports "NFQWS2_PORTS_TCP";
        udp = ports "NFQWS2_PORTS_UDP";
      };
      # Queue windows from its generated config: the clone of a multi-segment
      # ClientHello and the QUIC silence detector need more packets than nfqws2's defaults.
      window = {
        tcpOut = 20;
        udpOut = 8;
        udpIn = 8;
      };

      # z2k's own installer and config generator, run offline against a staged copy
      # of its tree, so every pass it applies (pool layout, in-range windows,
      # detectors, fake TTL) comes out exactly as on a router. Its tree is staged
      # under $out because the generated options point into it.
      mkProfiles =
        { hostlistSuffix, excludeSuffix }:
        pkgs.runCommand "proxy-suite-zapret2-z2k-profiles" {
          nativeBuildInputs = with pkgs; [
            bash
            coreutils
            findutils
            gawk
            gnugrep
            gnused
          ];
          inherit hostlistSuffix excludeSuffix;
        } (fillTemplate ./z2k-profiles.template.sh { z2k = src; });
    };
in
{
  nfqws2-keenetic = keenetic;
  inherit z2k;
}
