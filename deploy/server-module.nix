# A single-user VLESS server on a VPS: REALITY, TLS and WS+TLS inbounds, ACME
# certificates (for the domain, or the bare IP), SSH, and networking pinned to the
# uplink's MAC. Written for the installer ISO (deploy/iso.nix), which fills in
# host.nix, but usable on its own.
{ proxySuiteModule }:

{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

let
  inherit (lib) mkOption types;
  cfg = config.services.proxy-suite-server;
  net = cfg.network;

  certName = if cfg.domain != null then cfg.domain else cfg.publicAddress;
  certDir = "/var/lib/acme/${certName}";

  nullable =
    type: description:
    mkOption {
      type = types.nullOr type;
      default = null;
      inherit description;
    };

  addressType = types.submodule {
    options = {
      address = mkOption {
        type = types.str;
        description = "Address with prefix length, e.g. 203.0.113.10/24.";
        example = "203.0.113.10/24";
      };
      gateway = mkOption {
        type = types.str;
        description = "Default gateway. Reached on-link, so it may lie outside the subnet.";
        example = "203.0.113.1";
      };
    };
  };

  user = [
    {
      name = cfg.user;
      uuidFile = "${cfg.secretsDir}/uuid";
    }
  ];
  tls = {
    enable = true;
    certificateFile = "${certDir}/fullchain.pem";
    keyFile = "${certDir}/key.pem";
  };
in
{
  imports = [
    proxySuiteModule
    "${modulesPath}/profiles/qemu-guest.nix"
  ];

  options.services.proxy-suite-server = {
    enable = lib.mkEnableOption "the single-user VPS server profile";

    adminUser = mkOption {
      type = types.strMatching "[a-z_][a-z0-9_-]*";
      default = "admin";
      description = "Login user in wheel. Its password is set imperatively (passwd), not here.";
    };

    sshPort = mkOption {
      type = types.port;
      default = 22;
      description = "SSH port.";
    };

    bootDisk = mkOption {
      type = types.str;
      description = "Disk GRUB installs its BIOS stage to.";
      example = "/dev/vda";
    };

    network = {
      mac = mkOption {
        type = types.strMatching "([0-9a-f]{2}:){5}[0-9a-f]{2}";
        description = "MAC address of the uplink; matched instead of a name, which can change between kernels.";
        example = "52:54:00:12:34:56";
      };
      dhcp = mkOption {
        type = types.bool;
        default = false;
        description = "Take IPv4 from DHCP (and IPv6 from RA) instead of ipv4/ipv6.";
      };
      ipv4 = nullable addressType "Static IPv4.";
      ipv6 = nullable addressType "Static IPv6.";
      dns = mkOption {
        type = types.listOf types.str;
        default = [
          "1.1.1.1"
          "8.8.8.8"
        ];
        description = "DNS servers.";
      };
    };

    publicAddress = mkOption {
      type = types.strMatching "([0-9]{1,3}\\.){3}[0-9]{1,3}";
      description = "Public IPv4 clients connect to; the certificate is issued for it when domain is null.";
      example = "203.0.113.10";
    };

    domain = nullable (types.strMatching "[A-Za-z0-9.-]+") "Domain pointing at publicAddress. Null gets a short-lived Let's Encrypt certificate for the IP itself.";

    acmeEmail = nullable types.str "ACME account email.";

    user = mkOption {
      type = types.strMatching "[A-Za-z0-9_.-]+";
      default = "user";
      description = "Proxy user name: the label of its share links.";
    };

    secretsDir = mkOption {
      type = types.str;
      default = "/var/lib/proxy-suite-server";
      description = "Holds `uuid` and `reality-key` (the x25519 private key).";
    };

    reality = {
      sni = mkOption {
        type = types.str;
        default = "www.microsoft.com";
        description = "Site REALITY impersonates; must serve TLS 1.3 and HTTP/2 on 443.";
      };
      publicKey = mkOption {
        type = types.str;
        description = "x25519 public key matching secretsDir/reality-key.";
      };
      shortId = mkOption {
        type = types.strMatching "[0-9a-f]{0,16}";
        description = "REALITY short id.";
      };
    };

    wsPath = mkOption {
      type = types.strMatching "/[A-Za-z0-9/_-]*";
      description = "Path of the WS listener.";
      example = "/3f9a1c07b2e4";
    };

    onion.enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Also serve the listeners as a Tor onion service, for clients that cannot reach
        publicAddress. Its address is kept in /var/lib/proxy-suite/tor/onion; the links
        to it come from `proxy-ctl inbounds link <tag> --onion`.
      '';
    };

    ports = {
      reality = mkOption {
        type = types.port;
        default = 443;
        description = "VLESS REALITY port.";
      };
      tls = mkOption {
        type = types.port;
        default = 8443;
        description = "VLESS TLS port.";
      };
      ws = mkOption {
        type = types.port;
        default = 2053;
        description = "VLESS WS+TLS port (one Cloudflare proxies).";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    boot.loader.grub = {
      enable = true;
      device = cfg.bootDisk;
      # BIOS stage on the disk, EFI stage at the removable path: boots either way,
      # and needs no NVRAM entry the VPS may not keep.
      efiSupport = true;
      efiInstallAsRemovable = true;
    };
    boot.growPartition = true;

    networking = {
      useDHCP = false;
      useNetworkd = true;
      firewall.enable = true;
      firewall.allowedTCPPorts = [ 80 ];
      nameservers = net.dns;
    };
    systemd.network = {
      enable = true;
      networks."10-uplink" = {
        matchConfig.MACAddress = net.mac;
        # Some drivers clone the MAC onto helper links; bind the real NIC only.
        matchConfig.Type = "ether";
        networkConfig = {
          DHCP = if net.dhcp then "yes" else "no";
          IPv6AcceptRA = net.dhcp || net.ipv6 == null;
        };
        address = lib.optionals (!net.dhcp) (
          lib.optional (net.ipv4 != null) net.ipv4.address ++ lib.optional (net.ipv6 != null) net.ipv6.address
        );
        routes = lib.optionals (!net.dhcp) (
          map (a: {
            Gateway = a.gateway;
            GatewayOnLink = true;
          }) (lib.optional (net.ipv4 != null) net.ipv4 ++ lib.optional (net.ipv6 != null) net.ipv6)
        );
        linkConfig.RequiredForOnline = "routable";
      };
    };

    services.openssh = {
      enable = true;
      ports = [ cfg.sshPort ];
      settings = {
        PasswordAuthentication = true;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
      };
    };

    users.mutableUsers = true;
    users.users.${cfg.adminUser} = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
    };

    boot.kernel.sysctl = {
      "net.core.default_qdisc" = "fq";
      "net.ipv4.tcp_congestion_control" = "bbr";
    };
    zramSwap.enable = true;
    nix.settings.experimental-features = [
      "nix-command"
      "flakes"
    ];

    security.acme = {
      acceptTerms = true;
      defaults.email = cfg.acmeEmail;
      certs.${certName} = {
        domain = certName;
        listenHTTP = ":80";
        group = "proxy-suite-daemon";
        reloadServices = [ "proxy-suite-inbounds" ];
      }
      // lib.optionalAttrs (cfg.domain == null) {
        # IP certificates come only from the six-day profile; check twice a day.
        profile = "shortlived";
        renewInterval = "*-*-* 00,12:00:00";
      };
    };

    # A self-signed placeholder is in place before the first order, so REALITY does
    # not wait on ACME, and the order's success restarts the listeners.
    systemd.services.proxy-suite-inbounds = {
      wants = [ "acme-${certName}.service" ];
      after = [ "acme-${certName}.service" ];
    };

    services.proxy-suite = {
      enable = true;
      proxy.enable = false;
      tor = lib.mkIf cfg.onion.enable {
        enable = true;
        onionService.enable = true;
      };
      userControl = {
        enable = true;
        group = "wheel";
      };
      inbounds = {
        enable = true;
        serverAddress = certName;
        routing.via = "direct";
        listeners = {
          vless-reality = {
            type = "vless";
            port = cfg.ports.reality;
            users = user;
            flow = "xtls-rprx-vision";
            reality = {
              enable = true;
              dest = "${cfg.reality.sni}:443";
              serverNames = [ cfg.reality.sni ];
              privateKeyFile = "${cfg.secretsDir}/reality-key";
              inherit (cfg.reality) publicKey;
              shortIds = [ cfg.reality.shortId ];
            };
          };
          vless-tls = {
            type = "vless";
            port = cfg.ports.tls;
            users = user;
            flow = "xtls-rprx-vision";
            inherit tls;
          };
          vless-ws = {
            type = "vless";
            port = cfg.ports.ws;
            users = user;
            transport = {
              type = "ws";
              path = cfg.wsPath;
            };
            inherit tls;
          };
        };
      };
    };

    services.getty.helpLine = ''

      proxy-suite server ${certName}. Share links (as ${cfg.adminUser}):
        proxy-ctl inbounds link vless-reality --qr   (or vless-tls, vless-ws)
    ''
    + lib.optionalString cfg.onion.enable "  proxy-ctl inbounds link vless-reality --onion --qr   (through Tor)\n"
    + ''
      Network down? Log in and run: sudo proxy-suite-net
    '';

    environment.systemPackages = [
      pkgs.qrencode
      (pkgs.callPackage ./net-rescue.nix { })
    ];
  };
}
