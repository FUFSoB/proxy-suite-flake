# whitelist-bypass's headless ends: a tunnel through the media servers of video calls
# (WB Stream, Telemost, DION, Bitrix, VK), which stay reachable under mobile whitelists.
# Creators sit on the free side, joiners expose a SOCKS5 listener on the censored one.
{ pkgs }:

pkgs.buildGo126Module (finalAttrs: {
  pname = "whitelist-bypass";
  version = "0.4.4";

  src = pkgs.fetchFromGitHub {
    owner = "kulikov0";
    repo = "whitelist-bypass";
    rev = "v${finalAttrs.version}";
    hash = "sha256-dYSadPA3X/f61XjpU+DTiLTPkKb3RC18/Z3x/YAOcC0=";
  };
  vendorHash = "sha256-zKQzcfYdjKfpsyVgTTRdT0AFGqZQMtStpdVyCrojltE=";

  subPackages = [
    "headless/vk"
    "headless/telemost"
    "headless/wbstream"
    "headless/dion"
    "headless/bitrix"
    "headless/telemost-joiner"
    "headless/wbstream-joiner"
    "headless/dion-joiner"
    "headless/bitrix-joiner"
  ];
  ldflags = [
    "-s"
    "-w"
  ];

  # Upstream's names (build-headless.sh): each directory builds one binary.
  postInstall = ''
    for p in vk telemost wbstream dion bitrix; do
      mv "$out/bin/$p" "$out/bin/headless-$p-creator"
    done
    for p in telemost wbstream dion bitrix; do
      mv "$out/bin/$p-joiner" "$out/bin/headless-$p-joiner"
    done
  '';

  meta = {
    description = "Tunnel through video call media servers to get past mobile internet whitelists";
    homepage = "https://github.com/kulikov0/whitelist-bypass";
    license = pkgs.lib.licenses.mit;
  };
})
