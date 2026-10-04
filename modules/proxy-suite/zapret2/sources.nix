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
    in
    {
      # Its init script's order. QUIC reads the learned list but never adds to it:
      # browsers retry over TCP. The UDP profile carries no SNI, so no lists.
      profiles = [
        # Its first UDP strategy's fake has no blob, which zapret2 rejects on every
        # packet; nfqws1's default for unknown UDP was 64 zero bytes.
        (replaceStrings
          [ "--lua-desync=fake:repeats=6:strategy=1" ]
          [
            "--lua-desync=fake:blob=0x${lib.fixedWidthString 128 "0" ""}:repeats=6:strategy=1"
          ]
          (args "NFQWS_ARGS_UDP")
        )
        "${args "NFQWS_ARGS_QUIC"} <HOSTLIST_NOAUTO> ${lists}"
        # No 16 KB cutoff name step: its fake ClientHello ahead of these strategies
        # broke every host on a line where the strategies alone work.
        "${args "NFQWS_ARGS"} <HOSTLIST> ${lists}"
      ];
      blobArgs = map (replaceStrings [ "@/opt/etc/nfqws2/" ] [ "@${src}/etc/nfqws2/" ]) (
        filter (hasPrefix "--blob=") (words (quoted "NFQWS_BASE_ARGS"))
      );
      luaInit = [ ];
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
    in
    {
      # Its S99zapret2 order. z2k-range-rand resolves the ranges its strategies
      # write (repeats=6-10); without it nfqws2 sends each fake once.
      luaInit = map (name: "${src}/files/lua/${name}.lua") [
        "z2k-alert"
        "z2k-quic-silence"
        "z2k-tcp16"
        "z2k-fooling-ext"
        "z2k-range-rand"
        "z2k-modern-core"
      ];
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
