# zapret2's learning and verdicts against a censor in the middle (detect.lua): a router
# that blocks one site two connections out of three, cuts another after 16 KB, and drops
# every connection to an address. The client must learn the first two, record that the
# first works once it gets through, and hand the address to the proxy until it answers.
# Public test ranges throughout: detect.lua never judges private addresses.
{
  pkgs,
  proxySuiteModule,
}:

let
  state = "/var/lib/proxy-suite/zapret2";
  direct = "/var/lib/proxy-suite/zapret2-direct";

  cert = pkgs.runCommand "zapret2-runtime-cert" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir -p "$out"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=fine.test \
      -addext "subjectAltName=DNS:fine.test,DNS:flaky.test,DNS:stall.test,DNS:blocked.test" \
      -keyout "$out/key.pem" -out "$out/cert.pem"
  '';
  # Big enough for the success detector (past 4 KB in) and, at /big, for the cutoff.
  site = pkgs.runCommand "zapret2-runtime-site" { } ''
    mkdir -p "$out"
    head -c 65536 /dev/zero | tr '\0' a >"$out/index.html"
    head -c 1048576 /dev/zero | tr '\0' b >"$out/big"
  '';

  address = interface: addresses: {
    networking.interfaces.${interface}.ipv4.addresses = map (address: {
      inherit address;
      prefixLength = 24;
    }) addresses;
  };
in
pkgs.testers.runNixOSTest {
  name = "proxy-suite-zapret2-runtime";

  nodes = {
    server = {
      imports = [
        (address "eth1" [
          "203.0.113.2"
          "203.0.113.3"
        ])
      ];
      virtualisation.vlans = [ 2 ];
      networking.useDHCP = false;
      networking.defaultGateway = "203.0.113.1";
      networking.firewall.allowedTCPPorts = [ 443 ];
      services.nginx = {
        enable = true;
        virtualHosts.default = {
          default = true;
          onlySSL = true;
          sslCertificate = "${cert}/cert.pem";
          sslCertificateKey = "${cert}/key.pem";
          root = site;
        };
      };
    };

    router = {
      imports = [
        (address "eth1" [ "198.51.100.1" ])
        (address "eth2" [ "203.0.113.1" ])
      ];
      virtualisation.vlans = [
        1
        2
      ];
      networking.useDHCP = false;
      networking.firewall.enable = false;
      networking.nftables.enable = false;
      boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
      environment.systemPackages = [ pkgs.iptables ];
    };

    client = {
      imports = [
        proxySuiteModule
        (address "eth1" [ "198.51.100.2" ])
      ];
      virtualisation.vlans = [ 1 ];
      networking.useDHCP = false;
      networking.defaultGateway = "198.51.100.1";
      networking.hosts."203.0.113.2" = [
        "fine.test"
        "flaky.test"
        "stall.test"
      ];
      networking.hosts."203.0.113.3" = [ "blocked.test" ];
      environment.systemPackages = [ pkgs.curl ];
      services.proxy-suite = {
        enable = true;
        # An outbound to hand what zapret2 cannot fix to; nothing here dials it.
        proxy = {
          enable = true;
          backend = "sing-box";
          outbounds = [
            {
              tag = "primary";
              url = "http://192.0.2.1:8080";
            }
          ];
        };
        zapret = {
          enable = true;
          engine = "zapret2";
          zapret2 = {
            strategySource = "z2k";
            # The probe dials the internet.
            cutoff.enable = false;
          };
        };
      };
    };
  };

  testScript = ''
    start_all()
    server.wait_for_unit("nginx.service")
    router.wait_for_unit("multi-user.target")

    # The censor. Per connection, by the name in its ClientHello: flaky.test passes one
    # in three; stall.test is cut once 16 KB came back; 203.0.113.3 never answers.
    router.succeed(
      "iptables -t mangle -A FORWARD -p tcp --dport 443 -m connmark --mark 0 -m string --string flaky.test --algo bm"
      " -m statistic --mode nth --every 3 --packet 0 -j CONNMARK --set-mark 3",
      "iptables -t mangle -A FORWARD -p tcp --dport 443 -m connmark --mark 0 -m string --string flaky.test --algo bm"
      " -j CONNMARK --set-mark 2",
      "iptables -t mangle -A FORWARD -p tcp --dport 443 -m connmark --mark 0 -m string --string stall.test --algo bm"
      " -j CONNMARK --set-mark 4",
      "iptables -A FORWARD -m connmark --mark 2 -j DROP",
      "iptables -A FORWARD -p tcp --sport 443 -m connmark --mark 4"
      " -m connbytes --connbytes 16384: --connbytes-dir reply --connbytes-mode bytes -j DROP",
      "iptables -A FORWARD -d 203.0.113.3 -p tcp --syn -j DROP",
      # Byte counts for connbytes; the rules above loaded conntrack.
      "sysctl -w net.netfilter.nf_conntrack_acct=1",
    )

    client.wait_for_unit("proxy-suite-zapret.service")
    client.wait_until_succeeds("curl -sk --max-time 5 -o /dev/null https://fine.test/")

    def curl(host, path="/", seconds=8):
        client.execute(f"curl -sk --noproxy '*' --max-time {seconds} -o /dev/null https://{host}{path}")

    def learned(host):
        return f"grep -qx {host} ${state}/zapret-hosts-auto.txt"

    with subtest("a site blocked two times in three is learned, successes in between"):
        for _ in range(9):
            curl("flaky.test")
        client.wait_until_succeeds(learned("flaky.test"), timeout=60)

    with subtest("a transfer cut after 16 KB is learned"):
        for _ in range(4):
            curl("stall.test", "/big", 12)
        client.wait_until_succeeds(learned("stall.test"), timeout=60)

    with subtest("a working site is not"):
        for _ in range(4):
            curl("fine.test", "/big")
        client.fail(learned("fine.test"))

    with subtest("an address that never answers goes to the proxy, until it does"):
        for _ in range(4):
            curl("blocked.test", "/", 5)
        client.wait_until_succeeds("grep -qP '^blocked\\t203\\.0\\.113\\.3\\tip' ${state}/verdicts.tsv", timeout=60)
        client.wait_until_succeeds("grep -qF 203.0.113.3/32 ${direct}/proxy.json", timeout=60)
        client.succeed("proxy-ctl zapret auto | grep -F 'blocked by address'")
        router.succeed("iptables -D FORWARD -d 203.0.113.3 -p tcp --syn -j DROP")
        curl("blocked.test")
        client.wait_until_succeeds("grep -qP '^reachable\\t203\\.0\\.113\\.3\\tip' ${state}/verdicts.tsv", timeout=60)
        client.wait_until_succeeds("! grep -qF 203.0.113.3 ${direct}/proxy.json", timeout=60)

    with subtest("a learned site goes direct once a strategy gets through for it"):
        for _ in range(9):
            curl("flaky.test")
        client.wait_until_succeeds("grep -qP '^works\\tflaky\\.test\\ttcp' ${state}/verdicts.tsv", timeout=60)
        client.wait_until_succeeds("grep -qF '\"flaky.test\"' ${direct}/direct.json", timeout=60)
        # stall.test never got through: it keeps the proxy's route.
        client.fail("grep -qF stall.test ${direct}/direct.json")
  '';
}
