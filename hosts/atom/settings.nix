# Machine "atom" : Kimsufi KS-3 ancien modèle (Atom N2800, 4 Go, 1 x 2 To).
# Rôle : rodage NixOS, seedbox, et test de la lecture directe (Jellyfin sans transcodage).
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
    enable = true;   # qBittorrent + Prowlarr + Sonarr + Radarr (~1 Go de RAM)
    bazarr = false;  # sous-titres automatiques (+ ~250 Mo)
    lidarr = false;  # musique (+ ~250 Mo)
    # qBittorrent uniquement via Proton VPN (offre payante + serveur P2P requis).
    # Dépose d'abord le fichier WireGuard sur le serveur : README, phase 4 bis.
    vpn = true;
    # Clés API de Sonarr et Radarr à ajouter AVANT le rebuild : sops secrets/atom.yaml
    recyclarr = true;
  };

  # Test de la lecture DIRECTE avant de choisir le serveur suivant : le processeur ne peut
  # pas transcoder. Désactiver le transcodage pour chaque utilisateur dans Jellyfin
  # (Tableau de bord → Utilisateurs → « Autoriser la lecture nécessitant un transcodage »).
  # Sauvegarde B2 nocturne. Pas de copie Proton Drive : son CLI (compilé avec Bun, build
  # « baseline ») exige SSE4.2/POPCNT, absents de l'Atom.
  backup = common.backup // {
    enable = true;
    protonCopy = false;
  };

  # Serveur de veille Locanalyse (conteneur isolé, seul service exposé à Internet : 80, 443, 8443).
  # Adresse = IP de l'atom : elle est inscrite dans les codes de jumelage, qui seront à refaire au passage
  # sur NixKS. Archive à déposer AVANT le rebuild : /var/lib/locanalyse-src/locanalyse-serveur.tar.gz.
  locanalyse = common.locanalyse // {
    enable = true;
    publicHost = "37.187.126.47";   # ntfy : même adresse, port 8443
    narHash = "sha256-fWFM9+1UBx7H1X601mv1efek2KjPva7R4qw4jPRDX78="; # dist 2.0.0-dev+08cd29d
    memoryMax = "1G";               # 4 Go partagés avec la seedbox et Jellyfin
  };

  streaming = common.streaming // {
    jellyfin = true;
    seerr = true;
    smb = true;
  };
}
