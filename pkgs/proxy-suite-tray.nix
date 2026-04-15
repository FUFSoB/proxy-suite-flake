{
  pkgs,
  pollInterval ? 5,
}:

pkgs.stdenv.mkDerivation {
  pname = "proxy-suite-tray";
  version = "0.1.0";

  src = ./proxy-suite-tray;

  nativeBuildInputs = [ pkgs.pkg-config ];
  buildInputs = [
    pkgs.gtk3
    pkgs.libayatana-appindicator
  ];

  buildPhase = ''
    $CC -o proxy-suite-tray main.c \
      $(pkg-config --cflags --libs gtk+-3.0 ayatana-appindicator3-0.1) \
      -DSYSTEMCTL_BIN='"${pkgs.systemd}/bin/systemctl"' \
      -DPKEXEC_BIN='"/run/wrappers/bin/pkexec"' \
      -DPOLL_INTERVAL=${toString pollInterval} \
      -O2 -Wall
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp proxy-suite-tray $out/bin/

    # Install custom icons in hicolor theme
    if [ -d icons ]; then
      mkdir -p $out/share/icons/hicolor/scalable/apps
      mkdir -p $out/share/icons/hicolor/symbolic/apps
      cp icons/proxy-suite-disabled.svg \
         icons/proxy-suite-zapret.svg \
         icons/proxy-suite-proxy.svg \
         icons/proxy-suite-active.svg \
         icons/proxy-suite-tunnel.svg \
         $out/share/icons/hicolor/scalable/apps/
      cp icons/proxy-suite-disabled-symbolic.svg \
         icons/proxy-suite-zapret-symbolic.svg \
         icons/proxy-suite-proxy-symbolic.svg \
         icons/proxy-suite-active-symbolic.svg \
         icons/proxy-suite-tunnel-symbolic.svg \
         $out/share/icons/hicolor/symbolic/apps/
    fi
  '';

  meta = {
    description = "System tray indicator for proxy-suite";
    mainProgram = "proxy-suite-tray";
  };
}
