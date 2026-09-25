{ config, lib, pkgs, ... }:
{
  services.proxy-suite = {
  enable = true;
  proxy = {
    enable = true;
    outbounds = [ { tag = "my-vps"; urlFile = "/run/secrets/my-vps-url"; } ];
    routing.rules = [
      { domains = [ "chatgpt.com" "openai.com" ]; outbound = "warp"; }
      { domains = [ "check.torproject.org" ]; outbound = "tor"; }
    ];
  };

  # Tagged "warp". Registers a free WARP device on first start.
  warp = {
    enable = true;
    asOutbound = "singBox";
  };

  # Tagged "tor". .onion names always go to it.
  tor = {
    enable = true;
    asOutbound = true;
  };

  # Tagged "ssh-proxy".
  sshProxy = {
    enable = true;
    asOutbound = true;
    server = { user = "me"; host = "ssh.example.com"; };
    identityFile = "/run/secrets/ssh-key";
    hostKeyFile = "/run/secrets/ssh-known-hosts"; # from ssh-keyscan
  };
};
}
