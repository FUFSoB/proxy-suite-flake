{ pkgs }:

let
  src = pkgs.fetchFromGitHub {
    owner = "Flowseal";
    repo = "tg-ws-proxy";
    rev = "fe4e0e82344d8e8ca5e54b7752cafa934fb763ab";
    hash = "sha256-tXDfYE1qFYTAWTu7pse/jcovDmX/F42SCGOzsUBmljs=";
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
  text = ''
    set -euo pipefail

    secret=""
    script_path="${src}/proxy/tg_ws_proxy.py"
    args=()

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --secret-file=*)
          secret=$(tr -d '\r\n' < "''${1#--secret-file=}")
          shift
          ;;
        --secret-file)
          secret=$(tr -d '\r\n' < "$2")
          shift 2
          ;;
        --secret=*)
          secret="''${1#--secret=}"
          shift
          ;;
        --secret)
          secret="$2"
          shift 2
          ;;
        *)
          args+=("$1")
          shift
          ;;
      esac
    done

    export PYTHONPATH="${src}"
    if [ -n "$secret" ]; then
      export TG_WS_PROXY_SECRET="$secret"
    fi

    exec python - "$script_path" "''${args[@]}" <<'PY'
import os
import runpy
import sys

script_path = sys.argv[1]
args = sys.argv[2:]
secret = os.environ.get("TG_WS_PROXY_SECRET")

if secret is not None:
    args.extend(["--secret", secret])

sys.argv = ["tg_ws_proxy.py", *args]
runpy.run_path(script_path, run_name="__main__")
PY
  '';
}
