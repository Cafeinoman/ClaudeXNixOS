# Machine "NixKS" : Kimsufi KS-5 (Xeon E3-1270 v6, sans iGPU, 32 Go, 2 x 2 To en RAID 1).
# Rôle : serveur principal (développement, seedbox, streaming).
#
# Installée le 11/11/2026. Chaque option ci-dessous dépend d'un fichier absent d'une machine
# neuve ; l'activer AVANT d'avoir ce fichier casse l'évaluation ou le démarrage du service :
#   - backup, recyclarr : secrets/NixKS.yaml (sops) — DANS GIT avant le rebuild ;
#   - seedbox.vpn : /var/lib/secrets/proton.conf — sur le serveur avant le rebuild ;
#   - locanalyse : archive dans /var/lib/locanalyse-src/ et une adresse publique (un nom de
#     domaine évite de rejumeler à chaque changement de serveur). Pas encore activé.
let
  common = import ../../settings-common.nix;
in
common // {
  hostName = "NixKS";

  # Deux disques → RAID 1 logiciel (miroir mdadm), 2 To utiles. Confirmés par `lsblk` le
  # 11/11/2026 (HGST HUS724020ALA640). Ne pas modifier : seul disko (réinstallation) s'en sert.
  disks = [ "/dev/sda" "/dev/sdb" ];

  lowSpecHardware = false;

  # Mêmes services qu'atom (déménagement, README) : l'état des applications est importé
  # ensuite avec migrate-app-state.sh. Recyclarr échoue (clés API d'atom) jusqu'à cet import.
  seedbox = common.seedbox // {
    enable = true;
    bazarr = false;
    lidarr = false;
    vpn = true;        # /var/lib/secrets/proton.conf déposé AVANT le rebuild
    recyclarr = true;  # sonarr_api_key / radarr_api_key d'atom, dans secrets/NixKS.yaml
  };

  # Sauvegarde B2 nocturne, dépôt b2:NixOS-save:NixKS. Copie Proton Drive possible sur ce
  # CPU, mais jamais testée : à activer séparément (protonCopy, puis `sauvegarde-proton install`).
  backup = common.backup // {
    enable = true;
    protonCopy = false;
  };

  streaming = common.streaming // {
    jellyfin = true;        # films et séries, client sur TV / téléphone / navigateur
    seerr = true;           # catalogue de demandes « à la Netflix », branché sur Sonarr/Radarr
    navidrome = false;      # musique (API Subsonic : apps Symfonium, Substreamer, Feishin…)
    audiobookshelf = false; # livres audio et podcasts, avec reprise de lecture
    smb = true;             # partage SMB en lecture seule de /srv/data/media, via Tailscale
    # Exposer Jellyfin sur Internet en HTTPS, pour des appareils sans Tailscale.
    # null = accès uniquement via Tailscale (recommandé). Ex. : "jellyfin.mondomaine.fr"
    publicDomain = null;
  };
}
