{ lib, ... }:

let
  inherit (lib) mkEnableOption mkOption types;
  int =
    default: description:
    mkOption {
      type = types.ints.positive;
      inherit default description;
    };

  # Ported from nfqws2-keenetic. `circular` rotates strategy=1/2/3 per
  # second-level domain whenever the failure detector fires.
  defaultProfiles = [
    ''
      --filter-tcp=443,80,1984,5222 --filter-l7=http,tls,mtproto <HOSTLIST>
      --payload=tls_client_hello,mtproto_initial
      --lua-desync=circular:fails=2:time=300:retrans=3:nld=2
      --lua-desync=fake:blob=tls_clienthello:tls_mod=rnd,dupsid,sni=fonts.google.com:tcp_seq=10000:strategy=1
      --lua-desync=multisplit:pos=1,midsld:seqovl=1:seqovl_pattern=tls_clienthello:tcp_ts_up:strategy=1
      --lua-desync=fake:blob=0x00000000:tcp_ack=-66000:tls_mod=rnd,dupsid,sni=www.google.com:repeats=2:strategy=2
      --lua-desync=multisplit:pos=1,midsld:strategy=2
      --lua-desync=hostfakesplit:host=ozon.ru:midhost=host-2:seqovl=sniext+3:seqovl_pattern=tls_clienthello:badsum:tcp_md5:tcp_ts_up:strategy=3
      --lua-desync=hostfakesplit:tcp_md5:tcp_ts_up:strategy=3
      --payload=http_req
      --lua-desync=http_methodeol:badsum
    ''
    # QUIC reads the learned list but never adds to it: browsers retry over TCP.
    ''
      --filter-udp=443 --filter-l7=quic <HOSTLIST_NOAUTO>
      --payload=quic_initial
      --lua-desync=fake:blob=quic_initial:repeats=11
    ''
    # No hostlist: these protocols carry no SNI.
    ''
      --filter-udp=590-600,1400,3478-3481,5349,19294-19344,49152-65535
      --filter-l7=wireguard,stun,discord,mtproto,unknown
      --out-range=<n2
      --payload=wireguard_initiation,wireguard_response,wireguard_cookie,stun,discord_ip_discovery,mtproto_initial,unknown
      --lua-desync=circular:fails=2:time=300:retrans=3:nld=2
      --lua-desync=fake:repeats=6:strategy=1
      --lua-desync=fake:blob=quic_initial:repeats=6:strategy=2
    ''
  ];
in
{
  options.services.proxy-suite.zapret.zapret2 = {
    profiles = mkOption {
      type = types.listOf types.str;
      default = defaultProfiles;
      description = ''
        nfqws2 profiles, joined with --new; first match wins. <HOSTLIST> expands to the hostlist
        arguments, <HOSTLIST_NOAUTO> to the same without learning. --qnum, --fwmark and --lua-init
        are added automatically.
      '';
      example = [
        "--filter-tcp=443 --filter-l7=tls <HOSTLIST> --payload=tls_client_hello --lua-desync=multisplit:pos=1,midsld"
      ];
    };

    blobs = mkOption {
      type = types.attrsOf types.str;
      default = {
        tls_clienthello = "tls_clienthello_www_google_com.bin";
        quic_initial = "quic_initial_www_google_com.bin";
      };
      description = "Fake payloads by name (blob=<name>): a file in zapret2's files/fake, or an absolute path.";
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
        type = types.str;
        default = "80,443,1984,2053,2083,2087,2096,5222,8443";
        description = "TCP ports sent to NFQUEUE. Must cover every port a profile filters on.";
      };

      udp = mkOption {
        type = types.str;
        default = "443,590-600,1400,3478-3481,5349,19294-19344,49152-65535";
        description = "UDP ports sent to NFQUEUE. Must cover every port a profile filters on.";
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
