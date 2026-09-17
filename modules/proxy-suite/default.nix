# Factory: receives the zapret flake and this flake's own nixpkgs, and returns the
# proxy-suite module for each supported host. Consumers add a single flake input and
# get everything transitively.
inputs:

let
  core = import ./core.nix inputs;
  forHost = adapter: {
    imports = [
      core
      adapter
    ];
  };
in
{
  nixos = forHost ./hosts/nixos.nix;
  homeManager = forHost ./hosts/home-manager.nix;
  systemManager = forHost ./hosts/system-manager.nix;
  nixOnDroid = forHost ./hosts/nix-on-droid.nix;
}
