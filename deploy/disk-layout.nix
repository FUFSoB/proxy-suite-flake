# The disk layout of an installed server, for disko: GPT with a BIOS boot partition (GRUB
# on BIOS), an ESP on /boot (GRUB on UEFI) and btrfs over the rest, compressed, with a
# subvolume per mount point and a swap file. Subvolumes follow the @ convention: @ is /,
# @<name> the rest. services.proxy-suite-server.disko uses it
# for the installed system; proxy-suite-install passes it to the disko CLI to partition.
{
  device,
  swapSize ? "2G",
  ...
}:

let
  mountOptions = [
    "compress=zstd:3"
    "noatime"
  ];
in
{
  disko.devices.disk.main = {
    type = "disk";
    inherit device;
    content = {
      type = "gpt";
      partitions = {
        bios = {
          size = "1M";
          type = "EF02";
          priority = 1;
        };
        ESP = {
          size = "512M";
          type = "EF00";
          priority = 2;
          content = {
            type = "filesystem";
            format = "vfat";
            extraArgs = [
              "-n"
              "ESP"
            ];
            mountpoint = "/boot";
            mountOptions = [ "umask=077" ];
          };
        };
        root = {
          size = "100%";
          content = {
            type = "btrfs";
            extraArgs = [
              "-f"
              "-L"
              "nixos"
            ];
            subvolumes = {
              "@" = {
                mountpoint = "/";
                inherit mountOptions;
              };
              "@nix" = {
                mountpoint = "/nix";
                inherit mountOptions;
              };
              "@varlog" = {
                mountpoint = "/var/log";
                inherit mountOptions;
              };
              "@home" = {
                mountpoint = "/home";
                inherit mountOptions;
              };
              # btrfs filesystem mkswapfile makes the file NOCOW, so it is never compressed.
              "@swap" = {
                mountpoint = "/swap";
                mountOptions = [ "noatime" ];
                swap.swapfile.size = swapSize;
              };
            };
          };
        };
      };
    };
  };
}
