#!/usr/bin/env bash
# Vérification indépendante de scripts/menage-git.sh (spécification : message du commit 1fb4650).
# Dépôts jetables (remotes nus locaux), faux gh, faux notificateur, aucun accès réseau.
# Usage : tests/verif/menage-git-verif.sh
# Les cas marqués « xfail » montrent un écart mineur ou hors spécification connu : leur échec est
# attendu et ne fait pas échouer le script ; s'ils se mettent à passer, c'est signalé (XPASS).
# shellcheck disable=SC2016,SC2034
set -euo pipefail

script="${MENAGE_SCRIPT:-$(cd "$(dirname "$0")/../.." && pwd)/scripts/menage-git.sh}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$tmp/bin" "$tmp/gh"
git config --global user.name Test
git config --global user.email test@example.org
git config --global init.defaultBranch main
git config --global advice.detachedHead false

# Faux gh : $tmp/gh/<dépôt>.merged|.open ; « <dépôt>.open-ko » fait échouer seulement la liste ouverte.
cat > "$tmp/bin/gh" <<EOF
#!$(command -v bash)
nom="\$(basename "\$PWD")"
case "\$*" in
  *"--state merged"*) f="$tmp/gh/\$nom.merged" ;;
  *"--state open"*)   [ -e "$tmp/gh/\$nom.open-ko" ] && exit 1; f="$tmp/gh/\$nom.open" ;;
esac
[ -f "\$f" ] || exit 1
cat "\$f"
EOF
cat > "$tmp/bin/notifier" <<EOF
#!$(command -v bash)
{ echo "TITRE: \$1"; cat; } > "$tmp/notification"
EOF
cat > "$tmp/bin/notifier-ko" <<EOF
#!$(command -v bash)
cat >/dev/null; exit 7
EOF
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"

echecs=0 xfails=0 xpass=0
verif() { if eval "$2"; then echo "ok    $1"; else echo "ÉCHEC $1"; echecs=$((echecs + 1)); fi; }
xfail() { # $1 = nom, $2 = raison, $3 = condition attendue par la spécification
  if eval "$3"; then echo "XPASS $1"; xpass=$((xpass + 1));
  else echo "xfail $1 ($2)"; xfails=$((xfails + 1)); fi
}
a_branche()  { git -C "$1" rev-parse --verify --quiet "refs/heads/$2" >/dev/null; }
a_distante() { git -C "$tmp/remotes/$(basename "$1").git" rev-parse --verify --quiet "refs/heads/$2" >/dev/null; }
courante()   { git -C "$1" symbolic-ref --short HEAD; }
commit()     { echo "$2" >> "$1/f"; git -C "$1" add f; git -C "$1" commit -qm "$2"; }
tete()       { git -C "$1" rev-parse "refs/heads/$2"; }
nouveau() {
  local d="$1" r
  r="$tmp/remotes/$(basename "$d").git"
  git init -q --bare "$r"
  git clone -q "$r" "$d" 2>/dev/null
  commit "$d" init
  git -C "$d" push -q -u origin main
  git -C "$d" remote set-head origin main
  : > "$tmp/gh/$(basename "$d").open"; : > "$tmp/gh/$(basename "$d").merged"
}
pr_fusionnee() { echo "$2 $(tete "$1" "$2")" >> "$tmp/gh/$(basename "$1").merged"; }
lancer() { # $1 = fichier de sortie ; reste = arguments ; code de sortie dans $tmp/code
  local out="$1"; shift
  set +e; MENAGE_NOTIFIER="${NOTIF:-notifier}" bash "$script" "$@" > "$out" 2>&1; echo $? > "$tmp/code"; set -e
}
P="$HOME/projects"

# ---------------------------------------------------------------------------------------------
# 1. Fetch impossible : aucune suppression, aucun retour sur main (exigence du commit).
f="$P/fetchko"; nouveau "$f"
git -C "$f" switch -qc claude/finie; commit "$f" fini; git -C "$f" push -q -u origin claude/finie
pr_fusionnee "$f" claude/finie
git -C "$f" switch -qc claude/autre main; commit "$f" autre; git -C "$f" push -q -u origin claude/autre
pr_fusionnee "$f" claude/autre
git -C "$f" switch -q claude/finie
git -C "$f" remote set-url origin "$tmp/absent.git"
lancer "$tmp/s1" "$P"
verif "fetch KO : branche courante fusionnée gardée et non quittée" '[ "$(courante "$f")" = claude/finie ] && a_branche "$f" claude/finie'
verif "fetch KO : autre branche fusionnée gardée"                  'a_branche "$f" claude/autre'
verif "fetch KO : branches distantes intactes"                      'a_distante "$f" claude/finie && a_distante "$f" claude/autre'
verif "fetch KO : signalé"                                          'grep -q "fetchko : git fetch impossible, rien supprimé" "$tmp/s1"'
verif "code de sortie 0"                                            '[ "$(cat "$tmp/code")" = 0 ]'
rm -rf "$f"

