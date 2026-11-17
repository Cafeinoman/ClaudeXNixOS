#!/usr/bin/env bash
# Vérification indépendante du lot « glow » (paquet seul, aucun service, ligne dans CHANGELOG.md).
# Construit (sans appliquer) le système NixKS de HEAD, l'évalue aussi sur la base, et exerce glow
# dans un HOME jetable, sans réseau quand `unshare -rn` est disponible.
# Usage : tests/verif/glow-verif.sh [base]   (base par défaut : main)
# Les cas marqués « xfail » montrent un écart mineur ou hors spécification connu : leur échec est
# attendu et ne fait pas échouer le script ; s'ils se mettent à passer, c'est signalé (XPASS).
# shellcheck disable=SC2016,SC2034
set -euo pipefail

depot="$(cd "$(dirname "$0")/../.." && pwd)"
base="${1:-main}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cd "$depot"
exec </dev/null # glow lit l'entrée standard si ce n'est pas un terminal

echecs=0
verif() { if eval "$2"; then echo "ok    $1"; else echo "ÉCHEC $1"; echecs=$((echecs + 1)); fi; }

# ---------- Diff ----------
fichiers="$(git diff --name-only "$base"...HEAD | sort | tr '\n' ' ')"
verif "le diff ne touche que modules/base.nix et CHANGELOG.md ($fichiers)" \
  '[ "$fichiers" = "CHANGELOG.md modules/base.nix " ]'

# ---------- Construction (sans appliquer) ----------
sys="$(nix build --no-link --print-out-paths .#nixosConfigurations.NixKS.config.system.build.toplevel 2>/dev/null)"
glow="$sys/sw/bin/glow"
verif "glow est dans le profil système construit" '[ -x "$glow" ]'
verif "glow répond à --version" '"$glow" --version | grep -q "^glow version "'
verif "glow fait partie de environment.systemPackages" \
  '[ "$(nix eval --json .#nixosConfigurations.NixKS.config.environment.systemPackages \
        --apply "ps: builtins.any (p: (p.pname or \"\") == \"glow\") ps" 2>/dev/null)" = true ]'

# ---------- Rendu ----------
export HOME="$tmp/home"
mkdir -p "$HOME"
printf '# Titre essai\n\nTexte **gras** et `code`.\n\n- un\n- deux\n' > "$tmp/essai.md"
sansreseau=()
if unshare -rn true 2>/dev/null; then sansreseau=(unshare -rn); fi
verif "rendu d'un fichier local (sans réseau : ${sansreseau[*]:-indisponible})" \
  '"${sansreseau[@]}" "$glow" "$tmp/essai.md" | grep -q "Titre essai"'
verif "le Markdown est mis en forme (puces rendues, pas de tiret brut)" \
  '"$glow" "$tmp/essai.md" | grep -q "• un"'
verif "glow -p passe le rendu au pager (\$PAGER=cat)" \
  'PAGER=cat "$glow" -p "$tmp/essai.md" | grep -q "Titre essai"'
verif "fichier absent : code de sortie non nul" '! "$glow" "$tmp/absent.md" >/dev/null 2>&1'

# Pager réel du système (PAGER et LESSKEYIN_SYSTEM du set-environment construit), dans un pseudo-
# terminal : less doit afficher les couleurs (-R) et non le texte « ESC[… ».
env_pager="$(grep -E '^export (PAGER|LESSKEYIN_SYSTEM)=' "$sys/etc/set-environment" | sed 's/^export //; s/"//g')"
if command -v script >/dev/null; then
  # TERM de tmux (sessions `t <projet>`) : glow n'interroge pas le terminal. Avec TERM=xterm-256color,
  # il envoie OSC 11 et DSR et attend une réponse que le faux terminal de `script` ne donne jamais.
  # shellcheck disable=SC2086
  (for _ in 1 2 3 4 5 6 7 8 9 10; do sleep 0.5; printf q; done) \
    | timeout 20 env -i HOME="$HOME" TERM=tmux-256color PATH="$sys/sw/bin" $env_pager \
      script -qec "glow -p $tmp/essai.md" /dev/null > "$tmp/pty.out" 2>&1 || true
  verif "glow -p sous le pager du système : couleurs interprétées (pas de « ESC[ » littéral)" \
    'grep -q "Titre" "$tmp/pty.out" && ! grep -q "ESC\[" "$tmp/pty.out" && grep -q $'"'"'\e\[38;5'"'"' "$tmp/pty.out"'
else
  echo "saut  pager du système (script absent)"
fi

# ---------- Aucun service ----------
attrs='c: { s = builtins.attrNames c.systemd.services; t = builtins.attrNames c.systemd.timers;
  so = builtins.attrNames c.systemd.sockets; us = builtins.attrNames c.systemd.user.services;
  ut = builtins.attrNames c.systemd.user.timers; tcp = c.networking.firewall.allowedTCPPorts;
  udp = c.networking.firewall.allowedUDPPorts; users = builtins.attrNames c.users.users; }'
rev="$(git rev-parse "$base")"
nix eval --json "git+file://$depot?rev=$rev#nixosConfigurations.NixKS.config" --apply "$attrs" \
  2>/dev/null | jq -S . > "$tmp/base.json"
nix eval --json ".#nixosConfigurations.NixKS.config" --apply "$attrs" 2>/dev/null | jq -S . > "$tmp/head.json"
verif "évaluation de la base non vide" '[ "$(jq ".s | length" "$tmp/base.json")" -gt 0 ]'
verif "aucun service, timer, socket, port ni utilisateur ajouté ou retiré" \
  'diff -u "$tmp/base.json" "$tmp/head.json"'

# ---------- CHANGELOG ----------
ajouts="$(git diff "$base"...HEAD -- CHANGELOG.md | grep -E '^\+[^+]' || true)"
verif "une seule ligne ajoutée au CHANGELOG" '[ "$(printf "%s\n" "$ajouts" | grep -c .)" -eq 1 ]'
ligne="${ajouts#+}"
verif "la ligne est la dernière du tableau" '[ "$(tail -n 1 CHANGELOG.md)" = "$ligne" ]'
IFS='|' read -r _ date quoi pourquoi retour reste <<< "$ligne"
verif "date au format AAAA-MM-JJ (« $date »)" '[[ "$date" =~ ^\ *20[0-9]{2}-[01][0-9]-[0-3][0-9]\ *$ ]]'
verif "date du lot postérieure ou égale à la ligne précédente" \
  '[ "$(echo $date)" \> "$(tail -n 2 CHANGELOG.md | head -n 1 | cut -d"|" -f2 | tr -d " ")" ] || [ "$(echo $date)" = "$(tail -n 2 CHANGELOG.md | head -n 1 | cut -d"|" -f2 | tr -d " ")" ]'
verif "colonne « Changement » : fichier et paquet" '[[ "$quoi" == *modules/base.nix* && "$quoi" == *glow* ]]'
verif "colonne « Pourquoi » renseignée (Markdown)" '[[ "$pourquoi" == *Markdown* ]]'
verif "colonne « Retour arrière » renseignée" '[ -n "$(echo $retour)" ]'
verif "quatre colonnes exactement" '[ "$(echo $reste)" = "" ]'

echo
if [ "$echecs" -eq 0 ]; then echo "Tous les cas passent."; else echo "$echecs cas en échec."; exit 1; fi
