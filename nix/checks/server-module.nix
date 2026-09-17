# nixosModules.server as the installer writes it: once for an IP certificate, once for
# a domain.
{
  pkgs,
  system,
  nixpkgs,
  proxySuiteModule,
  mkInboundsSpec,
}:

let
  inherit (pkgs) lib;

  serverModule = import ../../deploy/server-module.nix { inherit proxySuiteModule; };

  mkServer =
    extra:
    import "${nixpkgs}/nixos/lib/eval-config.nix" {
      inherit system;
      modules = [
        serverModule
        {
          system.stateVersion = "26.05";
          fileSystems."/" = {
            device = "/dev/disk/by-label/nixos";
            fsType = "ext4";
          };
          services.proxy-suite-server = lib.recursiveUpdate {
            enable = true;
            bootDisk = "/dev/vda";
            network = {
              mac = "52:54:00:12:34:56";
              ipv4 = {
                address = "203.0.113.10/32";
                gateway = "198.51.100.1";
              };
            };
            publicAddress = "203.0.113.10";
            reality = {
              publicKey = "public-key";
              shortId = "0123456789abcdef";
            };
            wsPath = "/3f9a1c07b2e4";
          } extra;
        }
      ];
    };

  ipServer = mkServer { };
  onionServer = mkServer { onion.enable = true; };
  domainServer = mkServer {
    domain = "vpn.example.com";
    network.dhcp = true;
  };

  failedAssertions =
    fixture: map (a: a.message) (builtins.filter (a: !a.assertion) fixture.config.assertions);
  listener = spec: tag: lib.head (builtins.filter (l: l.tag == tag) spec.listeners);

  ipSpec = mkInboundsSpec ipServer;
  onionSpec = mkInboundsSpec onionServer;
  domainSpec = mkInboundsSpec domainServer;
  uplink = fixture: fixture.config.systemd.network.networks."10-uplink";
  ipCert = ipServer.config.security.acme.certs."203.0.113.10";
  domainCert = domainServer.config.security.acme.certs."vpn.example.com";
in
{
  assertions = [
    (
      assert failedAssertions ipServer == [ ];
      true
    )
    (
      assert failedAssertions domainServer == [ ];
      true
    )

    (
      assert
        lib.sort (a: b: a < b) (map (l: l.port) ipSpec.listeners) == [
          443
          2053
          8443
        ];
      true
    )
    (
      assert
        (listener ipSpec "vless-reality").reality.privateKeyFile
        == "/var/lib/proxy-suite-server/reality-key";
      true
    )
    (
      assert
        (listener ipSpec "vless-tls").tls.certificateFile == "/var/lib/acme/203.0.113.10/fullchain.pem";
      true
    )
    (
      assert (listener domainSpec "vless-ws").tls.keyFile == "/var/lib/acme/vpn.example.com/key.pem";
      true
    )
    (
      assert (listener ipSpec "vless-ws").transport.path == "/3f9a1c07b2e4";
      true
    )
    (
      assert
        (lib.head (listener ipSpec "vless-tls").users).uuidFile == "/var/lib/proxy-suite-server/uuid";
      true
    )

    # IP certificates exist only in the short-lived profile.
    (
      assert ipCert.profile == "shortlived" && domainCert.profile == null;
      true
    )
    (
      assert ipCert.group == "proxy-suite-daemon";
      true
    )
    (
      assert ipServer.config.services.proxy-suite.inbounds.serverAddress == "203.0.113.10";
      true
    )
    (
      assert domainServer.config.services.proxy-suite.inbounds.serverAddress == "vpn.example.com";
      true
    )

    # A /32 with a gateway outside it only works on-link.
    (
      assert (uplink ipServer).address == [ "203.0.113.10/32" ];
      true
    )
    (
      assert
        (uplink ipServer).routes == [
          {
            Gateway = "198.51.100.1";
            GatewayOnLink = true;
          }
        ];
      true
    )
    (
      assert (uplink domainServer).networkConfig.DHCP == "yes" && (uplink domainServer).address == [ ];
      true
    )

    (
      assert lib.all (p: builtins.elem p ipServer.config.networking.firewall.allowedTCPPorts) [
        80
        443
        8443
        2053
        22
      ];
      true
    )
    (
      assert ipServer.config.services.openssh.settings.PermitRootLogin == "no";
      true
    )

    # onion.enable: every listener behind the onion service, and nothing opened for it.
    (
      assert failedAssertions onionServer == [ ];
      true
    )
    (
      assert
        lib.sort (a: b: a < b) onionSpec.onionListeners == [
          "vless-reality"
          "vless-tls"
          "vless-ws"
        ];
      true
    )
    (
      assert !(ipServer.config.systemd.services ? proxy-suite-tor) && (ipSpec.onionListeners or [ ]) == [ ];
      true
    )
    (
      assert builtins.elem "proxy-suite-tor.service" onionServer.config.systemd.services.proxy-suite-inbounds.after;
      true
    )
    (
      assert
        onionServer.config.networking.firewall.allowedTCPPorts
        == ipServer.config.networking.firewall.allowedTCPPorts;
      true
    )
    (
      assert
        lib.hasInfix "--onion" onionServer.config.services.getty.helpLine
        && !(lib.hasInfix "--onion" ipServer.config.services.getty.helpLine);
      true
    )
  ];
}
