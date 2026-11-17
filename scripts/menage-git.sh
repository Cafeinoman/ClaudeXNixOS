#!/usr/bin/env bash
# Ménage quotidien des dépôts Git de l'utilisateur (timer de modules/menage-git.nix).
#
# Pour chaque dépôt trouvé sous la racine (dossiers cachés et worktrees ignorés) :
#   1. git fetch --prune ;
#   2. supprime les branches locales fusionnées ;
#   3. supprime sur origin les branches dont la PR est fusionnée ;
#   4. revient sur la branche par défaut si la branche courante est fusionnée et l'arbre propre,
#      puis avance la branche par défaut en fast-forward ;
#   5. relève les PR ouvertes ; s'il y en a, une notification résume la liste.
#
# « Fusionnée » est prouvé, jamais deviné : une PR fusionnée dont le commit de tête est exactement
# celui de la branche, ou (sans GitHub) une branche dont l'amont a disparu et qui est contenue dans
# la branche par défaut. Une branche neuve sans PR n'est jamais supprimée.
#
# Usage : menage-git [--dry-run] [racine]   (racine par défaut : $HOME)
# Notification : commande $MENAGE_NOTIFIER, appelée avec le titre en argument et le corps sur
# l'entrée standard. Sans elle, le résumé n'est qu'affiché.
set -uo pipefail

dry=0
if [ "${1:-}" = "--dry-run" ]; then dry=1; shift; fi
racine="${1:-$HOME}"

export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=15}"

prs=()     # lignes « dépôt #n titre »
erreurs=() # lignes « dépôt : problème »

agir() { # exécute la commande, ou l'affiche seulement en --dry-run
  if [ "$dry" -eq 1 ]; then echo "  [dry-run] $*"; return 0; fi
  "$@"
}

