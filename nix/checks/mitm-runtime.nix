# mitm.udp, mitm.attach and mitm addon load, end to end: a guest behind the gateway's
# mitm.interfaces, whose HTTP and UDP mitmproxy reads, a program attached to change both, an
# addon loaded into mitmproxy, and what the request log keeps.
{
  pkgs,
  proxySuiteModule,
}:

let
  # Its own tests are not this check's (12.3.0's fail on expired certificates).
  mitmproxy = pkgs.mitmproxy.overridePythonAttrs { doCheck = false; };
  # Public addresses: a private destination is left alone, as the LAN is.
  serverAddress = "11.0.0.1";
  gatewayOutside = "11.0.0.254";
  gatewayInside = "192.168.1.1";
  guestAddress = "192.168.1.2";
  python = "${pkgs.python3}/bin/python3";

  # The server's UDP echo, which notes who sent what: on 5056, and on 443 as QUIC would be.
  echoServer = pkgs.writeText "udp-echo-server.py" ''
    import socket
    import sys

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("0.0.0.0", int(sys.argv[1])))
    with open("/tmp/udp-peers", "a", buffering=1) as log:
        while True:
            data, peer = s.recvfrom(65535)
            log.write(f"{peer[0]} {len(data)}\n")
            s.sendto(data, peer)
  '';
  # Sends one datagram (the text, or that many bytes) to the server's echo, on 5056 or the
  # port given, and prints the answer.
  echoClient = pkgs.writeScriptBin "udp-echo" ''
    #!${python}
    import socket
    import sys

    word = sys.argv[1]
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 5056
    payload = b"x" * int(word) if word.isdigit() else word.encode()
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(3)
    s.sendto(payload, ("${serverAddress}", port))
    data, _ = s.recvfrom(65535)
    print(len(data) if word.isdigit() else data.decode())
  '';

  # Attached, changing traffic: the server's page and its datagrams.
  rewrite = pkgs.writeText "rewrite.py" ''
    class Rewrite:
        def response(self, flow):
            flow.response.content = flow.response.content.replace(b"hello from server", b"rewritten by attach")

        def udp_message(self, flow):
            message = flow.messages[-1]
            if not message.from_client:
                message.content = message.content.upper()


    addons = [Rewrite()]
  '';
  # Attached, reading: a line for each answer and datagram, as they come.
  record = pkgs.writeText "record.py" ''
    import json


    class Record:
        def __init__(self):
            self.out = open("/tmp/attach-record.jsonl", "a", buffering=1)

        def response(self, flow):
            self.out.write(json.dumps({"kind": "http", "url": flow.request.pretty_url}) + "\n")

        def udp_message(self, flow):
            message = flow.messages[-1]
            self.out.write(json.dumps({"kind": "udp", "from_client": message.from_client, "content": message.content.decode()}) + "\n")


    addons = [Record()]
  '';
  # Loaded into mitmproxy: writes where its output goes, with the option it was loaded with.
  marker = pkgs.writeText "marker.py" ''
    import os

    from mitmproxy import ctx


    class Marker:
        def load(self, loader):
            loader.add_option("marker_text", str, "", "What to write.")

        def response(self, flow):
            with open(os.path.join(os.environ["PROXY_SUITE_MITM_OUTPUT"], "marker.txt"), "a") as out:
                out.write(f"{ctx.options.marker_text} {flow.request.pretty_url}\n")


    addons = [Marker()]
  '';
  # Reads the UDP flows kept whole, after the fact.
  dumpUdp = pkgs.writeText "dump-udp.py" ''
    class Dump:
        def udp_message(self, flow):
            message = flow.messages[-1]
            print("UDP", message.from_client, message.content.decode(errors="replace"))


    addons = [Dump()]
  '';

  address = interface: ip: {
    networking.interfaces.${interface}.ipv4.addresses = [
      {
        address = ip;
        prefixLength = 24;
      }
    ];
  };
