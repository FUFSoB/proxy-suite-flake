{ config, lib, pkgs, ... }:
{
  services.proxy-suite.mitm.pythonPackages = ps: [ ps.msgpack ps.pycryptodome ];
}
