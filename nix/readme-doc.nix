{
  nixpkgs,
  pkgsFor,
  proxySuiteModule,
  zapret,
}:

system:

let
  pkgs = pkgsFor system;
  packages = import ../pkgs/default.nix { inherit pkgs; };
  fixture = import ./readme-doc-fixture.nix;
  eval = import "${nixpkgs}/nixos/lib/eval-config.nix" {
    inherit system;
    modules = [
      proxySuiteModule
      fixture
    ];
  };
  cfg = eval.config.services.proxy-suite;
  rules = import ../modules/proxy-suite/rules.nix {
    lib = pkgs.lib;
    inherit pkgs cfg zapret;
  };
  configs = import ../modules/proxy-suite/config.nix {
    lib = pkgs.lib;
    inherit pkgs cfg rules;
  };
  nftr = import ../modules/proxy-suite/nftables.nix {
    lib = pkgs.lib;
    inherit pkgs cfg;
  };
  context = import ../modules/proxy-suite/service/context.nix {
    lib = pkgs.lib;
    inherit
      pkgs
      packages
      cfg
      ;
    inherit (configs) tproxyFile tunFile perAppTunFile;
    inherit (nftr) perAppTunChainFile perAppTproxyRulesFile perAppZapretRulesFile ip nft;
  };
in
pkgs.runCommand "proxy-suite-README.md" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  src=${../README.md}
  help_file="$TMPDIR/proxy-ctl-help.txt"
  export src help_file

  ${context.control.proxyCtl}/bin/proxy-ctl help > "$help_file"

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
