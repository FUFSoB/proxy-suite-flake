{
  pkgs,
  rg,
  generatedOptionsDoc,
  generatedReadmeDoc,
  readmeDocSource,
  trayModuleSource,
  tgWsProxyModuleSource,
  controlModuleSource,
}:

{
  no-secrets = pkgs.runCommand "proxy-suite-no-secrets-check" { } ''
    repo_root=${../../.}
    if ${rg} --pcre2 -n -I -H -S \
      -e '-----BEGIN (RSA|DSA|EC|OPENSSH|PGP) PRIVATE KEY-----' \
      -e 'ghp_[A-Za-z0-9]{36}' \
      -e 'github_pat_[A-Za-z0-9_]{20,}' \
      -e 'glpat-[A-Za-z0-9_-]{20,}' \
      -e 'xox[baprs]-[A-Za-z0-9-]{10,}' \
      -e 'AKIA[0-9A-Z]{16}' \
      -e 'AIza[0-9A-Za-z_-]{35}' \
      -e 'sk-(proj-)?[A-Za-z0-9_-]{20,}' \
      "$repo_root"; then
      echo "secret-like content detected in source tree" >&2
      exit 1
    fi
    touch "$out"
  '';

  options-doc = pkgs.runCommand "proxy-suite-options-doc-check" { nativeBuildInputs = [ pkgs.diffutils ]; } ''
    diff -u ${../../docs/options.md} ${generatedOptionsDoc}
    touch "$out"
  '';

  readme-doc = pkgs.runCommand "proxy-suite-readme-doc-check" { nativeBuildInputs = [ pkgs.diffutils ]; } ''
    diff -u ${../../README.md} ${generatedReadmeDoc}
    touch "$out"
  '';

  readme-doc-source = builtins.seq
    (
      assert !(pkgs.lib.hasInfix "environment.systemPackages" readmeDocSource);
      assert !(pkgs.lib.hasInfix "packageByPattern" readmeDocSource);
      true
    )
    (pkgs.writeText "proxy-suite-readme-doc-source-check" "ok");

  package-source = builtins.seq
    (
      assert !(pkgs.lib.hasInfix "../../pkgs/proxy-suite-tray.nix" trayModuleSource);
      assert !(pkgs.lib.hasInfix "../../pkgs/tg-ws-proxy.nix" tgWsProxyModuleSource);
      assert !(pkgs.lib.hasInfix "../../../pkgs/proxy-ctl.nix" controlModuleSource);
      true
    )
    (pkgs.writeText "proxy-suite-package-source-check" "ok");
}
