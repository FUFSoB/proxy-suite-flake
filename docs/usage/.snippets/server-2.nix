{ config, lib, pkgs, ... }:
{
  services.proxy-suite.inbounds = {
  users.phone = {
    uuidFile = "/run/secrets/uuid-phone";       # tuic takes both
    passwordFile = "/run/secrets/password-phone";
  };
  listeners = {
    anytls = {
      type = "anytls";                           # TLS with padding against TLS-in-TLS detection
      port = 8443;
      users = [ "phone" ];
      tls.certificateFile = "/var/lib/acme/vpn.example.com/fullchain.pem";
      tls.keyFile = "/var/lib/acme/vpn.example.com/key.pem";
    };
    tuic = {
      type = "tuic";                             # QUIC, on UDP
      port = 8444;
      users = [ "phone" ];
      tls.certificateFile = "/var/lib/acme/vpn.example.com/fullchain.pem";
      tls.keyFile = "/var/lib/acme/vpn.example.com/key.pem";
    };
    shadowtls = {
      type = "shadowtls";                        # no certificate: it borrows a real site's handshake
      port = 8445;
      users = [ "phone" ];
      shadowTls.handshake = "www.microsoft.com:443";
    };
  };
};
}
