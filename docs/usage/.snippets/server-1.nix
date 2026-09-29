{ config, lib, pkgs, ... }:
{
  services.proxy-suite = {
  enable = true;
  inbounds = {
    enable = true;
    serverAddress = "vpn.example.com"; # null: this host's public IPv4
    routing.via = "direct";            # clients exit straight from this host
    # Each user once; listeners name the ones they accept, and take the secret they need.
    users = {
      phone.uuidFile = "/run/secrets/uuid-phone";
      laptop.uuidFile = "/run/secrets/uuid-laptop";
    };
    listeners = {
      vless-reality = {
        type = "vless";
        port = 443;
        flow = "xtls-rprx-vision";
        users = [ "phone" "laptop" ];
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
        users = [ "phone" ];
      };
    };
  };
};
}
