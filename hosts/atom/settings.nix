# Machine "atom" : Kimsufi KS-3 ancien modèle (Atom N2800, 4 Go, 1 x 2 To).
# Rôle : rodage NixOS, développement avec Claude Code, seedbox. Pas de streaming.
let
  common = import ../../settings-common.nix;
in
common // {
  hostName = "atom";

  # Disque système, vérifie avec `lsblk` dans le mode rescue. IL SERA EFFACÉ.
  disks = [ "/dev/sda" ];

  # Petite machine : zram agressif, documentation désactivée, compilation limitée.
  lowSpecHardware = true;

  seedbox = common.seedbox // {
    enable = false;  # qBittorrent + Prowlarr + Sonarr + Radarr (~1 Go de RAM)
    bazarr = false;  # sous-titres automatiques (+ ~250 Mo)
    lidarr = false;  # musique (+ ~250 Mo)
    # qBittorrent uniquement via Proton VPN (offre payante + serveur P2P requis).
    # Dépose d'abord le fichier WireGuard sur le serveur : README, phase 4 bis.
    vpn = false;
  };

  # Pas de streaming sur l'Atom : processeur incapable de transcoder, 4 Go de RAM.
}
