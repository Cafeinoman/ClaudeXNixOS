#!/usr/bin/env bash
# Vérifie si un Kimsufi KS-5 (Xeon E3-1270 v6, 32 Go, 2 x 2 To HDD) est en stock dans un
# datacenter acceptable : France (Gravelines, Roubaix, Strasbourg), Londres ou Francfort.
# 17,99 € HT/mois (21,59 € TTC), prix catalogue du 25/10/2026.
# Source : API publique d'OVH, sans compte ni clé.
#
# Usage :  bash scripts/ks-stock-check.sh
#          NTFY_TOPIC=mon-sujet-secret bash scripts/ks-stock-check.sh   # + notif sur le téléphone (app ntfy)
#          PLAN=24sk302 bash scripts/ks-stock-check.sh                  # autre offre (ici le KS-3)
# Code de sortie : 0 = disponible, 1 = rupture, 2 = erreur.
set -euo pipefail

PLAN="${PLAN:-24sk50-v1}"                          # KS-5, Europe
STORAGE="${STORAGE:-softraid-2x2000sa}"
MEMORY="${MEMORY:-ram-32g}"                        # préfixe : ram-32g-ecc-2400…
DATACENTERS="${DATACENTERS:-gra rbx sbg lon fra}"  # France, Londres, Francfort
ORDER_URL="${ORDER_URL:-https://eco.ovhcloud.com/fr/kimsufi/ks-5/}"

declare -A DC_NAME=(
  [gra]="Gravelines" [rbx]="Roubaix" [sbg]="Strasbourg" [lon]="Londres" [fra]="Francfort"
)

json="$(curl -fsS --max-time 20 \
  "https://eu.api.ovh.com/1.0/dedicated/server/datacenter/availabilities?planCode=${PLAN}")" \
  || { echo "Erreur : API OVH injoignable" >&2; exit 2; }

hits="$(jq -r --arg st "$STORAGE" --arg mem "$MEMORY" --arg dcs "$DATACENTERS" '
  ($dcs | split(" ")) as $want
  | .[] | select(.storage == $st and (.memory | startswith($mem))) as $o
  | $o.datacenters[]
  | select(.datacenter as $d | $want | index($d))
  | select(.availability != "unavailable" and .availability != "unknown")
  | "\(.datacenter) \($o.memory) \(.availability)"' <<<"$json")"

if [[ -n "$hits" ]]; then
  lines=()
  while read -r dc mem delay; do
    lines+=("$mem à ${DC_NAME[$dc]:-$dc} (délai : $delay)")
  done <<<"$hits"
  joined="$(printf '%s ; ' "${lines[@]}")"
  msg="KS-5 disponible : ${joined% ; }. Commander : $ORDER_URL"
  echo "$msg"
  if [[ -n "${NTFY_TOPIC:-}" ]]; then
    curl -fsS --max-time 10 -H "Title: KS-5 en stock" -H "Priority: high" \
      -H "Click: $ORDER_URL" -d "$msg" "https://ntfy.sh/$NTFY_TOPIC" >/dev/null || true
  fi
  exit 0
fi

echo "KS-5 : rupture (France, Londres, Francfort) le $(date '+%d/%m à %H:%M')."
exit 1
