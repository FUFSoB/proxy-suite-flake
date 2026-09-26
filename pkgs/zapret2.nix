# zapret2 / nfqws2 - the Lua-strategy successor to zapret's nfqws.
#
# Unlike the zapret v1 packaging, nothing here is patched for NixOS beyond making
# PIDDIR overridable: the init scripts already take ZAPRET_BASE, ZAPRET_RW,
# ZAPRET_CONFIG and HOSTLIST_BASE from the environment, and the unit supplies PATH.
{ pkgs }:

let
  version = "1.0.5.2";
in
pkgs.stdenv.mkDerivation {
  pname = "zapret2";
  inherit version;

  src = pkgs.fetchFromGitHub {
    owner = "bol-van";
    repo = "zapret2";
    tag = "v${version}";
    hash = "sha256-iS7j5Z31rGnuKEDEKfkPJqdIRVS9Psf0+zDtQ7YdoxI=";
  };

  nativeBuildInputs = [ pkgs.pkg-config ];

  buildInputs = [
    pkgs.libcap
    pkgs.libmnl
    pkgs.libnetfilter_queue
    pkgs.libnfnetlink
    pkgs.luajit
    pkgs.systemdLibs
    pkgs.zlib
  ];

  # "systemd" is the plain linux target plus -DUSE_SYSTEMD; ip2net and mdig are
  # only used by the ipset list-download scripts, which this suite does not run.
  buildPhase = ''
    runHook preBuild
    make -C nfq2 systemd
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/opt/zapret2" "$out/bin"
    cp -r common init.d ipset lua files config.default "$out/opt/zapret2/"
    install -Dm755 nfq2/nfqws2 "$out/opt/zapret2/nfq2/nfqws2"
    ln -s "$out/opt/zapret2/nfq2/nfqws2" "$out/bin/nfqws2"

    chmod +x "$out/opt/zapret2/init.d/sysv/zapret2"
    find "$out/opt/zapret2" -name '*.sh' -exec chmod +x {} +

    # Everything else the init scripts need is already env-overridable; PIDDIR is
    # not, and two instances (global + per-app) must not share a pidfile.
    substituteInPlace "$out/opt/zapret2/init.d/sysv/functions" \
      --replace-fail 'PIDDIR=/var/run' 'PIDDIR=''${PIDDIR:-/var/run}'

    runHook postInstall
  '';

  meta = with pkgs.lib; {
    description = "DPI bypass utility with Lua-scripted desync strategies (nfqws2)";
    homepage = "https://github.com/bol-van/zapret2";
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "nfqws2";
  };
}
