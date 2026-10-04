{ pkgs }:

let
  fillTemplate = import ../modules/proxy-suite/lib/fill-template.nix;
  src = pkgs.fetchFromGitHub {
    owner = "Flowseal";
    repo = "tg-ws-proxy";
    rev = "v1.10.4";
    hash = "sha256-emR1+31feNDNGzRJ7DSjf724bcK4+LpXqnCdRiAXWjM=";
  };

  pythonEnv = pkgs.python3.withPackages (
    ps: with ps; [
      websockets
      requests
      cryptography
    ]
  );
in
pkgs.writeShellApplication {
  name = "tg-ws-proxy";
  runtimeInputs = [ pythonEnv ];
  text = fillTemplate ./tg-ws-proxy.template.sh { inherit src; };
}
