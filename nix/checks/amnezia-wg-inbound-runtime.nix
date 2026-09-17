{
  pkgs,
  proxySuiteModule,
}:

let
  # Clients reach the server on VLAN 1, and nothing else but through it. Public addresses:
  # private destinations never reach XRay.
  serverAddress = "11.0.0.1";
  # VLAN 2: the internet, as seen from the server, and the server's LAN in one.
  serverUplink = "11.0.1.1";
  outsideAddress = "11.0.1.3";
  serverLanAddress = "192.168.2.1";
  lanAddress = "192.168.2.2";

  # Forced: the test driver's own 192.168.<vlan>.<node> addresses would share subnets.
  network = interface: addresses: {
    networking.useDHCP = false;
    networking.interfaces.${interface}.ipv4.addresses = pkgs.lib.mkForce (
      map (address: {
        inherit address;
        prefixLength = 24;
      }) addresses
    );
  };

  users = names: map (name: { inherit name; }) names;

  # Each client imports what the server hands out: the .conf, or the vpn:// link.
  client =
    address:
    { ... }:
    {
      imports = [
        proxySuiteModule
        (network "eth1" [ address ])
      ];
      services.proxy-suite = {
        enable = true;
        amneziaWg = {
          enable = true;
          # The server covers the kernel module.
          kernelModulePackage = null;
          profiles.home = {
            interfaceName = "awg-home";
            configFile = "/run/awg/home.conf";
          };
          profiles.roam = {
            interfaceName = "awg-roam";
            vpnFile = "/run/awg/roam.vpn";
          };
        };
      };
    };
in
pkgs.testers.runNixOSTest {
  name = "proxy-suite-amneziawg-inbounds-runtime";

  nodes = {
    server =
      { ... }:
      {
        imports = [
          proxySuiteModule
          (network "eth1" [ serverAddress ])
          (network "eth2" [
            serverUplink
            serverLanAddress
          ])
        ];
        virtualisation.vlans = [
          1
          2
        ];

        services.proxy-suite = {
          enable = true;
          proxy.enable = false;
          inbounds = {
            enable = true;
            inherit serverAddress;
            routing.via = "direct";
            openFirewall = true;
            listeners.home = {
              type = "amneziawg";
              port = 51820;
              users = users [
                "phone"
                "laptop"
              ];
              amneziaWg = {
                mode = "lan";
                subnet6 = "fd66:66::/64";
                dns = [ ];
              };
            };
            listeners.roam = {
              type = "amneziawg";
              port = 51821;
              users = users [
                "tablet"
                "watch"
              ];
              amneziaWg = {
                subnet = "10.67.0.0/24";
                dns = [ ];
              };
            };
          };
        };
        environment.systemPackages = [ pkgs.jq ];
      };

    # The internet and the server's LAN in one: a web server answering with the caller's address.
    outside =
      { ... }:
      {
        imports = [
          (network "eth1" [
            outsideAddress
            lanAddress
          ])
        ];
        virtualisation.vlans = [ 2 ];
        services.nginx = {
          enable = true;
          virtualHosts.default = {
            default = true;
            locations."/".return = "200 '$remote_addr'";
          };
        };
        networking.firewall.allowedTCPPorts = [ 80 ];
      };

    alice = client "11.0.0.2";
    bob = client "11.0.0.4";
  };

  testScript = ''
    start_all()
    server.wait_for_unit("proxy-suite-inbounds-awg.service")
    server.wait_for_unit("proxy-suite-inbounds.service")
    outside.wait_for_unit("nginx.service")

    def import_profiles(machine, home_user, roam_user):
        home = server.succeed(f"proxy-ctl inbounds link home {home_user} --config")
        roam = server.succeed(f"proxy-ctl inbounds link roam {roam_user}").strip()
        assert roam.startswith("vpn://"), roam
        machine.succeed("mkdir -p -m 700 /run/awg")
        machine.succeed(f"cat > /run/awg/home.conf <<'EOF'\n{home}\nEOF")
        machine.succeed(f"echo '{roam}' > /run/awg/roam.vpn")

    def fetch(machine, host):
        return machine.succeed(f"curl -sS --fail --max-time 10 http://{host}/").strip()

    # XRay dials out, so the web server sees the server.
    def through_server(machine, timeout=60):
        machine.wait_until_succeeds(
            "test \"$(curl -sS --fail --max-time 10 http://${outsideAddress}/)\" = ${serverUplink}",
            timeout=timeout,
        )

    with subtest("state and links are generated"):
        server.succeed("test $(stat -c %a /var/lib/proxy-suite/awg-inbounds/home/state.json) = 600")
        server.succeed("ip link show awgi-home")
        server.succeed("ip link show awgi-roam")
        server.succeed("nft list table inet proxy_suite_awg_inbounds")
        server.succeed("test $(jq '[.[] | select(.type == \"amneziawg\")] | length' /run/proxy-suite-inbounds/links.json) = 4")
        server.succeed("test -n \"$(proxy-ctl inbounds link home phone --config --qr)\"")
        import_profiles(alice, "phone", "tablet")
        import_profiles(bob, "laptop", "watch")

    with subtest("lan: the internet through the listener's routing"):
        for machine in (alice, bob):
            machine.succeed("systemctl start proxy-suite-awg-home.service")
        through_server(alice)
        # Nothing but TCP and UDP can follow via.
        alice.fail("ping -c 2 -W 2 ${outsideAddress}")

    with subtest("lan: this host, its LAN and the other peers"):
        alice.succeed("ping -c 2 -W 2 10.66.0.1")
        alice.succeed("ping -c 2 -W 2 ${serverLanAddress}")
        # Masqueraded, so the LAN needs no route back.
        assert fetch(alice, "${lanAddress}") == "${serverLanAddress}"
        bob_address = bob.succeed("ip -4 -o addr show awg-home | awk '{print $4}' | cut -d/ -f1").strip()
        alice.succeed(f"ping -c 2 -W 2 {bob_address}")
        alice.succeed("ping -6 -c 2 -W 2 fd66:66::1")

    with subtest("usage and presence are recorded"):
        server.succeed("proxy-ctl inbounds online | grep phone | grep -q online")
        server.succeed("proxy-ctl inbounds online | grep laptop | grep -q online")
        server.succeed("proxy-ctl inbounds stats --by user | grep -q phone")

    with subtest("proxy: nothing but the internet"):
        for machine in (alice, bob):
            machine.succeed("systemctl start proxy-suite-awg-roam.service")
            machine.fail("ip link show awg-home")
        through_server(alice)
        alice.fail("ping -c 2 -W 2 10.67.0.1")
        alice.fail("curl -sS --fail --max-time 5 http://${lanAddress}/")
        alice.fail("ping -c 2 -W 2 ${serverLanAddress}")
        bob_address = bob.succeed("ip -4 -o addr show awg-roam | awk '{print $4}' | cut -d/ -f1").strip()
        alice.fail(f"ping -c 2 -W 2 {bob_address}")
        server.succeed("proxy-ctl inbounds online | grep tablet | grep -q online")

    with subtest("keys survive a restart"):
        before = server.succeed("jq -S .users /var/lib/proxy-suite/awg-inbounds/roam/state.json")
        server.succeed("systemctl restart proxy-suite-inbounds-awg.service")
        server.wait_for_unit("proxy-suite-inbounds.service")
        assert server.succeed("jq -S .users /var/lib/proxy-suite/awg-inbounds/roam/state.json") == before
        through_server(alice, timeout=90)
  '';
}
