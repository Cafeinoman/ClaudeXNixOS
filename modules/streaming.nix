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
  # Le Xeon E3-1230 v6 n'a pas de puce graphique : pas de transcodage matériel.
  # Le transcodage logiciel tient 1 à 2 flux 1080p ; la 4K HEVC en transcodage, non.
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
