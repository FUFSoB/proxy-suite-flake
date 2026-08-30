{ pkgs }:

{
  build-outbound-parser =
    pkgs.runCommand "build-outbound-parser-check" { nativeBuildInputs = [ pkgs.python3 ]; }
      ''
        export PYTHONDONTWRITEBYTECODE=1
        export PYTHONPATH=${../../scripts}:$PYTHONPATH
        python ${../../scripts/test-build-outbound.py}
        touch "$out"
      '';

  fetch-subscription-parser =
    pkgs.runCommand "fetch-subscription-parser-check" { nativeBuildInputs = [ pkgs.python3 ]; }
      ''
        export PYTHONDONTWRITEBYTECODE=1
        export PYTHONPATH=${../../scripts}:$PYTHONPATH
        python ${../../scripts/test-fetch-subscription.py}
        touch "$out"
      '';

  amneziawg-config-parser =
    pkgs.runCommand "amneziawg-config-parser-check" { nativeBuildInputs = [ pkgs.python3 ]; }
      ''
        export PYTHONDONTWRITEBYTECODE=1
        export PYTHONPATH=${../../scripts}:$PYTHONPATH
        python ${../../scripts/test-amneziawg-config.py}
        touch "$out"
      '';
}