in
pkgs.testers.runNixOSTest {
  name = "proxy-suite-mitm-runtime";

  nodes = {
    server =
      { ... }:
      {
        imports = [ (address "eth1" serverAddress) ];
        virtualisation.vlans = [ 2 ];
        networking.useDHCP = false;
        networking.firewall.enable = false;
        systemd.services.udp-echo = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = "${python} ${echoServer} 5056";
        };
        systemd.services.udp-echo-443 = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = "${python} ${echoServer} 443";
        };
        services.nginx = {
          enable = true;
          virtualHosts.origin.locations."/".return = "200 'hello from server'";
        };
      };

    gateway =
      { ... }:
      {
        imports = [
          proxySuiteModule
          (address "br0" gatewayInside)
          (address "eth2" gatewayOutside)
        ];
        # The guests behind a bridge, as Waydroid's are, with bridge netfilter loaded, as
        # Docker loads it: proxy.tproxy.bridgeNetfilter = "off" keeps it from undoing the divert.
        networking.bridges.br0.interfaces = [ "eth1" ];
        # The test driver addresses each VLAN's interface; a bridge's member has none.
        networking.interfaces.eth1.ipv4.addresses = pkgs.lib.mkForce [ ];
        networking.interfaces.eth1.ipv6.addresses = pkgs.lib.mkForce [ ];
        boot.kernelModules = [ "br_netfilter" ];
        virtualisation.vlans = [
          1
          2
        ];
        virtualisation.memorySize = 2048;
        networking.useDHCP = false;
        networking.nftables.enable = true;
        # An uplink, as a host has: without a default route sing-box pauses its WireGuard
        # endpoints ("missing default interface"), mitm.udp's among them.
        networking.defaultGateway = serverAddress;
        # Runs apps pinned to mitm: a member of the group, with a user manager of their own.
        users.users.alice = {
          isNormalUser = true;
          extraGroups = [ "proxy-suite" ];
          linger = true;
        };
        services.proxy-suite = {
          enable = true;
          # A line per connection, with the rule that routed it: what a failure here shows.
          debug.logLevel = "info";
          userControl.enable = true;
          # Pin slots of both routes, for `mitm run` and `apps run --via mitm`.
          perAppRouting = {
            enable = true;
            tun.enable = true;
            tproxy.enable = true;
          };
          proxy = {
            enable = true;
            ipv6 = false;
            tproxy.bridgeNetfilter = "off";
            # Never reached: what mitmproxy reads leaves directly, but where `upstream vps`
            # sends it, which carries no UDP.
            outbounds = [
              {
                tag = "vps";
                url = "http://${serverAddress}:3128";
              }
            ];
          };
          mitm = {
            enable = true;
            package = mitmproxy;
            upstream = "direct";
            interfaces = [ "br0" ];
            udp.enable = true;
            requestLog = {
              enable = true;
              bodies = true;
            };
          };
        };
        environment.systemPackages = [
          mitmproxy
          pkgs.jq
          echoClient
        ];
      };

    guest =
      { ... }:
      {
        imports = [ (address "eth1" guestAddress) ];
        virtualisation.vlans = [ 1 ];
        networking.useDHCP = false;
        networking.firewall.enable = false;
        networking.defaultGateway = gatewayInside;
        environment.systemPackages = [
          echoClient
          pkgs.curl
        ];
      };
  };

  testScript = ''
    import time

    start_all()
    server.wait_for_unit("udp-echo.service")
    server.wait_for_unit("nginx.service")
    gateway.wait_for_unit("proxy-suite-socks.service")
    gateway.wait_for_unit("proxy-suite-mitm.service")
    gateway.wait_for_unit("proxy-suite-mitm-interfaces.service")
    gateway.wait_until_succeeds("test -S /run/proxy-suite-mitm/attach/attach.sock", timeout=60)
    guest.wait_for_unit("multi-user.target")

    lines = "/run/proxy-suite-mitm/requests/requests.jsonl"
    flows = "/run/proxy-suite-mitm/requests/requests.mitm"
    attach = "/run/current-system/sw/bin/proxy-ctl mitm attach"
    mitmdump = "${mitmproxy}/bin/mitmdump"

    with subtest("the guest's HTTP is read"):
        guest.wait_until_succeeds("curl -sS --fail --max-time 10 http://${serverAddress}/ | grep -q 'hello from server'", timeout=60)
        gateway.wait_until_succeeds(f"jq -e 'select(.kind == \"http\" and .url == \"http://${serverAddress}/\")' {lines}", timeout=30)

    with subtest("bridge netfilter: off, said when it is on, and off again with the divert"):
        assert gateway.succeed("sysctl -n net.bridge.bridge-nf-call-iptables").strip() == "0"
        # Turned on, as Docker does: the guest's TCP never reaches the proxy.
        gateway.succeed("sysctl -w net.bridge.bridge-nf-call-iptables=1")
        guest.fail("curl -sS --fail --max-time 5 http://${serverAddress}/")
        status = gateway.execute("proxy-ctl mitm 2>&1")[1]
        assert "br0 is a bridge and net.bridge.bridge-nf-call-iptables is on" in status, status
        gateway.succeed("systemctl restart proxy-suite-mitm-interfaces")
        assert gateway.succeed("sysctl -n net.bridge.bridge-nf-call-iptables").strip() == "0"
        guest.wait_until_succeeds("curl -sS --fail --max-time 10 http://${serverAddress}/ | grep -q 'hello from server'", timeout=30)

    with subtest("the guest's UDP goes through mitmproxy and back"):
        out = guest.wait_until_succeeds("udp-echo ping", timeout=60)
        assert out.strip() == "ping", out
        # A whole 1500-byte packet's worth: one datagram through the tunnel.
        out = guest.succeed("udp-echo 1472")
        assert out.strip() == "1472", out
        # It leaves from the gateway, through the backend.
        server.succeed("grep -q '^${gatewayOutside} 1472$' /tmp/udp-peers")
        # mitmproxy's own socket marked by its user, and sent back on lo to the backend: any UDP
        # of that user's comes back through it, past the reverse path check.
        gateway.succeed("nft list table inet proxy_suite_mitm | grep -q \"meta skuid != $(id -u proxy-suite-mitm) return\"")
        out = gateway.succeed(
            "${pkgs.util-linux}/bin/setpriv --reuid=proxy-suite-mitm --regid=proxy-suite-mitm --clear-groups"
            " ${python} -c 'import socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(5);"
            " s.sendto(b\"own\", (\"${serverAddress}\", 5056)); print(s.recvfrom(100)[0].decode())'"
        )
        assert out.strip() == "own", out
        gateway.succeed("ip rule | grep -q '^8987:.*fwmark 0x5b00 lookup 104'")
        # mitmproxy logs its WireGuard client's configuration as it starts: not the key.
        gateway.succeed("journalctl -u proxy-suite-mitm | grep -q 'WireGuard'")
        gateway.fail("journalctl -u proxy-suite-mitm | grep -q PrivateKey")

    with subtest("UDP leaves by mitm.upstream"):
        # The vps outbound carries no UDP: chosen, the datagrams go nowhere.
        gateway.succeed("proxy-ctl mitm upstream vps")
        guest.wait_until_fails("udp-echo blocked", timeout=30)
        gateway.succeed("proxy-ctl mitm upstream direct")
        guest.wait_until_succeeds("udp-echo again | grep -q again", timeout=30)

    with subtest("an attached program reads the flows live"):
        gateway.succeed(f"systemd-run --unit attach-record {attach} -- {mitmdump} -s ${record}")
        gateway.wait_until_succeeds("journalctl -u proxy-suite-mitm | grep -q 'attach: .* attached'", timeout=30)
        guest.succeed("udp-echo live")
        gateway.wait_until_succeeds(
            "jq -e 'select(.kind == \"udp\" and .from_client == false and .content == \"live\")' /tmp/attach-record.jsonl",
            timeout=15,
        )
        guest.succeed("curl -sS --fail --max-time 10 http://${serverAddress}/live")
        gateway.wait_until_succeeds("jq -e 'select(.kind == \"http\" and .url == \"http://${serverAddress}/live\")' /tmp/attach-record.jsonl", timeout=15)

    with subtest("an attached program changes what is sent on"):
        gateway.succeed(f"systemd-run --unit attach-rewrite {attach} --modify -- {mitmdump} -q -s ${rewrite}")
        gateway.wait_until_succeeds("journalctl -u proxy-suite-mitm | grep -q 'changing traffic) attached'", timeout=30)
        guest.wait_until_succeeds("curl -sS --fail --max-time 10 http://${serverAddress}/ | grep -q 'rewritten by attach'", timeout=30)
        out = guest.succeed("udp-echo quiet")
        assert out.strip() == "QUIET", out
        # The reader is sent what was sent on.
        gateway.wait_until_succeeds("jq -e 'select(.kind == \"udp\" and .content == \"QUIET\")' /tmp/attach-record.jsonl", timeout=15)
        # Gone, traffic is as it was.
        gateway.succeed("systemctl stop attach-rewrite")
        guest.wait_until_succeeds("curl -sS --fail --max-time 10 http://${serverAddress}/ | grep -q 'hello from server'", timeout=30)
        assert guest.succeed("udp-echo plain").strip() == "plain"

    def alice(command):
        """As a member of the group, in their user manager, as `apps run` needs."""
        return f"su - alice -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) {command}'"

    with subtest("a pinned app's UDP goes through mitmproxy, QUIC refused, on either route"):
        gateway.wait_for_unit("user@1000.service")
        for route in ("tproxy", "tun"):
            backend = {"tproxy": "proxy-suite-socks", "tun": "proxy-suite-per-app-tun"}[route]
            # Pinned straight out first: the slot carries UDP at all. On TProxy's, its packets
            # come back on lo from this host's address, past the reverse path check.
            status, out = gateway.execute(alice(f"proxy-ctl apps run --via direct --route {route} -- udp-echo base-{route}"))
            if status != 0:
                print(gateway.execute(f"journalctl -u {backend} --no-pager | tail -40")[1])
            assert out.strip() == f"base-{route}", out
            word = f"pinned-{route}"
            status, out = gateway.execute(alice(f"proxy-ctl apps run --via mitm --route {route} -- udp-echo {word}"))
            if status != 0:
                print(gateway.execute(f"journalctl -u {backend} --no-pager | tail -40")[1])
                print(gateway.execute("journalctl -u proxy-suite-mitm --no-pager | tail -20")[1])
            assert out.strip() == word, out
            # The reader attached sees it: it went through mitmproxy.
            gateway.wait_until_succeeds(
                f"jq -e 'select(.kind == \"udp\" and .from_client == false and .content == \"{word}\")' /tmp/attach-record.jsonl",
                timeout=15,
            )
            gateway.fail(alice(f"proxy-ctl apps run --via mitm --route {route} -- udp-echo quic-{route} 443"))
        # `mitm run`: the same, through a pin slot.
        assert gateway.succeed(alice("proxy-ctl mitm run -- udp-echo mitm-run")).strip() == "mitm-run"

    with subtest("an addon loaded into mitmproxy, and how long UDP waits for its restart"):
        gateway.succeed("proxy-ctl mitm addon load ${marker} --name marker --set marker_text=seen")
        gateway.succeed("proxy-ctl mitm addon | grep -q marker")
        began = time.monotonic()
        guest.wait_until_succeeds("udp-echo back | grep -q back", timeout=90)
        print(f"UDP through mitmproxy again {time.monotonic() - began:.1f}s after its restart")
        guest.succeed("curl -sS --fail --max-time 10 http://${serverAddress}/marked")
        gateway.wait_until_succeeds("grep -q '^seen http://${serverAddress}/marked$' /run/proxy-suite-mitm/requests/addons/marker.txt", timeout=15)
        # The reader attaches again by itself.
        gateway.wait_until_succeeds("journalctl -u attach-record | grep -q 'attached to mitmproxy' && test $(journalctl -u attach-record | grep -c 'attached to mitmproxy') -ge 2", timeout=30)
        gateway.succeed("proxy-ctl mitm addon unload marker")
        gateway.fail("proxy-ctl mitm addon | grep -q marker")

    with subtest("the request log keeps the UDP flows, after the fact"):
        # mitmproxy restarted as the addon was unloaded: the tunnel comes back first.
        guest.wait_until_succeeds("udp-echo kept-after", timeout=90)
        # A UDP flow ends after 20 idle seconds.
        gateway.wait_until_succeeds(
            f"jq -e 'select(.kind == \"udp\" and .server == \"${serverAddress}:5056\" and .messages_from_server == 1 and .bytes_from_client == 10)' {lines}",
            timeout=60,
        )
        out = gateway.succeed(f"{mitmdump} -nr {flows} -q -s ${dumpUdp}")
        assert "UDP True kept-after" in out and "UDP False kept-after" in out, out
  '';
}
