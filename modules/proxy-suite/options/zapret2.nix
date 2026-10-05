{ lib, ... }:

let
  inherit (lib) mkEnableOption mkOption types;
  int = (import ./lib.nix { inherit lib; }).positiveInt;
  fromSource = what: "`null`: use the ${what} from `strategySource`.";
  portOrRange = types.either types.port (types.strMatching "[0-9]+(-[0-9]+)?");
in
{
  options.services.proxy-suite.zapret.zapret2 = {
    strategySource = mkOption {
      type = types.enum [
        "nfqws2-keenetic"
        "z2k"
      ];
      default = "nfqws2-keenetic";
      description = ''
        Where the strategies, blobs and ports come from.
        - "nfqws2-keenetic": its strategies and site lists.
        - "z2k": z2k's strategies, which rotate per category (YouTube, Discord, QUIC, …), with
          its site lists, including the full RKN list (more memory).
        Either way, each site's working strategy is remembered across restarts.
      '';
      example = "z2k";
    };

    profiles = mkOption {
      type = types.nullOr (types.listOf types.str);
      default = null;
      description = ''
        Your own nfqws2 profiles, instead of those from `strategySource`. The first match wins.
        `<HOSTLIST>` expands to the site list arguments, `<HOSTLIST_NOAUTO>` to the same without
        learning. `--qnum`, `--fwmark` and `--lua-init` are added for you. ${fromSource "profiles"}
      '';
      example = [
        "--filter-tcp=443 --filter-l7=tls <HOSTLIST> --payload=tls_client_hello --lua-desync=multisplit:pos=1,midsld"
      ];
    };

    blobs = mkOption {
      type = types.attrsOf (types.strMatching "[^[:space:]]+");
      default = { };
      description = "Extra fake payloads by name (blob=<name>): a file in zapret2's files/fake, or an absolute path.";
      example = {
        tls_clienthello = "/etc/proxy-suite/my_clienthello.bin";
      };
    };

    domains = mkOption {
      # Each becomes one nfqws2 argument: whitespace would make more.
      type = types.listOf (types.strMatching "[^[:space:]]+");
      default = [ ];
      description = "Domains always treated as blocked. At runtime: `proxy-ctl zapret auto add`.";
      example = [ "rutracker.org" ];
    };

    excludeDomains = mkOption {
      type = types.listOf (types.strMatching "[^[:space:]]+");
      default = [ ];
      description = "Domains never touched or learned. At runtime: `proxy-ctl zapret auto exclude`.";
      example = [ "bank.example.com" ];
    };

    ports = {
      tcp = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "TCP ports zapret2 handles. The ports the profiles filter on and `extraTcp` are always added. ${fromSource "ports"}";
        example = "80,443";
      };

      udp = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "UDP ports zapret2 handles. The ports the profiles filter on and `extraUdp` are always added. ${fromSource "ports"}";
        example = "443";
      };

      extraTcp = mkOption {
        type = types.listOf portOrRange;
        default = [ ];
        description = ''
          More TCP ports, handled like the profiles' own: each profile that recognizes its traffic
          (`--filter-l7`, e.g. TLS) gets them too, so TLS to a blocked site on one of these ports
          gets the same strategies. A profile without `--filter-l7` keeps its ports.
        '';
        example = [
          8444
          "9000-9010"
        ];
      };

      extraUdp = mkOption {
        type = types.listOf portOrRange;
        default = [ ];
        description = ''
          More UDP ports, handled like the profiles' own: each profile that recognizes its traffic
          (`--filter-l7`, e.g. STUN, Discord, QUIC) gets them too, so a game's or call app's STUN
          on these ports gets the same strategies as Discord's.
        '';
        example = [ "27015-27030" ];
      };
    };

    proxyFallback = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Send through the proxy what zapret2 cannot fix: a site none of its strategies get
        through for (only its QUIC, when that alone fails), and an address that leaves
        connections unanswered (blocked by address, as Telegram's are). Learned sites go
        direct (`zapret.directSync`) only once a strategy is seen working for them. Needs an
        outbound; works for traffic the proxy sees (TUN, TProxy, per-app routing; by address
        only where it sees the address). `proxy-ctl zapret auto retry` gives one another try.
      '';
    };

    strategyLog = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Log each counted failure and strategy switch to the journal, per site
        (`proxy-ctl logs proxy-suite-zapret`). Without it nfqws2 logs them only with `debug`.
      '';
    };

    debug = mkOption {
      type = types.bool;
      default = false;
      description = "Log everything nfqws2 does to the journal, every packet included. Very verbose: for troubleshooting.";
    };

    ipv6 = mkOption {
      type = types.bool;
      default = false;
      description = "Handle IPv6 too.";
    };

    autoHostlist = {
      enable = mkEnableOption "learning blocked hosts at runtime" // {
        default = true;
        description = ''
          Learn blocked sites: after `failThreshold` failed connections, a site is treated as
          blocked. When off, only `zapret2.domains` and `proxy-ctl zapret auto add` are used.
        '';
      };

      failThreshold = int 3 "Failures before a site is learned.";
      failTime = int 300 "Seconds without a failure before the count resets.";
      retransThreshold = int 3 "Retransmissions of the first request that count as a failure.";

      retransReset = mkOption {
        type = types.bool;
        default = true;
        description = "Reset a stalled connection at `retransThreshold`, so failures are counted faster.";
      };

      retransMaxseq = int 32768 "Stop watching a connection for failures after this many bytes sent.";
      incomingMaxseq = int 4096 "After this many bytes received, a reset or redirect is not a failure.";
      udpOut = int 4 "UDP packets sent, with at most `udpIn` replies, that count as a failure.";
      udpIn = int 1 "Most UDP replies that still count as no answer (see `udpOut`).";

      debugLog = mkOption {
        type = types.bool;
        default = false;
        description = "Log why sites are or are not learned (nfqws2's own learner).";
      };

      extendedDetection = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Learn with proxy-suite's detector instead of nfqws2's. It also learns sites blocked
          only some of the time (a working connection no longer clears the failures before it),
          downloads that stall partway (the 16 KB cutoff), and requests that never get an
          answer. Learned sites are logged with `strategyLog`. Only with the source's own
          `profiles`, and for TLS: nfqws2-keenetic no longer learns plain HTTP sites.
        '';
      };
    };

    cutoff = {
      enable = mkEnableOption "the 16 KB cutoff probe" // {
        default = true;
        description = ''
          Work around ISPs that cut TLS to some hosting networks after about 16 KB, which no
          strategy fixes. A daily probe finds the affected networks and a whitelisted name that
          gets through for each. Only with `strategySource = "z2k"`. Each run makes thousands of
          short direct connections. `proxy-ctl zapret cutoff` shows the results.
        '';
      };

      proxyFallback = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Send cut-off networks that no name fixes through the proxy. Needs the sing-box backend,
          an outbound, and a route mode other than all-bypass. Only works for traffic the proxy
          sees by IP (TUN, TProxy, per-app routing). Explicit direct rules still win.
        '';
      };
    };
  };
}
