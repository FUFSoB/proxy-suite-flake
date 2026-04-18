{
  nixpkgs,
  pkgsFor,
  proxySuiteModule,
}:

system:

let
  pkgs = pkgsFor system;
  lib = pkgs.lib;
  eval = import "${nixpkgs}/nixos/lib/eval-config.nix" {
    inherit system;
    modules = [
      proxySuiteModule
      {
        system.stateVersion = lib.trivial.release;
        services.proxy-suite = {
          enable = true;
          singBox.outbounds = [
            {
              tag = "primary";
              url = "http://proxy.example.com:8080";
            }
          ];
        };
      }
    ];
  };
  packageByPattern =
    packages: pattern:
    builtins.head (
      builtins.filter (
        pkg: builtins.match pattern (builtins.unsafeDiscardStringContext (toString pkg)) != null
      ) packages
    );
  proxyCtl =
    packageByPattern eval.config.environment.systemPackages ".*/[^/]*proxy-ctl(-[0-9.]+)?$";
in
pkgs.runCommand "proxy-suite-README.md" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  src=${../README.md}
  help_file="$TMPDIR/proxy-ctl-help.txt"
  export src help_file

  ${proxyCtl}/bin/proxy-ctl help > "$help_file"

  python <<'PY'
  from pathlib import Path
  import os

  src = Path(os.environ["src"])
  help_file = Path(os.environ["help_file"])
  out = Path(os.environ["out"])

  start_marker = "<!-- proxy-ctl-help:start -->"
  end_marker = "<!-- proxy-ctl-help:end -->"

  readme = src.read_text()
  help_text = help_file.read_text().rstrip("\n")
  replacement = f"{start_marker}\n```text\n{help_text}\n```\n{end_marker}"

  try:
      start = readme.index(start_marker)
      end = readme.index(end_marker) + len(end_marker)
  except ValueError as exc:
      raise SystemExit(f"README markers missing: {exc}")

  out.write_text(readme[:start] + replacement + readme[end:])
  PY
''
