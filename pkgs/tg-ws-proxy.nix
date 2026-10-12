{ pkgs }:

let
  fillTemplate = import ../modules/proxy-suite/lib/fill-template.nix;
  src = pkgs.fetchFromGitHub {
    owner = "Flowseal";
    repo = "tg-ws-proxy";
    rev = "v1.11.2";
    hash = "sha256-oX6fdrsqeLwcwGJsI+0bj/y+5JM2ap+d3HuqLmnViho=";
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
