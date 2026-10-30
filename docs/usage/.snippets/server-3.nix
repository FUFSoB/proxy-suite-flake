{ config, lib, pkgs, ... }:
{
  services.proxy-suite.inbounds = {
  users.phone.uuidFile = "/run/secrets/uuid-phone";
  listeners.vless-enc = {
    type = "vless";
    port = 8080;
    users = [ "phone" ];
    flow = "xtls-rprx-vision";
    encryption = {
      enable = true;
      mode = "random";        # the whole handshake looks random
    };
  };
};
}