traiter() {
  local depot="$1" nom
  nom="${depot#"$racine"/}"
  echo "== $nom"
  cd "$depot" || return

  local fetch_ok=1
  if ! git fetch --prune --quiet origin 2>/dev/null; then
    fetch_ok=0
    erreurs+=("$nom : git fetch impossible, rien supprimé")
  fi

  local defaut
  defaut="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"
  defaut="${defaut#origin/}"
  [ -n "$defaut" ] || defaut=main
  if ! git rev-parse --verify --quiet "refs/remotes/origin/$defaut" >/dev/null; then
    echo "  pas de origin/$defaut : ignoré"
    return
  fi

  # PR fusionnées (branche + commit de tête) et PR ouvertes, par gh. Échec = pas de GitHub.
  local fusionnees="" ouvertes="" gh_ok=1
  if fusionnees="$(gh pr list --state merged --limit 200 --json headRefName,headRefOid \
                     --jq '.[] | "\(.headRefName) \(.headRefOid)"' 2>/dev/null)" &&
     ouvertes="$(gh pr list --state open --limit 100 --json number,title,headRefName \
                   --jq '.[] | "\(.number)\t\(.headRefName)\t\(.title)"' 2>/dev/null)"; then
    :
  else
    gh_ok=0; fusionnees=""; ouvertes=""
  fi
  local num titre
  while IFS=$'\t' read -r num _ titre; do
    [ -n "$num" ] && prs+=("$nom #$num $titre")
  done <<< "$ouvertes"

  [ "$fetch_ok" -eq 1 ] || return

  pr_fusionnee() { # $1 = branche, $2 = commit : une PR fusionnée a-t-elle cette tête exacte ?
    grep -qxF "$1 $2" <<< "$fusionnees"
  }
  pr_ouverte() { # $1 = branche : une PR ouverte en part-elle encore ?
    cut -f2 <<< "$ouvertes" | grep -qxF "$1"
  }
  fusionnee() { # $1 = branche locale
    local b="$1" sha amont
    sha="$(git rev-parse "refs/heads/$b")"
    pr_ouverte "$b" && return 1
    pr_fusionnee "$b" "$sha" && return 0
    amont="$(git for-each-ref --format='%(upstream:track)' "refs/heads/$b")"
    [ "$amont" = "[gone]" ] && git merge-base --is-ancestor "$sha" "refs/remotes/origin/$defaut"
  }

  local courante
  courante="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  # Branches extraites dans un autre worktree : intouchables.
  local occupees quittee=""
  occupees="$(git worktree list --porcelain | sed -n 's|^branch refs/heads/||p')"

  # 4. Retour sur la branche par défaut (avant la suppression, pour libérer la branche courante).
  if [ -n "$courante" ] && [ "$courante" != "$defaut" ] && fusionnee "$courante"; then
    if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
      erreurs+=("$nom : $courante est fusionnée mais a des modifications, laissée telle quelle")
    elif grep -qxF "$defaut" <<< "$occupees"; then
      erreurs+=("$nom : $defaut extraite dans un autre worktree, reste sur $courante")
    else
      echo "  $courante fusionnée : retour sur $defaut"
      agir git switch --quiet "$defaut" && quittee="$courante" && courante="$defaut"
    fi
  fi
  if [ "$courante" = "$defaut" ] && [ -z "$(git status --porcelain --untracked-files=no)" ] &&
     [ "$(git symbolic-ref --quiet --short HEAD)" = "$defaut" ]; then
    if ! git merge-base --is-ancestor "refs/remotes/origin/$defaut" HEAD; then
      echo "  $defaut avance sur origin/$defaut"
      agir git merge --ff-only --quiet "refs/remotes/origin/$defaut" ||
        erreurs+=("$nom : $defaut ne peut pas avancer en fast-forward")
    fi
  fi

  # 2. Branches locales fusionnées.
  local b
  while read -r b; do
    [ "$b" = "$defaut" ] && continue
    [ "$b" = "$courante" ] && continue
    # Extraite dans un worktree (sauf celle qu'on vient de quitter ici).
    [ "$b" != "$quittee" ] && grep -qxF "$b" <<< "$occupees" && continue
    if fusionnee "$b"; then
      echo "  branche locale fusionnée supprimée : $b"
      agir git branch --quiet -D "$b"
    fi
  done < <(git for-each-ref --format='%(refname:short)' refs/heads)

  # 3. Branches distantes dont la PR est fusionnée (même tête), sans PR ouverte.
  [ "$gh_ok" -eq 1 ] || return
  local sha
  while read -r b; do
    b="${b#origin/}"
    [ "$b" = "$defaut" ] || [ "$b" = "HEAD" ] || [ "$b" = "origin" ] && continue
    sha="$(git rev-parse "refs/remotes/origin/$b")"
    if pr_fusionnee "$b" "$sha" && ! pr_ouverte "$b"; then
      echo "  branche distante fusionnée supprimée : origin/$b"
      agir git push --quiet origin --delete "$b" ||
        erreurs+=("$nom : suppression de origin/$b impossible")
    fi
  done < <(git for-each-ref --format='%(refname:short)' refs/remotes/origin)
}

# Dépôts : dossiers .git (pas les fichiers .git des worktrees), hors dossiers cachés.
while IFS= read -r g; do
  traiter "$(dirname "$g")"
done < <(find "$racine" -maxdepth 4 \( -name '.*' ! -name .git -prune \) -o \( -type d -name .git -print -prune \) 2>/dev/null | sort)

echo
corps=""
if [ "${#prs[@]}" -gt 0 ]; then
  corps+="PR ouvertes (${#prs[@]}) :"$'\n'"$(printf -- '- %s\n' "${prs[@]}")"$'\n'
fi
if [ "${#erreurs[@]}" -gt 0 ]; then
  corps+="À regarder :"$'\n'"$(printf -- '- %s\n' "${erreurs[@]}")"$'\n'
fi
if [ -z "$corps" ]; then
  echo "Rien en attente."
  exit 0
fi
printf '%s' "$corps"
if [ "${#prs[@]}" -gt 0 ] && [ -n "${MENAGE_NOTIFIER:-}" ] && [ "$dry" -eq 0 ]; then
  printf '%s' "$corps" | "$MENAGE_NOTIFIER" "${#prs[@]} PR en attente" ||
    echo "Notification impossible" >&2
fi
exit 0
