# config.lib.proxy-suite: the wrappers are built for real and run, and each
# unavailable helper refuses with its reason instead of building something broken.
{ pkgs, evalProxySuite }:

let
  inherit (pkgs) lib;
  helpersFor =
    settings:
    (evalProxySuite [
      {
        system.stateVersion = "26.05";
        services.proxy-suite = {
          enable = true;
          proxy = {
            enable = true;
            outbounds = [
              {
                tag = "a";
                url = "socks://127.0.0.1:9";
              }
            ];
          };
        }
        // settings;
      }
    ]).config.lib.proxy-suite;
  helpers = helpersFor {
    perAppRouting = {
      enable = true;
      createDefaultProfiles = true;
      proxychains.enable = true;
      tun.enable = true;
    };
  };
  bare = helpersFor { };
  refuses = value: !(builtins.tryEval (builtins.deepSeq value value)).success;

  # Prints its environment; its .desktop file starts it by store path. Labelled unfree
  # (built as free, since nixpkgs here refuses unfree), which the wrappers must not inherit.
  fake =
    (pkgs.runCommand "fake-app" { } ''
      mkdir -p $out/bin $out/share/applications
      printf '#!${pkgs.runtimeShell}\nexec ${pkgs.coreutils}/bin/env\n' > $out/bin/fake
      printf '#!${pkgs.runtimeShell}\necho other\n' > $out/bin/other
      chmod +x $out/bin/fake $out/bin/other
      printf '[Desktop Entry]\nExec=%s/bin/fake %%U\n' "$out" > $out/share/applications/fake.desktop
    '')
    // {
      meta.license = lib.licenses.unfree;
    };
  viaHttp = helpers.wrapEnv { } fake;
  viaSocks = helpers.wrapEnv {
    protocol = "socks";
    programs = [ "fake" ];
  } fake;
  viaChains = helpers.wrapProxychains { programs = [ "fake" ]; } fake;
  viaTun = helpers.wrapPerApp { profile = "tun"; } fake;
in
assert helpers.urls.http == "http://127.0.0.1:1080";
assert helpers.env.ALL_PROXY == "socks5h://127.0.0.1:1080";
assert refuses (bare.wrapProxychains { } fake);
assert refuses (bare.wrapPerApp { profile = "tun"; } fake);
assert refuses (helpers.wrapPerApp { profile = "nope"; } fake);
assert refuses (
  (helpersFor {
    proxy.listener.auth = {
      username = "u";
      passwordFile = "/run/secrets/p";
    };
  }).env
);
pkgs.runCommand "proxy-suite-proxy-helpers-check" { } ''
  set -eu
  export ALL_PROXY=socks5h://elsewhere:1 HTTPS_PROXY=http://elsewhere:1

  # http: its variables set, the shell's socks one dropped; every program wrapped.
  ${viaHttp}/bin/fake > http.env
  grep -qx 'HTTPS_PROXY=http://127.0.0.1:1080' http.env
  grep -qx 'no_proxy=localhost,127.0.0.0/8,::1' http.env
  ! grep -q '^ALL_PROXY=' http.env || exit 1
  grep -q 'HTTPS_PROXY' ${viaHttp}/bin/other
  # The .desktop file starts the wrapper, not the original.
  grep -qx "Exec=${viaHttp}/bin/fake %U" ${viaHttp}/share/applications/fake.desktop

  # socks: the reverse, and only the named program.
  ${viaSocks}/bin/fake > socks.env
  grep -qx 'ALL_PROXY=socks5h://127.0.0.1:1080' socks.env
  ! grep -q '^HTTPS_PROXY=' socks.env || exit 1
  [ "$(readlink -f ${viaSocks}/bin/other)" = ${fake}/bin/other ]

  # proxychains preloads itself into the program.
  ${viaChains}/bin/fake | grep -q '^LD_PRELOAD=.*libproxychains4'

  # Per-app routing goes through proxy-ctl.
  grep -q 'proxy-ctl.* apps run tun -- ${fake}/bin/fake' ${viaTun}/bin/fake

  touch "$out"
''
