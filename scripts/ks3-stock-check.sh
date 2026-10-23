#!/usr/bin/env bash
# Vérifie si un Kimsufi KS-3 (Xeon E3-1245 v5, 32 Go, 2 x 2 To) est en stock en France.
# Source : API publique d'OVH, sans compte ni clé.
#
# Usage :  bash scripts/ks3-stock-check.sh
#          NTFY_TOPIC=mon-sujet-secret bash scripts/ks3-stock-check.sh   # + notif sur le téléphone (app ntfy)
# Code de sortie : 0 = disponible, 1 = rupture, 2 = erreur.
set -euo pipefail

PLAN="${PLAN:-24sk302}"                    # KS-3, Europe
STORAGE="${STORAGE:-softraid-2x2000sa}"
DATACENTERS="${DATACENTERS:-gra rbx sbg}"  # Gravelines, Roubaix, Strasbourg
ORDER_URL="https://eco.ovhcloud.com/fr/kimsufi/ks-3/"

json="$(curl -fsS --max-time 20 \
  "https://eu.api.ovh.com/1.0/dedicated/server/datacenter/availabilities?planCode=${PLAN}")" \
  || { echo "Erreur : API OVH injoignable" >&2; exit 2; }

hits="$(jq -r --arg st "$STORAGE" --arg dcs "$DATACENTERS" '
  ($dcs | split(" ")) as $want
  | .[] | select(.storage == $st) as $o
  | $o.datacenters[]
  | select(.datacenter as $d | $want | index($d))
  | select(.availability != "unavailable" and .availability != "unknown")
  | "\($o.memory) à \(.datacenter) (délai : \(.availability))"' <<<"$json")"

if [[ -n "$hits" ]]; then
  msg="KS-3 disponible en France : ${hits//$'\n'/ ; }. Commander : $ORDER_URL"
  echo "$msg"
  if [[ -n "${NTFY_TOPIC:-}" ]]; then
    curl -fsS --max-time 10 -H "Title: KS-3 en stock" -H "Priority: high" \
      -H "Click: $ORDER_URL" -d "$msg" "https://ntfy.sh/$NTFY_TOPIC" >/dev/null || true
  fi
  exit 0
fi

echo "KS-3 : rupture en France ($(date '+%d/%m %H:%M'))."
exit 1
