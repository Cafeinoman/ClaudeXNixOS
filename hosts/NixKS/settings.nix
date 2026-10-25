# Machine "NixKS" : Kimsufi KS-5 (Xeon E3-1270 v6, sans iGPU, 32 Go, 2 x 2 To en RAID 1).
# Rôle : serveur principal (développement, seedbox, streaming).
let
  common = import ../../settings-common.nix;
in
common // {
  hostName = "NixKS";

  # Deux disques → RAID 1 logiciel (miroir mdadm), 2 To utiles. ILS SERONT EFFACÉS.
  # Noms à confirmer avec `lsblk` dans le rescue.
  disks = [ "/dev/sda" "/dev/sdb" ];

  lowSpecHardware = false;

  seedbox = common.seedbox // {
    enable = false;
    bazarr = false;
    lidarr = false;
    vpn = false;
    recyclarr = false;
  };

  streaming = common.streaming // {
    jellyfin = false;       # films et séries, client sur TV / téléphone / navigateur
    seerr = false;          # catalogue de demandes « à la Netflix », branché sur Sonarr/Radarr
    navidrome = false;      # musique (API Subsonic : apps Symfonium, Substreamer, Feishin…)
    audiobookshelf = false; # livres audio et podcasts, avec reprise de lecture
    smb = false;            # partage SMB en lecture seule de /srv/data/media, via Tailscale
    # Exposer Jellyfin sur Internet en HTTPS, pour des appareils sans Tailscale.
    # null = accès uniquement via Tailscale (recommandé). Ex. : "jellyfin.mondomaine.fr"
    publicDomain = null;
  };
}
