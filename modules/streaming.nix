# Streaming depuis le serveur : Jellyfin (vidéo), Seerr (demandes), Navidrome (musique),
# Audiobookshelf (livres audio, podcasts). Chaque brique s'active dans settings.nix.
#
# Accès par défaut : uniquement via Tailscale (ports non ouverts au public).
# Option streaming.publicDomain : Jellyfin exposé en HTTPS via Caddy (certificat
# Let's Encrypt automatique), pour les appareils qui ne peuvent pas avoir Tailscale.
{ lib, settings, ... }:
let
  s = settings.streaming;
  public = s.publicDomain != null;
in
lib.mkMerge [
  # ---------- Jellyfin : films et séries (port 8096) ----------
  # Transcodage : impossible sur l'Atom ; sur le Xeon E3-1245 v5, iGPU HD P530 (HEVC 8 bits
  # seulement, à vérifier avec lspci) ou logiciel, 1 à 2 flux 1080p ; la 4K HEVC, non.
  # Stratégie : privilégier la lecture directe (formats choisis dans Sonarr/Radarr,
  # clients compatibles), voir README phase 6.
  (lib.mkIf s.jellyfin {
    services.jellyfin = {
      enable = true;
      group = "media";
    };
    # Le streaming passe avant le torrent et les tâches de fond sur les disques.
    systemd.services.jellyfin.serviceConfig = {
      IOSchedulingClass = "best-effort";
      IOSchedulingPriority = 2;
    };
  })

  # ---------- Seerr : demandes de films/séries (port 5055) ----------
  (lib.mkIf s.seerr {
    services.seerr.enable = true;
  })

  # ---------- Navidrome : musique (port 4533) ----------
  (lib.mkIf s.navidrome {
    services.navidrome = {
      enable = true;
      group = "media";
      settings = {
        Address = "0.0.0.0"; # joignable via Tailscale ; port non ouvert au public
        Port = 4533;
        MusicFolder = "/srv/data/media/music";
        ScanSchedule = "@every 1h";
        EnableSharing = true;
      };
    };
  })

  # ---------- Audiobookshelf : livres audio et podcasts (port 13378) ----------
  (lib.mkIf s.audiobookshelf {
    services.audiobookshelf = {
      enable = true;
      group = "media";
      host = "0.0.0.0";
      port = 13378; # 8000 laissé libre pour tes side projects
    };
  })

  # ---------- Partage SMB en lecture seule (VLC, Kodi, explorateur de fichiers) ----------
  # Port 445 non ouvert au public : joignable seulement via tailscale0 (interface de
  # confiance, base.nix), et « hosts allow » limité aux adresses Tailscale en plus.
  # Mot de passe SMB distinct du compte Linux, à créer une fois : sudo smbpasswd -a <utilisateur>
  (lib.mkIf s.smb {
    services.samba = {
      enable = true;
      openFirewall = false;
      settings = {
        global = {
          "server string" = settings.hostName;
          "server min protocol" = "SMB3";
          "map to guest" = "never";
          "hosts allow" = "100.64.0.0/10 fd7a:115c:a1e0::/48 127.0.0.1 ::1";
          "hosts deny" = "ALL";
          "load printers" = "no";
        };
        media = {
          path = "/srv/data/media";
          "read only" = "yes";
          "valid users" = settings.userName;
          browseable = "yes";
        };
      };
    };
  })

  # ---------- Accès public à Jellyfin (optionnel) ----------
  (lib.mkIf (s.jellyfin && public) {
    services.caddy = {
      enable = true;
      virtualHosts.${s.publicDomain}.extraConfig = ''
        encode zstd gzip
        reverse_proxy 127.0.0.1:8096
      '';
    };
    networking.firewall.allowedTCPPorts = [ 80 443 ];
  })

  {
    assertions = [{
      assertion = !(public && !s.jellyfin);
      message = "streaming.publicDomain n'a d'effet qu'avec streaming.jellyfin = true.";
    }];
  }
]
