#!/usr/bin/env bash
# Vérifie si un Kimsufi KS-3 ou KS-5 (2 x 2 To, 32 Go) est en stock en France.
#   KS-3 (24sk302)   : Xeon E3-1245 v5, iGPU HD P530 (transcodage HEVC 8 bits), 18,99 € HT
#   KS-5 (24sk50-v1) : Xeon E3-1270 v6, plus rapide, sans iGPU, 17,99 € HT
# Source : API publique d'OVH, sans compte ni clé.
#
# Usage :  bash scripts/ks-stock-check.sh
#          PLANS=24sk50-v1 bash scripts/ks-stock-check.sh            # une seule offre
#          NTFY_TOPIC=mon-sujet-secret bash scripts/ks-stock-check.sh # + notif sur le téléphone (app ntfy)
# Code de sortie : 0 = au moins une offre disponible, 1 = rupture, 2 = erreur.
set -euo pipefail

PLANS="${PLANS:-24sk302 24sk50-v1}"
STORAGE="${STORAGE:-softraid-2x2000sa}"
MEMORY="${MEMORY:-ram-32g}"                # préfixe : ram-32g-ecc-2133, ram-32g-ecc-2400…
DATACENTERS="${DATACENTERS:-gra rbx sbg}"  # Gravelines, Roubaix, Strasbourg

name_of() { case "$1" in 24sk302) echo "KS-3";; 24sk50-v1) echo "KS-5";; *) echo "$1";; esac; }
url_of()  { case "$1" in 24sk302) echo "https://eco.ovhcloud.com/fr/kimsufi/ks-3/";;
                         24sk50-v1) echo "https://eco.ovhcloud.com/fr/kimsufi/ks-5/";;
                         *) echo "https://eco.ovhcloud.com/fr/kimsufi/";; esac; }

found=0
for plan in $PLANS; do
  json="$(curl -fsS --max-time 20 \
    "https://eu.api.ovh.com/1.0/dedicated/server/datacenter/availabilities?planCode=${plan}")" \
    || { echo "Erreur : API OVH injoignable ($plan)" >&2; exit 2; }

  hits="$(jq -r --arg st "$STORAGE" --arg mem "$MEMORY" --arg dcs "$DATACENTERS" '
    ($dcs | split(" ")) as $want
    | .[] | select(.storage == $st and (.memory | startswith($mem))) as $o
    | $o.datacenters[]
    | select(.datacenter as $d | $want | index($d))
    | select(.availability != "unavailable" and .availability != "unknown")
    | "\($o.memory) à \(.datacenter) (délai : \(.availability))"' <<<"$json")"

  name="$(name_of "$plan")"
  if [[ -n "$hits" ]]; then
    found=1
    url="$(url_of "$plan")"
    msg="$name disponible en France : ${hits//$'\n'/ ; }. Commander : $url"
    echo "$msg"
    if [[ -n "${NTFY_TOPIC:-}" ]]; then
      curl -fsS --max-time 10 -H "Title: $name en stock" -H "Priority: high" \
        -H "Click: $url" -d "$msg" "https://ntfy.sh/$NTFY_TOPIC" >/dev/null || true
    fi
  else
    echo "$name : rupture en France ($(date '+%d/%m %H:%M'))."
  fi
done

(( found )) && exit 0
exit 1
