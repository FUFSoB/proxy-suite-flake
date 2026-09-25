# Example: a private VPN for your own devices

An AmneziaWG server for your laptop and phone. Unlike the proxy listeners, it also reaches
the server itself and its private services, like a home VPN. Internet traffic still follows
the server's routing (`inbounds.routing.via`), so the devices get the same exits and zapret
as the server.

A small DNS server on the tunnel address answers for private names, such as a mail server
that is only reachable over the VPN.

```nix
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
```

## Adding a device

```sh
proxy-ctl inbounds link vpn phone --config --qr   # scan in the AmneziaWG app
proxy-ctl inbounds link vpn laptop --config > laptop.conf
proxy-ctl inbounds link vpn phone                 # a vpn:// link instead
```

On a laptop that also runs proxy-suite, the `.conf` becomes a profile: see
[Use an AmneziaWG config](../amneziawg.md).

## Notes

- `mode = "lan"` turns on IP forwarding. The default, `"proxy"`, gives devices the
  internet only, like the other listeners.
- Only TCP and UDP reach the internet; ping and other protocols stop at the server.
- A device that keeps its own private key can be added with `users.*.publicKey` instead;
  it gets no generated config.
