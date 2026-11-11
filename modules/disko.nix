# Partitionnement déclaratif, adapté au nombre de disques de settings.nix :
#  - 1 disque  : GPT [BIOS | ESP | swap | btrfs]
#  - 2 disques : GPT [BIOS | ESP | swap | root] sur chaque disque, puis trois miroirs
#                mdadm, un par partition : /boot (metadata 1.0, lisible par le firmware
#                UEFI), swap, btrfs. Pas de table de partitions DANS un RAID : dans le
#                rescue du KS-5, le noyau refusait de la relire (partprobe « in use »).
#    Avantage du mdadm sur un serveur sans console : si un disque meurt, le serveur
#    redémarre seul sur le disque restant (mode dégradé), sans intervention.
# GRUB est installé sur chaque disque (partition EF02) : démarrage BIOS ou UEFI.
# Utilisé deux fois : par disko pour formater, puis par NixOS pour monter les disques.
{ lib, pkgs, settings, ... }:
let
  mdadmAlert = pkgs.writeShellScript "mdadm-alert" ''
    # Appelé par mdadm : $1 = événement (Fail, DegradedArray…), $2 = RAID, $3 = disque
    ${pkgs.util-linux}/bin/logger -p daemon.crit -t mdadm-alert "RAID : $1 sur $2 ''${3:-}"
  '';

  disks = settings.disks;
  raid = builtins.length disks >= 2;

  # zstd niveau 1 : compression légère, utile sur disque dur lent.
  opts = [ "compress=zstd:1" "noatime" ];

  btrfsRoot = {
    type = "btrfs";
    extraArgs = [ "-f" ];
    subvolumes = {
      "@root" = { mountpoint = "/"; mountOptions = opts; };
      "@nix" = { mountpoint = "/nix"; mountOptions = opts; };
      "@home" = { mountpoint = "/home"; mountOptions = opts; };
      # Données (torrents, médias) : sans compression, inutile sur de la vidéo.
      "@srv" = { mountpoint = "/srv"; mountOptions = [ "noatime" ]; };
    };
  };

  esp = {
    type = "filesystem";
    format = "vfat";
    mountpoint = "/boot";
    mountOptions = [ "umask=0077" ];
  };

  biosPartition = {
    size = "1M";
    type = "EF02"; # GRUB en mode BIOS legacy
    priority = 1;
  };

  singleDisk = {
    disk.main = {
      type = "disk";
      device = builtins.head disks;
      content = {
        type = "gpt";
        partitions = {
          bios = biosPartition;
          ESP = { size = "1G"; type = "EF00"; content = esp; };
          swap = { size = settings.swapSize; content.type = "swap"; };
          root = { size = "100%"; content = btrfsRoot; };
        };
      };
    };
  };

  raidDisk = i: device: lib.nameValuePair "disk${toString i}" {
    type = "disk";
    inherit device;
    content = {
      type = "gpt";
      partitions = {
        bios = biosPartition;
        ESP = {
          size = "1G";
          type = "EF00";
          content = { type = "mdraid"; name = "boot"; };
        };
        swap = {
          size = settings.swapSize;
          content = { type = "mdraid"; name = "swap"; };
        };
        root = {
          size = "100%";
          content = { type = "mdraid"; name = "root"; };
        };
      };
    };
  };

  mirrored = {
    disk = builtins.listToAttrs (lib.imap1 raidDisk disks);
    mdadm = {
      boot = {
        type = "mdadm";
        level = 1;
        metadata = "1.0"; # métadonnées en fin de partition : le firmware voit une FAT normale
        content = esp;
      };
      swap = {
        type = "mdadm";
        level = 1;
        content.type = "swap";
      };
      root = {
        type = "mdadm";
        level = 1;
        content = btrfsRoot;
      };
    };
  };
in
{
  disko.devices = if raid then mirrored else singleDisk;

  # Alerte quand un disque du RAID tombe : message dans le journal
  # (journalctl -t mdadm-alert), et `cat /proc/mdstat` montre [U_] au lieu de [UU].
  boot.swraid.mdadmConf = lib.mkIf raid ''
    PROGRAM ${mdadmAlert}
  '';
}
