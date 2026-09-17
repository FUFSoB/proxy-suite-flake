# wireproxy with AmneziaWG 3.1: a profile as a SOCKS5 listener, with no interface or
# privileges, for asOutbound = "userspace". Its vendored amneziawg-go gets the suite's
# userspace patch, and wireproxy learns FwMark for hosts that capture traffic.
{ pkgs }:

pkgs.buildGo126Module (finalAttrs: {
  pname = "wireproxy-awg";
  version = "1.0.18";

  src = pkgs.fetchFromGitHub {
    owner = "artem-russkikh";
    repo = "wireproxy-awg";
    rev = "v${finalAttrs.version}";
    hash = "sha256-aiDHUkAP9vuRVmdt/6be0ExaPheE7xWkI8twxVHTzYc=";
  };
  vendorHash = "sha256-jHi8bg8Y+L1Hio/UOrSGQNbF+tJg37tfYDjeqlVLmHM=";

  patches = [ ./patches/wireproxy-awg-fwmark.patch ];

  # The vendored copy, once it exists: the module fetch keeps upstream's.
  overrideModAttrs = _: { preBuild = ""; };
  preBuild = ''
    chmod -R u+w vendor/github.com/amnezia-vpn/amneziawg-go/v3
    patch -p1 -d vendor/github.com/amnezia-vpn/amneziawg-go/v3 \
      < ${./patches/amneziawg-go-random-trailers-transport.patch}
  '';

  subPackages = [ "cmd/wireproxy" ];
  ldflags = [
    "-s"
    "-w"
    "-X main.version=${finalAttrs.version}"
  ];

  meta = {
    description = "WireGuard/AmneziaWG client as a userspace SOCKS5/HTTP proxy";
    homepage = "https://github.com/artem-russkikh/wireproxy-awg";
    license = pkgs.lib.licenses.isc;
    mainProgram = "wireproxy";
  };
})
