{ pkgs }:

let
  fillTemplate = import ../modules/proxy-suite/lib/fill-template.nix;
  src = pkgs.fetchFromGitHub {
    owner = "Flowseal";
    repo = "tg-ws-proxy";
    rev = "v1.11.4";
    hash = "sha256-N7k8D2tnO4iVFq5lXjhdKpYMR+gDsCkKZLTpACpJStY=";
  };

  pythonEnv = pkgs.python3.withPackages (
    ps: with ps; [
      websockets
      requests
      cryptography
      # proxy/cf_h2.py since v1.11: httpx with its HTTP/2 extra (h2), CA bundle from certifi.
      httpx
      h2
      certifi
    ]
  );
in
pkgs.writeShellApplication {
  name = "tg-ws-proxy";
  runtimeInputs = [ pythonEnv ];
  text = fillTemplate ./tg-ws-proxy.template.sh { inherit src; };
}
