{ lib, ... }:

let
  inherit (lib) mkOption types;
  inherit (import ./lib.nix { inherit lib; }) bool;
in
{
  # Troubleshooting only: everything here logs more, some of it every site visited.
  options.services.proxy-suite.debug = {
    logLevel = mkOption {
      type = types.enum [
        "warn"
        "info"
        "debug"
        "trace"
      ];
      default = "warn";
      description = ''
        How much the proxy backends log to the journal (`proxy-ctl logs proxy-suite-socks`):
        sing-box, and XRay where it runs (XRay has no "trace": it logs at "debug" then).
        "info" logs every connection with its destination and the rule that routed it.
        `/run/proxy-suite/xray-loglevel` still overrides XRay's level at the next start.
      '';
      example = "info";
    };

    connectionLog = {
      enable = bool false ''
        Record the backends' connections to the journal: each one as it opens, with its
        listener, site, rule and exit, and as it closes, with the bytes each way and how long
        it lasted. For failures that come and go: look back at the time one happened. A unit
        per backend, up while it is: proxy-suite-connection-log for the local proxy and
        global or per-app TProxy, proxy-suite-connection-log-tun for the global TUN and
        proxy-suite-connection-log-per-app-tun for per-app TUN, whose Clash APIs this turns
        on. The same view live: `proxy-ctl debug conns`. Polls the Clash API, so it needs the
        sing-box or hybrid backend; a connection shorter than `interval` can be missed.
      '';

      hosts = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Record only connections to these domains and their subdomains, or these addresses.
          Empty: every connection.
        '';
        example = [
          "twimg.com"
          "x.com"
        ];
      };

      inbounds = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Record only connections that came in on listeners whose tag starts with one of
          these: "tproxy" for global and per-app TProxy, "tun-in" for the global and per-app
          TUN, "per-app-pin" for apps run `--via` an outbound through TProxy, "mixed-in" for
          the local proxy. Empty: every listener.
        '';
        example = [ "tproxy" ];
      };

      stallAfter = mkOption {
        type = types.ints.unsigned;
        default = 10;
        description = ''
          Seconds a connection may wait on an answer: one that has sent since it last
          received, and received nothing for this long, is logged as stalled, and again
          when it resumes. Several requests share a connection (HTTP/2), so a stall shows
          only when all of them wait. 0: never.
        '';
      };

      interval = mkOption {
        type = types.numbers.positive;
        default = 0.5;
        description = "Seconds between looks at the connections.";
      };
    };

    perAppDns = bool false ''
      Log every lookup the per-app DNS forwarders send on (per-app TUN and TProxy, and apps
      run through an AmneziaWG interface): the name, its type, the answer's code and how long
      it took, and the lookups that got no answer. In the journals of
      proxy-suite-per-app-tun-dns, proxy-suite-per-app-tproxy-dns and
      proxy-suite-per-app-via@.
    '';

    zapret2 = {
      packets = bool false "Log everything nfqws2 does to the journal, every packet included. Very verbose.";
      autoHostlist = bool false "Log why sites are or are not learned (nfqws2's own learner).";
    };

    tgWsProxy = bool false "Log the Telegram proxy's debug messages.";
  };
}
