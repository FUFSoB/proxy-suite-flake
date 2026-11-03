{ config, lib, pkgs, ... }:
{
  services.proxy-suite.proxy.subscriptions = [
  {
    tag = "provider";
    urlFile = "/run/secrets/provider-sub-url";
    # Tried in order until one gets entries: a panel may serve some clients a stub.
    userAgent = [ "v2rayN/6.0" "Happ/1.0" ];
    # The HWID and system, as Happ sends them.
    sendDeviceInfo = true;
  }
];
}
