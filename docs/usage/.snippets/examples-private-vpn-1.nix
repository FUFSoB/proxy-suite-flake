{ ... }:
let
  interface = "awg0";
  serverAddress = "10.77.77.1";
  privateDomains = [ "mail.example.com" ];
in
{
  services.proxy-suite = {
    enable = true;
    proxy = {
      enable = true;
      outbounds = [ { tag = "primary"; urlFile = "/run/secrets/proxy-primary-url"; } ];
    };

    inbounds = {
      enable = true;
      routing.via = "proxy";
      listeners.vpn = {
        type = "amneziawg";
        port = 51820;
        # Fixed addresses, so firewall rules and DNS can name each device. Keys are
        # generated on first start.
        users = [
          { name = "laptop"; address = "10.77.77.2"; }
          { name = "phone"; address = "10.77.77.3"; }
        ];
        amneziaWg = {
          # Devices also reach this host, its LAN and each other, directly.
          mode = "lan";
          interfaceName = interface;
          subnet = "10.77.77.0/24";
          subnet6 = "fd77:77:77::/64";
          mtu = 1400;
          dns = [ serverAddress ];
          # Optional: a fixed server key, so client configs survive a reinstall.
          privateKeyFile = "/run/secrets/awg-server-key";
        };
      };
    };
  };

  # Private names for VPN clients; everything else is forwarded to 1.1.1.1.
  services.dnsmasq = {
    enable = true;
    resolveLocalQueries = false;
    settings = {
      bind-dynamic = true;
      interface = interface;
      listen-address = serverAddress;
      no-resolv = true;
      server = [ "1.1.1.1" ];
      address = map (domain: "/${domain}/${serverAddress}") privateDomains;
    };
  };
  # The interface comes and goes with the listener.
  systemd.services.dnsmasq = {
    after = [ "proxy-suite-inbounds-awg.service" ];
    wants = [ "proxy-suite-inbounds-awg.service" ];
  };
}