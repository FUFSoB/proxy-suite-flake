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
  # Evaluated like the installed flake evaluates it, so the two share their store paths.
  template = self.inputs.nixpkgs.lib.nixosSystem {
    modules = [
      serverModule
      {
        nixpkgs.hostPlatform = system;
        networking.hostName = "proxy-template";
        system.stateVersion = config.system.nixos.release;
        # Asked by the installer, on by default.
        services.qemuGuest.enable = true;
        services.proxy-suite-server = {
          enable = true;
          bootDisk = "/dev/vda";
          disko.enable = true;
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

  # This flake's source without what a path: build picks up besides the tracked files.
  flakeSource = lib.cleanSourceWith {
    name = "source";
    src = self;
    filter =
      path: type:
      lib.cleanSourceFilter path type
      && !(lib.elem (baseNameOf path) [
        "__pycache__"
        ".ruff_cache"
        ".direnv"
      ]);
  };

  # The sources of the flakes this one is locked to, so locking /etc/nixos finds them
  # here. Non-flake inputs (z2k alone is 270M) are fetched when evaluation needs them,
  # which the server never does.
  inputSources =
    flake:
    lib.concatMap (input: [ input.outPath ] ++ inputSources input) (
      lib.filter (input: input._type or null == "flake") (lib.attrValues (flake.inputs or { }))
    );

  # Tells ISOs apart: the commit, and a hash of the tree when it differs from it (dirty,
  # or built from path:). The file name adds the build time.
  treeId = builtins.substring 0 8 (builtins.hashString "sha256" self.narHash);
  sourceId =
    if self ? rev then
      self.shortRev
    else if self ? dirtyShortRev then
      "${self.dirtyShortRev}-${treeId}"
    else
      treeId;

  installer = pkgs.callPackage ./installer.nix {
    xray = import ../pkgs/xray.nix { inherit pkgs; };
    # Evaluates the layout against the nixpkgs source on the ISO, not a copy of it.
    disko = self.inputs.disko.packages.${system}.disko.override {
      path = self.inputs.nixpkgs.outPath;
    };
    diskLayout = ./disk-layout.nix;
    # The installer pins this commit on GitHub when it holds what flakeSource does, and
    # installs flakeSource itself otherwise (not pushed, dirty, or built from path:).
    flakeRev = self.rev or "";
    inherit flakeSource;
    stateVersion = config.system.nixos.release;
  };
in
{
  imports = [ "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix" ];

  # The generic installer's extras, none of which a VPS console needs: rescue and disk
  # tools with zfs and bcachefs (base.nix), a copy of nixpkgs as a channel, and the
  # ISO's own configuration in /etc/nixos.
  disabledModules = [
    "profiles/base.nix"
    "installer/cd-dvd/channel.nix"
    "profiles/clone-config.nix"
  ];

  isoImage = {
    edition = "proxy-suite";
    # The template's disko script brings the partitioning tools (btrfs-progs, sgdisk...).
    storeContents = [
      template.config.system.build.toplevel
      template.config.system.build.diskoScript
      flakeSource
    ]
    ++ lib.unique (inputSources self);
    # Smaller than the default zstd, at the cost of a slower boot and build.
    squashfsCompression =
      "xz -Xdict-size 100%" + lib.optionalString pkgs.stdenv.hostPlatform.isx86 " -Xbcj x86";
  };
  image.baseName = lib.mkForce "proxy-suite-installer-${sourceId}-${system}";

  # The ISO under a name with its build time. The store path keeps the plain name, so an
  # unchanged ISO is not rebuilt and keeps its first build time.
  system.build.installerIso = config.system.build.isoImage.overrideAttrs (old: {
    buildCommandPath = pkgs.writeText "make-iso9660-image-stamped.sh" ''
      isoName="proxy-suite-installer-$(date -u +%Y%m%d-%H%M)-${sourceId}-${system}.iso"
      source ${old.buildCommandPath}
    '';
  });

  # Smaller: no firmware (a VM needs none, 800M+), docs, RAID or memtest.
  hardware.enableRedistributableFirmware = lib.mkForce false;
  documentation = {
    enable = lib.mkForce false;
    man.enable = lib.mkForce false;
    doc.enable = lib.mkForce false;
    info.enable = lib.mkForce false;
    nixos.enable = lib.mkForce false;
  };
  environment.defaultPackages = lib.mkForce [ ];
  boot.swraid.enable = lib.mkForce false;
  boot.loader.grub.memtest86.enable = lib.mkForce false;
  # What the installer mounts: disko's ESP and btrfs.
  boot.supportedFilesystems = [
    "btrfs"
    "vfat"
  ];

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
  # Lets the VPS panel see the installer's address.
  services.qemuGuest.enable = true;

  # No channel here (channel.nix is off): without this NIX_PATH still names root's
  # channels, and every lookup warns that they do not exist. <nixpkgs> is the flake's.
  nix.channel.enable = false;
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

  # The installed server's shell and tools, which the template brings anyway.
  programs.fish.enable = true;
  users.defaultUserShell = pkgs.fish;
  programs.vim.enable = true;
  programs.git.enable = true;
  environment.systemPackages = [
    installer
    (pkgs.callPackage ./net-rescue.nix { })
    pkgs.htop
  ];

  services.getty.helpLine = lib.mkForce ''

    Proxy-suite installer. It starts on tty1; to run it again: sudo proxy-suite-install
  '';

  # Once, on tty1 only: other consoles (Alt+F2) stay plain shells. The console logs in
  # as nixos, which has passwordless sudo.
  programs.fish.interactiveShellInit = ''
    if test (tty) = /dev/tty1; and not test -e /tmp/.proxy-suite-install-started
      touch /tmp/.proxy-suite-install-started
      sudo proxy-suite-install
    end
  '';
}
