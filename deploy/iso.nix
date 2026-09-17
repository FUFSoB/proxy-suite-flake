# Installer ISO for a proxy-suite VPS (packages.<system>.installer-iso). Boots to the
# console installer on tty1; everything per server is asked there, nothing is baked in.
{ self, serverModule }:

{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

let
  inherit (pkgs.stdenv.hostPlatform) system;

  # The configuration the installer writes, with placeholders for what it asks. Its
  # closure goes on the ISO, so installing downloads little and builds nothing big.
  template = import "${modulesPath}/../lib/eval-config.nix" {
    inherit system;
    modules = [
      serverModule
      {
        networking.hostName = "proxy-template";
        system.stateVersion = config.system.nixos.release;
        fileSystems."/" = {
          device = "/dev/disk/by-label/nixos";
          fsType = "ext4";
        };
        fileSystems."/boot" = {
          device = "/dev/disk/by-label/ESP";
          fsType = "vfat";
          options = [ "umask=077" ];
        };
        services.proxy-suite-server = {
          enable = true;
          bootDisk = "/dev/vda";
          network = {
            mac = "52:54:00:00:00:01";
            ipv4 = {
              address = "192.0.2.1/24";
              gateway = "192.0.2.254";
            };
          };
          publicAddress = "192.0.2.1";
          reality = {
            publicKey = "template";
            shortId = "0123456789abcdef";
          };
          wsPath = "/template";
        };
      }
    ];
  };

  # The sources of this flake and of its inputs, so locking /etc/nixos finds them here.
  inputSources =
    flake: [ flake.outPath ] ++ lib.concatMap inputSources (lib.attrValues (flake.inputs or { }));

  installer = pkgs.callPackage ./installer.nix {
    xray = import ../pkgs/xray.nix { inherit pkgs; };
    # A github ref only for a clean, committed tree; the installer falls back to the
    # copy in PSI_FLAKE_SRC when it cannot be fetched (e.g. not pushed yet).
    flakeUrl = lib.optionalString (self ? rev) "github:FUFSoB/proxy-suite-flake/${self.rev}";
    flakeSource = self.outPath;
    stateVersion = config.system.nixos.release;
  };
in
{
  imports = [ "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix" ];

  isoImage = {
    edition = "proxy-suite";
    storeContents = [ template.config.system.build.toplevel ] ++ lib.unique (inputSources self);
  };

  # The same stack the installed system uses, so settings tested here carry over.
  networking = {
    hostName = "proxy-suite-installer";
    networkmanager.enable = lib.mkForce false;
    wireless.enable = lib.mkForce false;
    useNetworkd = true;
    useDHCP = true;
  };
  systemd.network.wait-online.enable = false;
  services.openssh.enable = lib.mkForce false;

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # VNC consoles are small and blurry.
  console = {
    earlySetup = true;
    font = "${pkgs.terminus_font}/share/consolefonts/ter-v24n.psf.gz";
    packages = [ pkgs.terminus_font ];
  };

  environment.systemPackages = [
    installer
    (pkgs.callPackage ./net-rescue.nix { })
  ];

  services.getty.helpLine = lib.mkForce ''

    Proxy-suite installer. It starts on tty1; to run it again: sudo proxy-suite-install
  '';

  # Once, on tty1 only: other consoles (Alt+F2) stay plain shells. The console logs in
  # as nixos, which has passwordless sudo.
  programs.bash.interactiveShellInit = ''
    if [[ $(tty) == /dev/tty1 && ! -e /tmp/.proxy-suite-install-started ]]; then
      touch /tmp/.proxy-suite-install-started
      sudo proxy-suite-install
    fi
  '';
}
