{ config, lib, pkgs, ... }:
{
  services.proxy-suite.inbounds.runtime = {
  enable = true;
  ports = [ "20000-20099" ];   # runtime listeners bind only here; opened in the firewall
  vias = [ "direct" ];         # exits besides routing.via and "block"
  tlsCertificates.main = {     # named, so a runtime listener never points at a file
    certificateFile = "/var/lib/acme/vpn.example.com/fullchain.pem";
    keyFile = "/var/lib/acme/vpn.example.com/key.pem";
  };
};
}
