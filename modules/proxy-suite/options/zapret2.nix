{ lib, ... }:

let
  inherit (lib) mkEnableOption mkOption types;
  int =
    default: description:
    mkOption {
      type = types.ints.positive;
      inherit default description;
    };
  fromSource = what: "null uses the ${what} of strategySource.";
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
        Where profiles, blobs and ports come from; both are pinned flake inputs.
        "nfqws2-keenetic": its nfqws2.conf strategies with its user and exclude lists.
        "z2k": z2k's own config generator, run at build time: per-category rotation pools
        (general, YouTube, googlevideo, QUIC, Discord), its failure detectors and fake-TTL
        hook, its blobs, whitelist and hostlists, including the ~125k-domain RKN list
        (about 15 MB more RSS per nfqws2 process).
        Either way each host's working strategy is remembered across restarts in
        /var/lib/proxy-suite/zapret2/circular/state.tsv.
      '';
      example = "z2k";
    };

    profiles = mkOption {
      type = types.nullOr (types.listOf types.str);
      default = null;
      description = ''
        nfqws2 profiles replacing those of strategySource, joined with --new; first match wins.
        <HOSTLIST> expands to the hostlist arguments, <HOSTLIST_NOAUTO> to the same without
        learning. --qnum, --fwmark and --lua-init are added automatically. ${fromSource "profiles"}
      '';
      example = [
        "--filter-tcp=443 --filter-l7=tls <HOSTLIST> --payload=tls_client_hello --lua-desync=multisplit:pos=1,midsld"
      ];
    };

    blobs = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Fake payloads by name (blob=<name>) on top of those of strategySource: a file in zapret2's files/fake, or an absolute path.";
      example = {
        tls_clienthello = "/etc/proxy-suite/my_clienthello.bin";
      };
    };

    domains = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Domains always treated as blocked. At runtime: `proxy-ctl zapret auto add`.";
      example = [ "rutracker.org" ];
    };

    excludeDomains = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Domains never touched or learned. At runtime: `proxy-ctl zapret auto exclude`.";
      example = [ "bank.example.com" ];
    };

    ports = {
      tcp = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "TCP ports sent to NFQUEUE. Must cover every port a profile filters on. ${fromSource "ports"}";
        example = "80,443";
      };

      udp = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "UDP ports sent to NFQUEUE. Must cover every port a profile filters on. ${fromSource "ports"}";
        example = "443";
      };
    };

    ipv6 = mkOption {
      type = types.bool;
      default = false;
      description = "Intercept IPv6 as well as IPv4.";
    };

    autoHostlist = {
      enable = mkEnableOption "learning blocked hosts at runtime" // {
        default = true;
        description = ''
          Learn blocked hosts: after failThreshold failures (retransmissions, early RST, DPI
          redirect, one-sided UDP) a host joins /var/lib/proxy-suite/zapret2/zapret-hosts-auto.txt.
          Off, only zapret2.domains and `proxy-ctl zapret auto add` are acted on.
          The thresholds below also fill whichever of them a profile's strategy rotation
          (circular) leaves unset; its own fails and time are kept.
        '';
      };

      failThreshold = int 3 "Failures before a host is learned.";
      failTime = int 300 "Seconds allowed between two failures before the count resets.";
      retransThreshold = int 3 "Retransmissions of the first request that count as one failure.";

      retransReset = mkOption {
        type = types.bool;
        default = true;
        description = "RST a stalled client once retransThreshold is hit, so failures are counted fast.";
      };

      retransMaxseq = int 32768 "Outgoing sequence number past which failure detection stops.";
      incomingMaxseq = int 4096 "Incoming sequence number past which an RST or redirect is not a failure.";
      udpOut = int 4 "Outgoing UDP packets before a one-sided exchange counts as a failure.";
      udpIn = int 1 "Incoming UDP packets at or below which an exchange is one-sided.";

      debugLog = mkOption {
        type = types.bool;
        default = false;
        description = "Log why hosts are or are not learned to zapret-hosts-auto-debug.log.";
      };
    };
  };
}
