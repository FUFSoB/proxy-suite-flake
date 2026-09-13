# Strategy sources for nfqws2, both pinned flake inputs.
{
  lib,
  pkgs,
  sources,
}:

let
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
        (args "NFQWS_ARGS_UDP")
        "${args "NFQWS_ARGS_QUIC"} <HOSTLIST_NOAUTO> ${lists}"
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
      luaInit = map (name: "${src}/files/lua/${name}.lua") [
        "z2k-alert"
        "z2k-quic-silence"
        "z2k-fooling-ext"
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
        pkgs.runCommand "proxy-suite-zapret2-z2k-profiles"
          {
            nativeBuildInputs = with pkgs; [
              bash
              coreutils
              findutils
              gawk
              gnugrep
              gnused
            ];
            inherit hostlistSuffix excludeSuffix;
          }
          ''
            root=$out/root
            mkdir -p "$root/lists" "$root/lua" conf
            cp -r ${src}/files/lists/extra_strats "$root/"
            chmod -R u+w "$root"
            cp "$root/extra_strats/TCP/RKN/Discord.txt" "$root/extra_strats/TCP_Discord.txt"
            cp ${src}/files/lists/cf_extra_check_ips.txt "$root/lists/"
            : >"$root/lists/discovered-domains.txt"
            # The generator wires its detectors only when their Lua files exist.
            ln -s ${src}/files/lua/*.lua "$root/lua/"

            export ZAPRET2_DIR="$root" CONFIG_DIR="$PWD/conf" LISTS_DIR="$root/lists"
            (
              cd ${src}
              bash -c '
                . lib/utils.sh && . lib/config.sh && . lib/strategies.sh && . lib/config_official.sh || exit 1
                print_info() { echo "$*" >&2; }
                print_success() { echo "$*" >&2; }
                print_warning() { echo "$*" >&2; }
                print_error() { echo "$*" >&2; }
                create_base_config >&2 &&
                  generate_strategies_conf strats_new2.txt "$STRATEGIES_CONF" >&2 &&
                  generate_quic_strategies_conf quic_strats.ini "$QUIC_STRATEGIES_CONF" >&2 &&
                  create_default_strategy_files >&2 &&
                  generate_nfqws2_opt_from_strategies
              '
            ) >generated

            sed -n '/^NFQWS2_OPT="/,/^"$/p' generated | sed '1s/^NFQWS2_OPT="//; $d' | tr '\n' ' ' >raw
            grep -q -- '--lua-desync=circular' raw || { echo "z2k generator produced no profiles" >&2; exit 1; }

            # Its learned-host list becomes ours (only the first profile learns), its
            # whitelist gains our excludes, and the circular args it pins to the zapret2
            # docs are dropped so autoHostlist fills them in.
            awk -v disc="--hostlist=$root/lists/discovered-domains.txt" \
                -v wl="--hostlist-exclude=$root/lists/whitelist.txt" \
                -v hsuf="$hostlistSuffix" -v esuf="$excludeSuffix" '
              {
                for (i = 1; i <= NF; i++) {
                  t = $i
                  if (t == disc) {
                    t = (seen++ ? "<HOSTLIST_NOAUTO>" : "<HOSTLIST>") hsuf
                  } else if (t == wl) {
                    t = t esuf
                  } else if (t ~ /^--lua-desync=circular:/) {
                    n = split(substr(t, 23), p, ":")
                    t = "--lua-desync=circular"
                    for (j = 1; j <= n; j++)
                      if (p[j] !~ /^(retrans|maxseq|inseq)=/ && p[j] != "reset") t = t ":" p[j]
                  }
                  printf "%s%s", (i > 1 ? " " : ""), t
                }
              }' raw >body

            awk -v z=${src} '
              match($0, /^([A-Z0-9_]+_BLOB)="\$ZAPRET_BASE\/([^"]+)"/, m) { file[m[1]] = m[2] }
              match($0, /--blob=([a-z0-9_]+):@\$([A-Z0-9_]+_BLOB)/, m) { printf "--blob=%s:@%s/%s ", m[1], z, file[m[2]] }
            ' ${src}/files/S99zapret2.new >blobs
            grep -q -- '--blob=' blobs || { echo "z2k blob registrations not found" >&2; exit 1; }

            mkdir -p "$out"
            cp blobs "$out/blobs"
            cp body "$out/profiles"
          '';
    };
in
{
  nfqws2-keenetic = keenetic;
  inherit z2k;
}
