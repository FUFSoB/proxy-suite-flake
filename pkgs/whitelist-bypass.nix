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
  # The call link (WB_LINK), the local proxy's password (WB_UPSTREAM_PASS) and a joiner's
  # SOCKS password (WB_SOCKS_PASS) from the environment, not argv: these run for good, and
  # every local user reads a command line.
  postPatch = ''
    envDefault() {
      substituteInPlace "headless/$1/main.go" --replace-fail \
        "flag.String(\"$2\", \"\"," "flag.String(\"$2\", os.Getenv(\"$3\"),"
    }
    for p in vk telemost wbstream dion bitrix; do
      envDefault $p upstream-pass WB_UPSTREAM_PASS
    done
    for p in bitrix dion dion-joiner wbstream wbstream-joiner; do
      envDefault $p room WB_LINK
    done
    # The joiners' SOCKS password (the hop login proxy-suite gives them) likewise.
    for p in telemost-joiner wbstream-joiner dion-joiner bitrix-joiner; do
      envDefault $p socks-pass WB_SOCKS_PASS
    done
    envDefault bitrix-joiner link WB_LINK
    envDefault telemost tm-link WB_LINK
    envDefault telemost-joiner tm-link WB_LINK
    envDefault vk vk-link WB_LINK
  '';
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
