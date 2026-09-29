{ config, lib, pkgs, ... }:
{
  services.proxy-suite.proxy = {
  enable = true;
  subscriptions = [ { tag = "provider"; urlFile = "/run/secrets/provider-sub"; } ];
  groups.fast = {
    subscriptions = [ "provider" ]; # every entry the subscription holds
    match = [ "de-*" ];             # and every outbound whose tag matches
    strategy = "urltest";
  };
};
}