# ---------------------------------------------------------------------------------------------
# 2. Branches claude/* (avec « / ») : cas d'usage principal du commit.
c="$P/claude"; nouveau "$c"
git -C "$c" switch -qc claude/lot-a; commit "$c" a; git -C "$c" push -q -u origin claude/lot-a
pr_fusionnee "$c" claude/lot-a
# Branche neuve sans PR, poussée, avec un commit propre : jamais touchée.
git -C "$c" switch -qc claude/lot-b main; commit "$c" b; git -C "$c" push -q -u origin claude/lot-b
# Branche neuve sans PR ni amont, contenue dans main.
git -C "$c" branch claude/neuve main
# Branche avec PR fusionnée ET PR ouverte de même tête : gardée.
git -C "$c" switch -qc claude/rouverte main; commit "$c" r; git -C "$c" push -q -u origin claude/rouverte
pr_fusionnee "$c" claude/rouverte
printf '12\tclaude/rouverte\tReprise $(touch %s/injecte) `id`\n' "$tmp" > "$tmp/gh/claude.open"
# Distante seulement (pas de branche locale), PR fusionnée, mais quelqu'un a poussé après la fusion.
git -C "$c" switch -qc claude/repoussee main; commit "$c" rp1; git -C "$c" push -q -u origin claude/repoussee
pr_fusionnee "$c" claude/repoussee
commit "$c" rp2; git -C "$c" push -q origin claude/repoussee
git -C "$c" switch -q main; git -C "$c" branch -qD claude/repoussee
# Distante seulement, PR fusionnée, même tête : supprimée.
git -C "$c" switch -qc claude/distante main; commit "$c" d; git -C "$c" push -q -u origin claude/distante
pr_fusionnee "$c" claude/distante
git -C "$c" switch -q main; git -C "$c" branch -qD claude/distante
git -C "$c" switch -q claude/lot-a
# Fichier non suivi : ne bloque pas le retour, et reste intact.
echo brouillon > "$c/notes.txt"
lancer "$tmp/s2" "$P"
verif "claude/* : retour sur main"                        '[ "$(courante "$c")" = main ]'
verif "claude/* : fichier non suivi conservé"             '[ "$(cat "$c/notes.txt")" = brouillon ]'
verif "claude/* : branche fusionnée supprimée (locale)"   '! a_branche "$c" claude/lot-a'
verif "claude/* : branche fusionnée supprimée (origin)"   '! a_distante "$c" claude/lot-a'
verif "branche sans PR poussée : intacte (locale+origin)" 'a_branche "$c" claude/lot-b && a_distante "$c" claude/lot-b'
verif "branche neuve sans amont : intacte"                'a_branche "$c" claude/neuve'
verif "PR fusionnée + PR ouverte : gardée"                'a_branche "$c" claude/rouverte && a_distante "$c" claude/rouverte'
verif "distante poussée après fusion : gardée"            'a_distante "$c" claude/repoussee'
verif "distante fusionnée même tête : supprimée"          '! a_distante "$c" claude/distante'
verif "titre de PR non interprété (pas d injection)"      '[ ! -e "$tmp/injecte" ] && grep -qF "Reprise \$(touch" "$tmp/notification"'
verif "titre de notification"                             'grep -q "^TITRE: 1 PR en attente$" "$tmp/notification"'
rm -rf "$c" "$tmp/notification"

# ---------------------------------------------------------------------------------------------
# 3. Sans GitHub : la règle « amont disparu et contenue dans main » s'applique seule.
g="$P/sansgh"; nouveau "$g"; rm -f "$tmp/gh/sansgh.merged" "$tmp/gh/sansgh.open"
git -C "$g" switch -qc fusion; commit "$g" x; git -C "$g" push -q -u origin fusion
git -C "$g" switch -q main; git -C "$g" merge -q --no-ff -m m fusion; git -C "$g" push -q origin main
git -C "$g" push -q origin --delete fusion
# Amont disparu mais commits absents de main : gardée.
git -C "$g" switch -qc abandon main; commit "$g" y; git -C "$g" push -q -u origin abandon
git -C "$g" push -q origin --delete abandon
git -C "$g" switch -q main
lancer "$tmp/s3" "$P"
verif "sans gh : amont disparu + contenue dans main → supprimée" '! a_branche "$g" fusion'
verif "sans gh : amont disparu + commits propres → gardée"       'a_branche "$g" abandon'
rm -rf "$g"

# ---------------------------------------------------------------------------------------------
# 4. gh à moitié en panne (liste ouverte en échec) : aucune suppression par la règle PR.
h="$P/demi"; nouveau "$h"
git -C "$h" switch -qc ouverte; commit "$h" o; git -C "$h" push -q -u origin ouverte
pr_fusionnee "$h" ouverte; touch "$tmp/gh/demi.open-ko"
git -C "$h" switch -q main
lancer "$tmp/s4" "$P"
verif "gh partiel : rien supprimé"                         'a_branche "$h" ouverte && a_distante "$h" ouverte'
rm -rf "$h"

