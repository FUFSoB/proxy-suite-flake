# The runtime helper scripts (../../../scripts), as one filtered store path shared by every
# module that shells out to them. Unfiltered, the unit tests and any stale __pycache__ land
# in every host's closure and move its store hash.
{ lib }:
builtins.path {
  name = "proxy-suite-scripts";
  path = ../../../scripts;
  filter =
    path: _type:
    let
      base = baseNameOf path;
    in
    !(lib.hasPrefix "test-" base) && base != "__pycache__";
}
