{
  pkgs,
  proxySuiteModule,
}:

let
  # Fixed so the client can be configured against it at build time. Real
  # deployments keep these in a secret manager.
  uuid = "b831381d-6324-4d53-ad4f-8cda48b30811";
  ssPassword = "dGhpcy1pcy1hLTE2Ynl0ZS1rZXk=";
  serverAddress = "192.168.0.1";

  network = address: {
    networking.useDHCP = false;
    networking.interfaces.eth1.ipv4.addresses = [
      {
        inherit address;
        prefixLength = 24;
      }
    ];
  };
in
pkgs.testers.runNixOSTest {
  name = "proxy-suite-inbounds-runtime";

  nodes = {
    # A pure server: no client proxy stack at all.
    server =
      { ... }:
      {
        imports = [
          proxySuiteModule
          (network serverAddress)
        ];

        services.proxy-suite = {
          enable = true;
          proxy.enable = false;
          proxyInbounds = {
            enable = true;
            inherit serverAddress;
            via = "direct";
            openFirewall = true;
            listeners.vless-in = {
              type = "vless";
              port = 8443;
              users = [
                {
                  name = "tester";
                  inherit uuid;
                }
              ];
            };
            listeners.ss-in = {
              type = "shadowsocks";
              port = 8388;
              method = "2022-blake3-aes-128-gcm";
              users = [ { password = ssPassword; } ];
            };
          };
        };

        services.nginx = {
          enable = true;
          virtualHosts."origin".locations."/".return = "200 'served-from-origin'";
        };
        networking.firewall.allowedTCPPorts = [ 80 ];
      };

    client =
      { ... }:
      {
        imports = [
          proxySuiteModule
          (network "192.168.0.2")
        ];

        services.proxy-suite = {
          enable = true;
          proxy = {
            enable = true;
            xray.enable = true;
            port = 1080;
            outbounds = [
              {
                tag = "server";
                url = "vless://${uuid}@${serverAddress}:8443?type=tcp&security=none";
              }
            ];
          };
        };
      };
  };

  testScript = ''
    start_all()
    server.wait_for_unit("proxy-suite-inbounds.service")
    server.wait_for_unit("nginx.service")
    server.wait_for_open_port(8443)
    server.wait_for_open_port(8388)

    with subtest("the rendered config carries both listeners"):
        cfg = "/run/proxy-suite-inbounds/config.json"
        server.succeed(f"test $(jq -r '.inbounds | length' {cfg}) = 2")
        server.succeed(f"jq -e '.inbounds[] | select(.tag == \"vless-in\" and .port == 8443)' {cfg}")
        server.succeed(f"jq -e '.inbounds[] | select(.tag == \"ss-in\" and .port == 8388)' {cfg}")
        # Credentials live only in the runtime config, never in the store.
        server.succeed(f"test $(stat -c %a {cfg}) = 600")
        server.fail(f"grep -r '${uuid}' /nix/store/*proxy-suite-inbounds-*.json")

    with subtest("safety rules are present and ordered first"):
        cfg = "/run/proxy-suite-inbounds/config.json"
        server.succeed(f"test $(jq -r '.routing.rules[0].ruleTag' {cfg}) = inbound-block-private")
        server.succeed(f"jq -e '.routing.rules[] | select(.ruleTag == \"inbound-block-ru-domain\")' {cfg}")
        server.succeed(f"test $(jq -r '.routing.rules[-1].outboundTag' {cfg}) = direct")

    with subtest("a client reaches the origin through the inbound"):
        client.wait_for_unit("proxy-suite-socks.service")
        client.wait_for_open_port(1080)
        client.succeed(
            "curl -sS --fail --max-time 20 --proxy socks5h://127.0.0.1:1080"
            f" http://{'${serverAddress}'}/ | grep -q served-from-origin"
        )

    with subtest("blocked destinations are refused"):
        # The inbound must not become a way into the server's own loopback.
        server.succeed("jq -e '.routing.rules[] | select(.ruleTag == \"inbound-block-private\") | select(.outboundTag == \"block\")' /run/proxy-suite-inbounds/config.json")
        client.fail(
            "curl -sS --fail --max-time 15 --proxy socks5h://127.0.0.1:1080"
            " http://127.0.0.1/ 2>&1"
        )

    with subtest("share links are generated and readable by proxy-ctl"):
        links = "/run/proxy-suite-inbounds/links.json"
        server.succeed(f"test $(stat -c %a {links}) = 600")
        server.succeed(f"test $(jq -r 'length' {links}) = 2")
        link = server.succeed("proxy-ctl inbounds link vless-in").strip()
        assert link.startswith("vless://${uuid}@${serverAddress}:8443"), link
        assert "#tester" in link, link
        server.succeed("proxy-ctl inbounds | grep -q vless-in")
        server.succeed("proxy-ctl inbounds qr vless-in | head -c 1")
        server.succeed("proxy-ctl status | grep -q proxy-suite-inbounds")

    with subtest("a listener keeps serving after a restart"):
        server.succeed("systemctl restart proxy-suite-inbounds.service")
        server.wait_for_open_port(8443)
  '';
}
