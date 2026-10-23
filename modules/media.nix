# Socle commun à la seedbox et au streaming : groupe "media" et arborescence /srv/data.
#
# Tout est sur le même système de fichiers, pour que Sonarr/Radarr/Lidarr importent par
# lien physique (hardlink) : un fichier à la fois en partage (torrents/) et rangé dans
# la bibliothèque (media/) n'occupe l'espace qu'une seule fois.
#
#   /srv/data/torrents/{tv,movies,music}   ← qBittorrent télécharge et partage ici
#   /srv/data/media/tv, movies             ← Sonarr / Radarr  → Jellyfin
#   /srv/data/media/music                  ← Lidarr           → Navidrome
#   /srv/data/media/audiobooks, podcasts   ← dépôt manuel (SFTP) → Audiobookshelf
{ lib, settings, ... }:
let
  s = settings.streaming;
  enabled = settings.seedbox.enable
    || s.jellyfin || s.seerr || s.navidrome || s.audiobookshelf;
  dirs = [
    "" "/torrents" "/torrents/tv" "/torrents/movies" "/torrents/music"
    "/media" "/media/tv" "/media/movies" "/media/music"
    "/media/audiobooks" "/media/podcasts"
  ];
in
lib.mkIf enabled {
  users.groups.media = { };
  users.users.${settings.userName}.extraGroups = [ "media" ];

  # setgid (2xxx) : tout ce qui est créé dedans hérite du groupe "media".
  systemd.tmpfiles.rules = map (d: "d /srv/data${d} 2775 root media - -") dirs;
}
