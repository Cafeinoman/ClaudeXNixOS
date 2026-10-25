#!/usr/bin/env bash
# Déménage l'état des applications (Sonarr, Radarr, Prowlarr, qBittorrent, Bazarr,
# Lidarr, Jellyfin, Seerr, Navidrome, Audiobookshelf) d'une machine à l'autre :
# bases de données, réglages, clés API, comptes, historique.
#
# Les deux machines ont la même arborescence (/srv/data/...) et les mêmes services
# déclarés dans Nix : l'état copié fonctionne tel quel sur la nouvelle machine.
#
# 1. Sur l'ancienne machine (ex. atom) :
#      sudo bash scripts/migrate-app-state.sh export
#    → crée ~/app-state-<machine>-<date>.tar.gz (services arrêtés le temps de la copie)
# 2. Copie le fichier vers la nouvelle machine (via Tailscale) :
#      scp ~/app-state-*.tar.gz nixks:
# 3. Sur la nouvelle machine (ex. NixKS), APRÈS avoir activé les mêmes services dans
#    hosts/NixKS/settings.nix et fait un `rebuild` :
#      sudo bash scripts/migrate-app-state.sh import ~/app-state-atom-....tar.gz
# 4. Données (téléchargements, médias), si besoin, en tant que ton utilisateur :
#      rsync -aP --info=progress2 atom:/srv/data/ /srv/data/
#
# L'archive contient des secrets (clés API, mots de passe chiffrés, cookies d'indexeurs) :
# ne la mets ni dans Git ni sur un partage public, et supprime-la après l'import.
set -euo pipefail

SERVICES=(sonarr radarr prowlarr qbittorrent bazarr lidarr jellyfin seerr navidrome audiobookshelf)
DIRS=(
  /var/lib/sonarr /var/lib/radarr /var/lib/private/prowlarr /var/lib/qBittorrent
  /var/lib/bazarr /var/lib/lidarr /var/lib/jellyfin /var/lib/seerr
  /var/lib/navidrome /var/lib/audiobookshelf
)

die() { printf 'ERREUR : %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "lance-le avec sudo."

active_services() {
  local s
  for s in "${SERVICES[@]}"; do
    systemctl is-active --quiet "$s.service" && echo "$s"
  done
  return 0
}

existing_services() {
  local s
  for s in "${SERVICES[@]}"; do
    systemctl cat "$s.service" >/dev/null 2>&1 && echo "$s"
  done
  return 0
}

mode="${1:-}"
case "$mode" in
  export)
    owner="${SUDO_USER:-root}"
    home="$(getent passwd "$owner" | cut -d: -f6)"
    out="$home/app-state-$(hostname)-$(date +%Y%m%d-%H%M).tar.gz"
    present=()
    for d in "${DIRS[@]}"; do [[ -d "$d" ]] && present+=("${d#/}"); done
    (( ${#present[@]} )) || die "aucun dossier d'application trouvé."

    mapfile -t running < <(active_services)
    echo "Arrêt des services pour une copie cohérente : ${running[*]:-aucun}"
    (( ${#running[@]} )) && systemctl stop "${running[@]/%/.service}"
    trap '(( ${#running[@]} )) && systemctl start "${running[@]/%/.service}"' EXIT

    # Exclut les caches (affiches, images), régénérés automatiquement.
    tar -czpf "$out" -C / \
      --exclude='*/MediaCover' --exclude='*/cache' --exclude='*/logs' \
      --exclude='*/Backups' --exclude='*/transcodes' \
      "${present[@]}"
    chown "$owner" "$out"
    chmod 600 "$out"
    echo "Archive créée : $out ($(du -h "$out" | cut -f1))"
    echo "Contenu : ${present[*]}"
    ;;

  import)
    archive="${2:-}"
    [[ -f "$archive" ]] || die "usage : sudo bash $0 import <archive.tar.gz>"
    mapfile -t declared < <(existing_services)
    echo "Services déclarés sur cette machine : ${declared[*]:-aucun}"
    echo "Dossiers dans l'archive :"
    tar -tzf "$archive" | awk -F/ '$3=="private" && $4!="" {print "  /"$1"/"$2"/"$3"/"$4; next}
                                   $3!="private" && $3!="" {print "  /"$1"/"$2"/"$3}' | sort -u
    read -r -p "Les données actuelles de ces applications seront REMPLACÉES. Taper OUI : " ok
    [[ "$ok" == "OUI" ]] || die "abandon."

    mapfile -t running < <(active_services)
    (( ${#running[@]} )) && systemctl stop "${running[@]/%/.service}"

    # Les propriétaires sont restaurés par NOM (sonarr, radarr, qbittorrent…) :
    # les numéros d'utilisateur peuvent différer d'une machine à l'autre sans souci.
    tar -xzpf "$archive" -C /

    (( ${#declared[@]} )) && systemctl start "${declared[@]/%/.service}"
    echo "Import terminé. Vérifie chaque interface web, puis supprime l'archive :"
    echo "  shred -u $archive"
    ;;

  *)
    sed -n '2,24p' "$0"
    exit 1
    ;;
esac
