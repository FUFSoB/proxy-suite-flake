{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    literalExpression
    literalMD
    mkEnableOption
    mkOption
    types
    ;
  inherit (import ./lib.nix { inherit lib; }) hostType interfaceType;
  proxyEnabled = config.services.proxy-suite.proxy.enable;
  domains =
    description:
    mkOption {
      # Each ends up in a routing rule or in a regular expression mitmproxy matches.
      type = types.listOf (types.strMatching "[A-Za-z0-9._-]+");
      default = [ ];
      inherit description;
      example = [ "example.com" ];
    };
in
{
  options.services.proxy-suite.mitm = {
    enable = mkEnableOption "mitmproxy" // {
      description = ''
        Run mitmproxy, to read the HTTP requests inside TLS. It decrypts only what is sent
        to it, and a program must trust its CA (`proxy-ctl mitm ca`) for that to work. With
        `proxy.enable` it is also an outbound tagged "mitm", which selection and autoProxy
        never pick: send traffic to it with `hosts`, `interfaces`, `listener`,
        `proxy.routing.rules` or `proxy-ctl mitm run`. Needs the sing-box or hybrid backend.
      '';
    };

    package = mkOption {
      type = types.package;
      default = pkgs.mitmproxy;
      defaultText = literalExpression "pkgs.mitmproxy";
      description = "mitmproxy package.";
    };

    port = mkOption {
      type = types.port;
      default = 18531;
      description = ''
        Loopback port mitmproxy takes the backend's connections on, with `proxy.enable`. It
        takes no login, so on a host with root only proxy-suite's daemons and root may
        connect to it; everything else comes in through `listener`.
      '';
    };

    returnPort = mkOption {
      type = types.port;
      default = 18532;
      description = ''
        Loopback port of the backend that mitmproxy sends what it has read on to, with
        `proxy.enable`. From there it leaves through `upstream`.
      '';
    };

    upstream = mkOption {
      type = types.str;
      default = if proxyEnabled then "proxy" else "direct";
      defaultText = literalMD ''`"proxy"` with `proxy.enable`, `"direct"` without'';
      description = ''
        Where intercepted traffic leaves.
        - "direct": straight from the uplink. The only choice without `proxy.enable`.
        - "proxy": through the outbound in use, as everything else does.
        - an outbound or group tag: through that one, to read a site that is blocked here.

        `proxy-ctl mitm upstream` changes it without a rebuild.
      '';
      example = "nl-vps";
    };

    hosts = domains ''
      Domains, with their subdomains, sent to mitmproxy wherever they come from. Needs
      `proxy.enable`. `proxy-ctl mitm hosts add` adds more without a rebuild.
    '';

    ignoreHosts = domains ''
      Domains, with their subdomains, that mitmproxy passes on undecrypted: for programs that
      pin their certificates.
    '';

    listener = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Listen for programs and devices pointed straight at mitmproxy: everything that
          connects here is intercepted. An HTTP proxy, and SOCKS5 too with `proxy.enable`,
          its UDP read with `udp.enable`.
        '';
      };

      address = mkOption {
        type = hostType;
        default = "127.0.0.1";
        description = ''
          Address of that listener. Use "0.0.0.0" or a LAN address to intercept another
          device, which then opens http://mitm.it for the CA; set `auth` with it.
        '';
        example = "0.0.0.0";
      };

      port = mkOption {
        type = types.port;
        # Beside the local proxy's 1080: 8080 is where development servers listen.
        default = 1088;
        description = "Port of that listener.";
      };

      auth = {
        username = mkOption {
          type = types.nullOr (types.strMatching "[^[:space:]:]+");
          default = null;
          description = "Username for that listener. Needs `passwordFile`.";
          example = "mitm-user";
        };

        passwordFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "File with the password for that listener, a single word.";
          example = "/run/secrets/proxy-suite-mitm-password";
        };
      };

      openFirewall = mkOption {
        type = types.bool;
        default = false;
        description = "Open the firewall for that listener. Needs an `address` off loopback.";
      };
    };

    interfaces = mkOption {
      type = types.listOf interfaceType;
      default = [ ];
      description = ''
        Interfaces of containers, virtual machines or LAN devices that use this host as their
        gateway: all TCP they send is intercepted, with nothing to set up in them but the CA.
        UDP to port 443 is refused, so they fall back from QUIC; the rest of their UDP is
        forwarded as usual, or with `udp.enable` read too. Turns on IP forwarding. Needs
        `proxy.enable`, root and, on NixOS, the nftables firewall.
      '';
      example = [ "waydroid0" ];
    };

    interfacesPort = mkOption {
      type = types.port;
      default = 18529;
      description = "Loopback port of the backend that `interfaces` are diverted to.";
    };

    udp = {
      enable = mkEnableOption "reading UDP too" // {
        description = ''
          Send mitmproxy the UDP that goes to "mitm" as well: what `hosts`, `listener`
          (SOCKS5), `interfaces` and the routing rules send there. The backend hands it over
          through a WireGuard tunnel on loopback, and what mitmproxy sends on comes back to the
          backend to leave by `upstream`, as TCP does. mitmproxy reads each datagram as a
          message of a UDP flow: in mitmweb, the request log and attached programs. QUIC (UDP
          to port 443) is still refused, so browsers take TCP. Needs `proxy.enable`, root
          and, on NixOS, the nftables firewall.
        '';
      };

      port = mkOption {
        type = types.port;
        default = 18527;
        description = "Loopback UDP port of mitmproxy's WireGuard listener, which the backend dials.";
      };

      returnPort = mkOption {
        type = types.port;
        default = 18528;
        description = ''
          Loopback port of the backend that the UDP mitmproxy sends on is diverted to, to leave
          by `upstream`.
        '';
      };

      relayPort = mkOption {
        type = types.port;
        default = 18526;
        description = ''
          Loopback port of the backend's SOCKS5 listener that the TUN backends (global TUN,
          per-app TUN and its pinned apps) hand their UDP for mitmproxy to: the tunnel into it
          has one end, in that backend. It takes the hop login.
        '';
      };
    };

    attach = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Let programs attach to mitmproxy, to read the flows live and change them:
          `proxy-ctl mitm attach -- mitmdump -s addon.py` runs a mitmdump, mitmproxy or
          mitmweb of your own, with your addons and your Python packages, that sees each
          request, answer and WebSocket, TCP or UDP message as it comes. With `--modify`
          what its addons change is what is sent on. Whoever reads the request log and opens
          mitmweb may attach: the groups whose `userControl` scopes hold `mitm`, and root.
        '';
      };

      timeout = mkOption {
        type = types.numbers.positive;
        default = 5;
        description = ''
          Seconds an attached program that changes traffic has to answer each hook, unless it
          asks for more (`--set attach_timeout=…`). A late one is detached, and the flow goes on
          unchanged.
        '';
      };
    };

    addons = {
      userControl = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Let the groups whose `userControl` scopes hold `mitm` load addons into mitmproxy
          itself (`proxy-ctl mitm addon load`), not only root. An addon there runs as
          mitmproxy's user, which reads the CA's key: whoever loads one can sign certificates
          with it. Prefer `proxy-ctl mitm attach`, which runs your addons as you.
        '';
      };
    };

    pythonPackages = mkOption {
      type = types.functionTo (types.listOf types.package);
      default = _: [ ];
      defaultText = literalExpression "ps: [ ]";
      description = ''
        Python packages for the addons mitmproxy itself runs: `extraOptions.scripts` and those
        `proxy-ctl mitm addon load` loads. From `pkgs.python3.pkgs`, the Python mitmproxy is
        built with. Not needed for `attach`, whose addons run in your own mitmdump.
      '';
      example = literalExpression "ps: [ ps.msgpack ps.pycryptodome ]";
    };

    web = {
      enable = mkEnableOption "mitmweb, mitmproxy's web interface" // {
        description = ''
          Run mitmweb, which shows the requests in a browser, instead of mitmdump, which
          logs a line for each. `proxy-ctl mitm web` prints its address and password. It
          shows passwords and cookies as they are sent.
        '';
      };

      port = mkOption {
        type = types.port;
        default = 18536;
        description = "Loopback port of mitmweb.";
      };

      passwordFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          File with mitmweb's password. `null`: one is generated at first start and kept in
          the state directory.
        '';
        example = "/run/secrets/proxy-suite-mitmweb-password";
      };
    };

    saveFlows = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Keep every request and answer, bodies included, in the state directory
        (`flows.mitm`, for `mitmproxy -r`). It grows until deleted.
      '';
    };

    requestLog = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Append a line of JSON for each request to `requests.jsonl`, for jq and the like: the
          time, client, method, URL, status or error, duration, sizes and content type. A
          WebSocket, TCP or UDP flow gets one as it ends, with the messages and bytes each way.
          `proxy-ctl mitm requests on|off` switches it without a rebuild, and
          `proxy-ctl mitm requests follow` streams it (`> session.jsonl` to keep one).
        '';
      };

      bodies = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Also write each request whole, bodies included, as mitmproxy's flows to
          `requests.mitm` beside that log: for an addon of your own, run by you with what it
          needs, `proxy-ctl mitm requests follow --bodies | mitmdump -nr - -s addon.py`.
          `proxy-ctl mitm requests bodies on|off` switches it without a rebuild. Rotated
          and readable as the log is, whether or not that is on. A WebSocket, TCP or UDP flow
          is written in parts as it goes, at each MiB or ten seconds, each with the messages
          since the last and the flow's id. For the flows live as they come, attach instead.
        '';
      };

      persist = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Keep that log across restarts and reboots, in `mitm-requests` beside the state
          directory. Without, it is in memory under the runtime directory and gone when
          mitmproxy stops. Either way the groups whose `userControl` scopes hold `mitm` read
          it, as they open mitmweb; nobody else but root and mitmproxy's user.
        '';
      };

      maxSizeMiB = mkOption {
        type = types.numbers.positive;
        default = 64;
        description = "Rotate that log at this size, in MiB, to `requests.jsonl.1`, replacing the one there.";
      };

      headers = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Put the requests' and answers' headers in that log too, as `[name, value]` pairs:
          cookies and logins among them.
        '';
      };
    };

    ca = {
      certFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Certificate of the CA mitmproxy signs with, in PEM. `null`: a CA is generated at
          first start and kept in the state directory, readable by mitmproxy alone. Set it,
          with `keyFile`, for a CA the system already trusts, such as one listed in
          `security.pki.certificateFiles`.
        '';
        example = "/run/secrets/proxy-suite-mitm-ca.crt";
      };

      keyFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Private key of that CA, in PEM and without a passphrase. Needs `certFile`.";
        example = "/run/secrets/proxy-suite-mitm-ca.key";
      };
    };

    extraOptions = mkOption {
      type = types.attrsOf (
        types.oneOf [
          types.bool
          types.int
          types.str
          (types.listOf types.str)
        ]
      );
      default = { };
      description = ''
        More of mitmproxy's options, as in its `config.yaml`. They are set after
        proxy-suite's own and override them, but for `scripts`, which are added to its own.
      '';
      example = {
        anticache = true;
        flow_detail = 2;
      };
    };
  };
}
