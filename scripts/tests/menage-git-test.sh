#!/usr/bin/env bash
# Les vérifications sont des chaînes évaluées plus tard (verif) : guillemets simples voulus.
# shellcheck disable=SC2016,SC2034
# Tests de scripts/menage-git.sh sur des dépôts jetables (remote nu local, faux gh, faux notificateur).
# Usage : scripts/tests/menage-git-test.sh   (aussi lancé par « nix flake check »)
set -euo pipefail

script="${MENAGE_SCRIPT:-$(cd "$(dirname "$0")/.." && pwd)/menage-git.sh}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$tmp/bin" "$tmp/gh"
git config --global user.name Test
git config --global user.email test@example.org
git config --global init.defaultBranch main
git config --global advice.detachedHead false

# Faux gh : renvoie les lignes déjà formatées de $tmp/gh/<dépôt>.merged|.open ; échoue sans fichier.
cat > "$tmp/bin/gh" <<EOF
#!$(command -v bash)
nom="\$(basename "\$PWD")"
case "\$*" in
  *"--state merged"*) f="$tmp/gh/\$nom.merged" ;;
  *"--state open"*)   f="$tmp/gh/\$nom.open" ;;
esac
[ -f "\$f" ] || exit 1
cat "\$f"
EOF
cat > "$tmp/bin/notifier" <<EOF
#!$(command -v bash)
{ echo "TITRE: \$1"; cat; } > "$tmp/notification"
EOF
chmod +x "$tmp/bin/gh" "$tmp/bin/notifier"
export PATH="$tmp/bin:$PATH"

echecs=0
ok()   { echo "ok   $1"; }
ko()   { echo "ÉCHEC $1"; echecs=$((echecs + 1)); }
verif() { if eval "$2"; then ok "$1"; else ko "$1"; fi; }
a_branche()  { git -C "$1" rev-parse --verify --quiet "refs/heads/$2" >/dev/null; }
a_distante() { git -C "$tmp/remotes/$(basename "$1").git" rev-parse --verify --quiet "refs/heads/$2" >/dev/null; }
courante()   { git -C "$1" symbolic-ref --short HEAD; }
commit()     { echo "$2" >> "$1/f"; git -C "$1" add f; git -C "$1" commit -qm "$2"; }

nouveau() { # $1 = chemin du dépôt : remote nu + clone avec un commit sur main
  local d="$1" r
  r="$tmp/remotes/$(basename "$d").git"
  git init -q --bare "$r"
  git clone -q "$r" "$d" 2>/dev/null
  commit "$d" init
  git -C "$d" push -q -u origin main
  git -C "$d" remote set-head origin main
}

racine="$HOME"

# --- Dépôt « projet » : cas nominaux ---
p="$racine/projects/projet"; nouveau "$p"
# PR fusionnée en squash (main reçoit un autre commit) ; branche courante.
git -C "$p" switch -qc fusionnee-pr; commit "$p" travail1; git -C "$p" push -q -u origin fusionnee-pr
echo "fusionnee-pr $(git -C "$p" rev-parse HEAD)" > "$tmp/gh/projet.merged"
# Branche fusionnée par vrai merge, branche distante supprimée (amont disparu), sans PR connue.
git -C "$p" switch -qc amont-disparu main; commit "$p" travail2; git -C "$p" push -q -u origin amont-disparu
git -C "$p" switch -q main; git -C "$p" merge -q --no-ff -m merge amont-disparu
git -C "$p" push -q origin main; git -C "$p" push -q origin --delete amont-disparu
# Branche neuve sans commit ni PR : contenue dans main, mais jamais supprimée.
git -C "$p" branch neuve main
# PR fusionnée, mais la branche locale a un commit de plus : gardée.
git -C "$p" switch -qc pr-modifiee main; commit "$p" v1; git -C "$p" push -q -u origin pr-modifiee
echo "pr-modifiee $(git -C "$p" rev-parse HEAD)" >> "$tmp/gh/projet.merged"
commit "$p" v2
# PR ouverte.
git -C "$p" switch -qc en-cours main; commit "$p" encours; git -C "$p" push -q -u origin en-cours
printf '7\ten-cours\tAjoute la fonction X\n' > "$tmp/gh/projet.open"
# main local en retard : quelqu'un pousse sur origin/main, et main local est revenu en arrière.
git -C "$p" switch -q fusionnee-pr
git -C "$p" branch -f main HEAD~1  # main local = init ; origin/main a le merge
avant_main="$(git -C "$p" rev-parse refs/remotes/origin/main)"

