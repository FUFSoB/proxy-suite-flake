{
  pkgs,
  nixpkgs,
  proxySuiteModule,
}:

let
  keys = import "${nixpkgs}/nixos/tests/wireguard/snakeoil-keys.nix";
  awgPackages = import ../../pkgs/amneziawg.nix { inherit pkgs; };
  obfuscation = {
    jc = 5;
    jmin = 10;
    jmax = 42;
    s1 = 60;
    s2 = 90;
  };
  network = address: {
    networking.useDHCP = false;
    networking.interfaces.eth1.ipv4.addresses = [
      {
        inherit address;
        prefixLength = 24;
      }
    ];
  };
  client =
    address: userspaceOnly:
    {
      imports = [ proxySuiteModule ];
      services.proxy-suite = {
        enable = true;
        amneziaWg = {
          enable = true;
          kernelModulePackage = if userspaceOnly then null else awgPackages.kernelModule pkgs.linuxPackages;
          profiles.test = {
            interfaceName = "awg-test";
            settings = {
              addresses = [ "10.23.42.2/32" ];
              privateKey = keys.peer1.privateKey;
              obfuscation = { inherit (obfuscation) s1 s2; };
              obfuscationFile = "/run/awg-obfuscation.json";
              peers = [
                {
                  publicKey = keys.peer0.publicKey;
                  endpoint = "192.168.0.1:23542";
                  allowedIPs = [ "10.23.42.1/32" ];
                  persistentKeepalive = 5;
                }
              ];
            };
          };
          profiles.broken = {
            interfaceName = "awg-broken";
            settings = {
              addresses = [ "10.99.42.2/32" ];
              privateKey = keys.peer1.privateKey;
              inherit obfuscation;
              peers = [
                {
                  publicKey = keys.peer0.publicKey;
                  endpoint = "192.168.0.254:23542";
                  allowedIPs = [ "10.99.42.1/32" ];
                }
              ];
            };
          };
        };
      };
    }
    // network address;
in
pkgs.testers.runNixOSTest {
  name = "proxy-suite-amneziawg-runtime";

  nodes = {
    server =
      { ... }:
      {
        imports = [ (network "192.168.0.1") ];
        networking.firewall.allowedUDPPorts = [ 23542 ];
        networking.wg-quick.interfaces.awg-server = {
          type = "amneziawg";
          address = [ "10.23.42.1/32" ];
          listenPort = 23542;
          privateKey = keys.peer0.privateKey;
          extraOptions = {
            Jc = obfuscation.jc;
            Jmin = obfuscation.jmin;
            Jmax = obfuscation.jmax;
            S1 = obfuscation.s1;
            S2 = obfuscation.s2;
          };
          peers = [
            {
              publicKey = keys.peer1.publicKey;
              allowedIPs = [ "10.23.42.2/32" ];
            }
          ];
        };
      };

    kernel = client "192.168.0.2" false;
    userspace = client "192.168.0.3" true;
  };

  testScript = ''
    start_all()
    server.wait_for_unit("wg-quick-awg-server.service")

    # Provision the partial secret after boot, outside the generated manifest.
    for machine in (kernel, userspace):
        machine.succeed("""umask 077; echo '${
          builtins.toJSON { inherit (obfuscation) jc jmin jmax; }
        }' > /run/awg-obfuscation.json""")

    with subtest("packaged kernel module"):
        kernel.succeed("systemctl start proxy-suite-awg-test.service")
        kernel.succeed("test $(stat -c %a /run/proxy-suite-awg-test/awg-test.conf) = 600")
        kernel.succeed("test $(stat -c %a /run/proxy-suite-awg-test) = 700")
        kernel.succeed("ip -d link show awg-test | grep -q amneziawg")
        kernel.succeed("ping -c 5 10.23.42.1")
        kernel.succeed("test $(awg show awg-test latest-handshakes | awk '{print $2}') -gt 0")
        kernel.succeed("systemctl stop proxy-suite-awg-test.service")
        kernel.fail("ip link show awg-test")

    with subtest("automatic userspace fallback"):
        userspace.fail("modprobe -n amneziawg")
        userspace.succeed("systemctl start proxy-suite-awg-test.service")
        userspace.succeed("test $(stat -c %a /run/proxy-suite-awg-test/awg-test.conf) = 600")
        userspace.succeed("test $(stat -c %a /run/proxy-suite-awg-test) = 700")
        userspace.succeed("test -r /sys/class/net/awg-test/tun_flags")
        userspace.succeed("ping -c 5 10.23.42.1")
        userspace.succeed("test $(awg show awg-test latest-handshakes | awk '{print $2}') -gt 0")
        userspace.succeed("systemctl stop proxy-suite-awg-test.service")
        userspace.fail("ip link show awg-test")

    with subtest("a profile added at runtime"):
        # The same client as "test", as a .conf pasted in rather than declared.
        userspace.succeed("""umask 077; cat > /root/rt.conf <<'EOF'
    [Interface]
    PrivateKey = ${keys.peer1.privateKey}
    Address = 10.23.42.2/32
    Jc = ${toString obfuscation.jc}
    Jmin = ${toString obfuscation.jmin}
    Jmax = ${toString obfuscation.jmax}
    S1 = ${toString obfuscation.s1}
    S2 = ${toString obfuscation.s2}

    [Peer]
    PublicKey = ${keys.peer0.publicKey}
    Endpoint = 192.168.0.1:23542
    AllowedIPs = 10.23.42.1/32
    PersistentKeepalive = 5
    EOF""")
        userspace.succeed("proxy-ctl awg add rt /root/rt.conf")
        userspace.succeed("test $(stat -c %a /var/lib/proxy-suite/amneziawg.d/rt.conf) = 600")
        userspace.succeed("proxy-ctl awg list | grep -E 'rt +inactive +runtime'")
        userspace.succeed("proxy-ctl awg on rt")
        userspace.succeed("ip link show awg-rt")
        userspace.succeed("ping -c 5 10.23.42.1")
        userspace.succeed("systemctl is-active proxy-suite-awg-watchdog@rt.service")
        # A declared profile takes over: they share the peer, and only one global tunnel runs.
        userspace.succeed("systemctl start proxy-suite-awg-test.service")
        userspace.fail("systemctl is-active proxy-suite-awg@rt.service")
        userspace.fail("ip link show awg-rt")
        userspace.succeed("systemctl stop proxy-suite-awg-test.service")
        # Hooks are refused whoever adds the config, and nothing is written.
        userspace.fail("sed 's/^Address/PostUp = touch \\/pwned\\nAddress/' /root/rt.conf | proxy-ctl awg add hooked -")
        userspace.fail("test -e /var/lib/proxy-suite/amneziawg.d/hooked.conf")
        userspace.succeed("proxy-ctl awg rm rt")
        userspace.fail("test -e /var/lib/proxy-suite/amneziawg.d/rt.conf")

    with subtest("failed handshake rolls back userspace routing"):
        userspace.fail("systemctl start proxy-suite-awg-broken.service")
        userspace.fail("ip link show awg-broken")
        userspace.fail("ip route show table all | grep -F awg-broken")
        userspace.fail("ip -6 route show table all | grep -F awg-broken")
  '';
}
