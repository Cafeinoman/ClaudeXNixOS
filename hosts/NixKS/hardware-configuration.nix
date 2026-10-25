# EXEMPLE — remplacé pendant l'installation par
# `nixos-generate-config --no-filesystems --show-hardware-config`.
# Les systèmes de fichiers ne sont PAS ici : c'est disko.nix qui les déclare.
{ lib, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [ "ahci" "nvme" "xhci_pci" "usb_storage" "sd_mod" ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
