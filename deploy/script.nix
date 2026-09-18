# The console helpers are net-lib.sh plus one front end, wrapped with the tools they call.
{ lib, writeShellApplication }:

{
  name,
  script,
  runtimeInputs,
  runtimeEnv ? { },
}:
writeShellApplication {
  inherit name runtimeInputs runtimeEnv;
  text = lib.concatStringsSep "\n" [
    (builtins.readFile ./net-lib.sh)
    (builtins.readFile script)
  ];
}
