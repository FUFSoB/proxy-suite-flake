# Server-side proxy inbound options.
{ lib, pkgs, ... }:

let
  inherit (lib)
    literalExpression
    mkEnableOption
    mkOption
    types
    ;
  inboundTypes = import ./types/proxy-inbounds.nix { inherit lib; };
in
{
  options.services.proxy-suite.proxyInbounds = {
    enable = mkEnableOption "server-side proxy inbounds (accept connections from outside)";

    package = mkOption {
      type = types.package;
      default = pkgs.xray;
      defaultText = literalExpression "pkgs.xray";
      example = literalExpression "pkgs.xray";
      description = ''
        XRay package serving the inbounds.

        This is independent of proxy.xray.package: the inbound service always
        runs XRay, whichever backend the client side uses, and works with
        proxy.enable = false.
      '';
    };

    serverAddress = mkOption {
      type = types.nullOr (types.strMatching "[^[:space:]]+");
      default = null;
      description = ''
        Public hostname or address clients connect to. Used for generated share
        links only; it does not affect what the listeners bind.

        Leave null to detect the machine's uplink IPv4 address at service start
        time. Set it explicitly when the server is behind NAT or reached by a
        domain name.
      '';
      example = "vpn.example.com";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Add every listener port to networking.firewall. Disable to manage the
        firewall yourself.
      '';
      example = false;
    };

    shareLinks = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Write client share links to /run/proxy-suite-inbounds/links.json at
        service start, for `proxy-ctl inbounds link` and
        `proxy-ctl inbounds qr`.

        The file is readable by root and the userControl group only, because
        the links carry the listener credentials.
      '';
      example = false;
    };

    via = mkOption {
      type = types.str;
      default = "proxy";
      description = ''
        Default egress for traffic arriving on the inbounds. Individual
        listeners can override it with their own via option, which is how two
        listeners can leave through two different servers.

        - "proxy": chain out through the local proxy stack, so the machine
          relays rather than exits. Requires proxy.enable. The inbound service
          hands traffic to the SOCKS listener on proxy.listenAddress, so it
          follows whatever the client side is currently doing: the selected
          outbound, subscriptions, urltest, and `proxy-ctl select` all apply,
          with no second copy of that machinery.
        - A proxy.outbounds tag: pin this traffic to that specific server,
          independently of what the client side has selected. The outbound is
          built into the inbound service's own config, so it must be one XRay
          can represent (a url/urlFile entry, or xrayJson). Subscription
          proxies cannot be named here, because their tags only exist at
          runtime; use "proxy" to reach those.
        - "direct": leave from this machine, making it a plain exit node. Needs
          no client-side proxy configuration at all.
        - "block": drop the traffic.
      '';
      example = "direct";
    };

    zapretDirect = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Route zapret's hostlist domains and IPs to the direct outbound instead
        of through the proxy, so this host's own zapret unblocks them for
        inbound clients.

        Has no effect unless zapret.enable and zapret.syncDirectRouting are on:
        the rules are built from the same hostlists that already feed
        routing.direct on the client side, so they are empty when zapret is not
        running here.

        On by default because a zapret host is by definition inside the filtered
        network, and paying for a proxy hop to reach something zapret already
        unblocks locally is pure latency. Only applies to listeners using the
        default via; an explicit per-listener via still wins.
      '';
      example = false;
    };

    blockRu = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Send traffic destined for Russian domains and IP ranges
        ("category-ru" geosite, "ru" geoip) to the block outbound.

        On by default: a relay whose whole point is leaving the RKN-filtered
        network has no reason to carry traffic back into it, and it keeps the
        server out of the way of domestic services that geo-check.
      '';
      example = false;
    };

    blockPrivate = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Send traffic destined for private and loopback addresses to the block
        outbound.

        On by default: without it, anyone holding an inbound credential can
        reach the server's LAN, its localhost services, and the local proxy
        ports of proxy-suite itself.
      '';
      example = false;
    };

    listeners = mkOption {
      type = types.attrsOf inboundTypes.inboundType;
      default = { };
      description = ''
        Named inbound listeners. The attribute name becomes the inbound tag
        used in routing rules and in `proxy-ctl inbounds`.
      '';
      example = literalExpression ''
        {
          vless-reality = {
            type = "vless";
            port = 443;
            users = [ { uuidFile = "/run/secrets/proxy-inbound-uuid"; } ];
            flow = "xtls-rprx-vision";
            reality = {
              enable = true;
              dest = "www.microsoft.com:443";
              serverNames = [ "www.microsoft.com" ];
              privateKeyFile = "/run/secrets/proxy-inbound-reality-key";
              publicKey = "jNXH...";
              shortIds = [ "0123abcd" ];
            };
          };
        }
      '';
    };
  };
}