# ---------------------------------------------------------------------------------------------
# 5. Worktrees : branche fusionnée extraite ailleurs gardée ; main occupée → on reste.
w="$P/arbres"; nouveau "$w"
git -C "$w" switch -qc wt-fini; commit "$w" w; git -C "$w" push -q -u origin wt-fini
pr_fusionnee "$w" wt-fini
git -C "$w" switch -qc courant-fini main; commit "$w" cf; git -C "$w" push -q -u origin courant-fini
pr_fusionnee "$w" courant-fini
git -C "$w" worktree add -q "$P/.arbres-wt" wt-fini
git -C "$w" worktree add -q "$tmp/wt-main" main 2>/dev/null
lancer "$tmp/s5" "$P"
verif "worktree : branche extraite gardée"                'a_branche "$w" wt-fini && [ "$(courante "$P/.arbres-wt")" = wt-fini ]'
verif "worktree : main occupée → reste sur sa branche"    '[ "$(courante "$w")" = courant-fini ] && a_branche "$w" courant-fini'
verif "worktree : signalé"                                'grep -q "main extraite dans un autre worktree" "$tmp/s5"'
git -C "$w" worktree remove --force "$P/.arbres-wt"; git -C "$w" worktree remove --force "$tmp/wt-main"
rm -rf "$w"

# ---------------------------------------------------------------------------------------------
# 6. main locale divergente : pas de perte de commit local.
v="$P/diverge"; nouveau "$v"
commit "$v" local-seul
git -C "$v" clone -q "$tmp/remotes/diverge.git" "$tmp/autre" 2>/dev/null
commit "$tmp/autre" distant; git -C "$tmp/autre" push -q origin main
local_sha="$(tete "$v" main)"
lancer "$tmp/s6" "$P"
verif "main divergente : commit local conservé"           '[ "$(tete "$v" main)" = "$local_sha" ]'
verif "main divergente : signalé"                         'grep -q "diverge : main ne peut pas avancer" "$tmp/s6"'
rm -rf "$v" "$tmp/autre"

# ---------------------------------------------------------------------------------------------
# 7. Robustesse : dépôt sans origin, HEAD détachée, notificateur en panne.
n="$P/aaa-local"; mkdir -p "$n"; git -C "$n" init -q; commit "$n" i
d="$P/detache"; nouveau "$d"
git -C "$d" switch -qc det-fini; commit "$d" df; git -C "$d" push -q -u origin det-fini
pr_fusionnee "$d" det-fini
git -C "$d" switch -q --detach main
printf '3\tx\tPR\n' > "$tmp/gh/detache.open"
NOTIF=notifier-ko lancer "$tmp/s7" "$P"
verif "dépôt sans origin : n'arrête pas le parcours"      '! a_branche "$d" det-fini'
verif "HEAD détachée : branche fusionnée supprimée"       '! a_distante "$d" det-fini'
verif "notificateur en panne : code 0 et message"         '[ "$(cat "$tmp/code")" = 0 ] && grep -q "Notification impossible" "$tmp/s7"'
xfail "dépôt sans origin : pas présenté comme « fetch impossible »" \
  "hors spécification : un dépôt purement local est signalé chaque jour comme une erreur de fetch" \
  '! grep -q "aaa-local : git fetch impossible" "$tmp/s7"'
rm -rf "$n" "$d"

# ---------------------------------------------------------------------------------------------
# 8. --dry-run : aucune référence locale ni distante modifiée.
y="$P/sec"; nouveau "$y"
git -C "$y" switch -qc sec-fini; commit "$y" s; git -C "$y" push -q -u origin sec-fini
pr_fusionnee "$y" sec-fini
avant_l="$(git -C "$y" for-each-ref refs/heads)"; avant_r="$(git -C "$tmp/remotes/sec.git" for-each-ref)"
lancer "$tmp/s8" --dry-run "$P"
verif "dry-run : refs locales et distantes inchangées"    '[ "$(git -C "$y" for-each-ref refs/heads)" = "$avant_l" ] && [ "$(git -C "$tmp/remotes/sec.git" for-each-ref)" = "$avant_r" ] && [ "$(courante "$y")" = sec-fini ]'

# ---------------------------------------------------------------------------------------------
# 9. Racine relative ou « . » (usage manuel documenté : menage-git [--dry-run] [racine]).
z="$P/zzz"; nouveau "$z"
git -C "$z" switch -qc z-fini; commit "$z" z; git -C "$z" push -q -u origin z-fini
pr_fusionnee "$z" z-fini
(cd "$HOME" && set +e; bash "$script" --dry-run projects > "$tmp/s9" 2>&1)
xfail "racine relative : tous les dépôts traités" \
  "mineur : après le premier dépôt, cd vers un chemin relatif échoue et les dépôts suivants sont ignorés (erreur cd sur stderr seulement, « Rien en attente »)" \
  'grep -q "z-fini" "$tmp/s9"'
(cd "$P" && set +e; bash "$script" --dry-run . > "$tmp/s10" 2>&1)
xfail "racine « . » : dépôts trouvés" \
  "mineur : find élague « . » comme dossier caché, aucun dépôt n'est traité" \
  'grep -q "== " "$tmp/s10"'

echo
echo "$echecs échec(s), $xfails xfail, $xpass xpass"
[ "$echecs" -eq 0 ]