# --- Dépôt « sale » : branche courante fusionnée mais modifiée ---
s="$racine/projects/sale"; nouveau "$s"
git -C "$s" switch -qc finie; commit "$s" fini; git -C "$s" push -q -u origin finie
echo "finie $(git -C "$s" rev-parse HEAD)" > "$tmp/gh/sale.merged"; : > "$tmp/gh/sale.open"
echo modif >> "$s/f"

# --- Dépôt caché : ignoré ---
c="$racine/.cache/cache"; nouveau "$c"
git -C "$c" switch -qc finie; commit "$c" fini; git -C "$c" push -q -u origin finie
echo "finie $(git -C "$c" rev-parse HEAD)" > "$tmp/gh/cache.merged"; : > "$tmp/gh/cache.open"

# === --dry-run : rien ne bouge ===
MENAGE_NOTIFIER=notifier bash "$script" --dry-run "$racine" > "$tmp/sortie-dry" 2>&1
verif "dry-run : branche courante inchangée"    '[ "$(courante "$p")" = fusionnee-pr ]'
verif "dry-run : branche fusionnée conservée"   'a_branche "$p" fusionnee-pr && a_distante "$p" fusionnee-pr'
verif "dry-run : annonce la suppression"        'grep -q "branche distante fusionnée supprimée : origin/fusionnee-pr" "$tmp/sortie-dry"'
verif "dry-run : pas de notification"           '[ ! -e "$tmp/notification" ]'

# === Passage réel ===
MENAGE_NOTIFIER=notifier bash "$script" "$racine" > "$tmp/sortie" 2>&1 || { cat "$tmp/sortie"; ko "code de sortie"; }
verif "retour sur main"                          '[ "$(courante "$p")" = main ]'
verif "main avancé en fast-forward"              '[ "$(git -C "$p" rev-parse main)" = "$avant_main" ]'
verif "branche PR fusionnée supprimée (locale)"  '! a_branche "$p" fusionnee-pr'
verif "branche PR fusionnée supprimée (origin)"  '! a_distante "$p" fusionnee-pr'
verif "branche à amont disparu supprimée"        '! a_branche "$p" amont-disparu'
verif "branche neuve conservée"                  'a_branche "$p" neuve'
verif "branche modifiée après PR conservée"      'a_branche "$p" pr-modifiee'
verif "branche à PR ouverte conservée"           'a_branche "$p" en-cours && a_distante "$p" en-cours'
verif "dépôt sale : reste sur sa branche"        '[ "$(courante "$s")" = finie ] && a_branche "$s" finie'
verif "dépôt sale : modification intacte"        'grep -q modif "$s/f"'
verif "dépôt sale : signalé"                     'grep -q "sale : finie est fusionnée mais a des modifications" "$tmp/sortie"'
verif "dossier caché ignoré"                     '[ "$(courante "$c")" = finie ] && ! grep -q "cache" "$tmp/sortie"'
verif "notification envoyée"                     'grep -q "TITRE: 1 PR en attente" "$tmp/notification"'
verif "notification : PR listée"                 'grep -q "projects/projet #7 Ajoute la fonction X" "$tmp/notification"'

# === Sans PR ouverte : pas de notification ===
rm -f "$tmp/notification" "$tmp/gh/projet.open"; : > "$tmp/gh/projet.open"
MENAGE_NOTIFIER=notifier bash "$script" "$racine" > "$tmp/sortie2" 2>&1
verif "aucune PR : pas de notification"          '[ ! -e "$tmp/notification" ]'

# === Sans GitHub (gh en échec) : seule la règle « amont disparu » s'applique ===
g="$racine/projects/sansgh"; nouveau "$g"
git -C "$g" switch -qc finie; commit "$g" fini; git -C "$g" push -q -u origin finie
git -C "$g" switch -qc neuve2 main
bash "$script" "$racine" > "$tmp/sortie3" 2>&1
verif "sans gh : rien supprimé sans preuve"      'a_branche "$g" finie && a_distante "$g" finie && a_branche "$g" neuve2'

# === fetch impossible : rien supprimé, signalé ===
git -C "$g" remote set-url origin "$tmp/absent.git"
git -C "$g" branch --set-upstream-to=main neuve2 2>/dev/null || true
bash "$script" "$racine" > "$tmp/sortie4" 2>&1
verif "fetch impossible : signalé"               'grep -q "sansgh : git fetch impossible" "$tmp/sortie4"'

if [ "$echecs" -gt 0 ]; then
  echo "--- sortie du passage réel ---"; cat "$tmp/sortie"
  echo "$echecs test(s) en échec"; exit 1
fi
echo "Tous les tests passent."
