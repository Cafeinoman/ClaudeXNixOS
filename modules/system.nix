# Socle commun à toutes les machines. Les fichiers propres à chaque serveur
# (réseau, matériel, réglages) sont dans hosts/<machine>/ et ajoutés par flake.nix.
{ settings, ... }:
{
  imports = [
    ./disko.nix
    ./base.nix
    ./dev.nix
    ./media.nix       # groupe "media" et /srv/data, si seedbox ou streaming
    ./seedbox.nix     # inactif tant que seedbox.enable = false
    ./streaming.nix   # chaque service s'active dans settings.streaming
    ./proton-vpn.nix  # inactif tant que seedbox.vpn = false
    ./backup.nix      # inactif tant que backup.enable = false
  ];

  # Démarrage hybride : fonctionne que le Kimsufi soit en BIOS legacy ou en UEFI.
  # disko renseigne lui-même boot.loader.grub.devices grâce à la partition EF02.
  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
    configurationLimit = 20;
  };

  networking.hostName = settings.hostName;

  # Ne JAMAIS changer après l'installation, même lors d'une montée de version.
  system.stateVersion = "26.05";
}
