{ config, lib, pkgs, ... }:
{
  services.proxy-suite.inbounds = {
  manager = {
    enable = true;
    speedLimits.enable = true;   # nftables, and proxy-suite's XRay patch
  };
  # Declared users take a policy in the config; runtime ones get theirs from proxy-ctl or the API.
  users.phone.policy = {
    expiresAt = "2026-12-31";
    trafficLimit = "100G";
    trafficPeriod = "monthly";
    ipLimit = 2;
    speedLimit = "50M/10M";      # down/up, bits per second
  };
};
}
