{ config, lib, pkgs, ... }:
{
  services.proxy-suite = {
  enable = true;
  inbounds = {
    enable = true;
    serverAddress = "vpn.example.com"; # null: this host's public IPv4
    routing.via = "direct";            # clients exit straight from this host
    listeners = {
      vless-reality = {
        type = "vless";
        port = 443;
        flow = "xtls-rprx-vision";
        users = [
          { name = "phone"; uuidFile = "/run/secrets/uuid-phone"; }
          { name = "laptop"; uuidFile = "/run/secrets/uuid-laptop"; }
        ];
        reality = {
          enable = true;
          serverNames = [ "www.microsoft.com" ];
          privateKeyFile = "/run/secrets/reality-private-key";
          publicKey = "jNXH…"; # both keys from `xray x25519`
          shortIds = [ "0123abcd" ];
        };
      };
      # Keys for the server and each user are generated on first start.
      awg = {
        type = "amneziawg";
        port = 51820;
        users = [ { name = "phone"; } ];
      };
    };
  };
};
}
