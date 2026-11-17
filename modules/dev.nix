# Poste de travail distant pour Claude Code et les side projects.
{ config, lib, pkgs, settings, nixpkgs-unstable, ... }:
let
  user = settings.userName;
  # Le sujet ntfy est déclaré par backup.nix (sops) : pas de notification sans lui.
  ntfy = settings.backup.enable;

  # Claude Code est un binaire compilé avec Bun : il exige au moins SSE4.2/POPCNT, et en
  # pratique AVX. Un processeur sans eux (ex. l'Atom N2800, ancienne machine) donne
  # « Illegal instruction ». Donc seulement si lowSpecHardware = false (NixKS : AVX2).
  claudeCode = !settings.lowSpecHardware;
  # Claude Code vient de nixos-unstable (voir flake.nix) : seul paquet pris hors de la branche stable.
  # Mise à jour : nix flake update nixpkgs-unstable, puis rebuild-check.
  claudeCodePkg = (import nixpkgs-unstable {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfreePredicate = pkg: lib.getName pkg == "claude-code";
  }).claude-code;

  # Session tmux par projet : « t veilleur » crée ou rejoint la session, dans ~/projects/veilleur.
  # Même session depuis le poste et le téléphone (mosh/Termius) : le travail continue où il en était.
  t = pkgs.writeShellApplication {
    name = "t";
    runtimeInputs = [ pkgs.tmux ];
    text = ''
      if [ $# -eq 0 ]; then
        tmux list-sessions 2>/dev/null || echo "Aucune session. Usage : t <projet>"
        exit 0
      fi
      dir="$HOME/projects/$1"
      [ -d "$dir" ] || dir="$HOME/$1"
      [ -d "$dir" ] || dir="$HOME"
      exec tmux new-session -A -s "$1" -c "$dir"
    '';
  };

  # Environnement de test isolé par branche : une copie de travail Git à part, un projet
  # docker compose à part (réseau, volumes et conteneurs propres) et un port à part.
  # Joignable par Tailscale seulement (le pare-feu ne fait confiance qu'à tailscale0).
  bac = pkgs.writeShellApplication {
    name = "bac";
    runtimeInputs = with pkgs; [ git docker-compose iproute2 coreutils gnused gnugrep ];
    text = ''
      racine="$HOME/projects/.bacs"
      etat="$racine/.etat"
      usage() {
        cat <<'AIDE'
      Usage (depuis le dépôt Git d'un projet) :
        bac up [branche]   crée ou met à jour le bac de la branche (défaut : branche courante)
        bac rm [branche]   arrête les conteneurs, supprime volumes et copie de travail
        bac ls             liste les bacs et leur port
      Le fichier compose du projet publie son port avec ''${BAC_PORT} ;
      BAC_NOM contient le nom du bac.
      AIDE
      }
      nom_du_bac() { # $1 = branche
        commun="$(git rev-parse --path-format=absolute --git-common-dir)"
        projet="$(basename "$(dirname "$commun")")"
        printf '%s-%s' "$projet" "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//'
      }
      fichier_compose() { # $1 = dossier
        for f in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
          if [ -f "$1/$f" ]; then echo "$1/$f"; return 0; fi
        done
        return 1
      }
      port_libre() {
        for p in $(seq 8100 8199); do
          if grep -qsx "$p" "$etat"/*.port; then continue; fi
          if ss -Hltn "sport = :$p" | grep -q .; then continue; fi
          echo "$p"; return 0
        done
        echo "Aucun port libre entre 8100 et 8199." >&2
        return 1
      }

      cmd="''${1:-}"
      case "$cmd" in
        ls)
          mkdir -p "$etat"
          for f in "$etat"/*.port; do
            [ -e "$f" ] || { echo "Aucun bac."; break; }
            printf '%s\thttp://%s:%s\n' "$(basename "$f" .port)" "$(hostname | tr '[:upper:]' '[:lower:]')" "$(cat "$f")"
          done
          ;;
        up|rm)
          git rev-parse --git-dir >/dev/null
          branche="''${2:-$(git branch --show-current)}"
          [ -n "$branche" ] || { echo "Pas de branche courante : donner la branche." >&2; exit 1; }
          nom="$(nom_du_bac "$branche")"
          dir="$racine/$nom"
          mkdir -p "$etat"
          if [ "$cmd" = up ]; then
            # Copie détachée : fonctionne même si la branche est déjà extraite ailleurs, et ne
            # contient que ce qui est commité.
            if [ -d "$dir" ]; then
              git -C "$dir" checkout --quiet --detach "$branche"
            else
              git worktree add --quiet --detach "$dir" "$branche"
            fi
            [ -f "$etat/$nom.port" ] || port_libre > "$etat/$nom.port"
            port="$(cat "$etat/$nom.port")"
            if compose="$(fichier_compose "$dir")"; then
              BAC_PORT="$port" BAC_NOM="$nom" docker-compose -p "$nom" -f "$compose" up -d --build
              echo "Bac $nom : http://$(hostname | tr '[:upper:]' '[:lower:]'):$port (Tailscale)"
            else
              echo "Bac $nom : copie de travail dans $dir (pas de fichier compose, port réservé : $port)"
            fi
          else
            if [ -d "$dir" ]; then
              if compose="$(fichier_compose "$dir")"; then
                BAC_PORT=0 BAC_NOM="$nom" docker-compose -p "$nom" -f "$compose" down --volumes --remove-orphans
              fi
              git worktree remove --force "$dir"
            fi
            rm -f "$etat/$nom.port"
            echo "Bac $nom supprimé."
          fi
          ;;
        *) usage ;;
      esac
    '';
  };

  # Notification sur le téléphone quand Claude Code attend une réponse ou une permission
  # (crochet « Notification » de ~/claude-config/settings.json). Seul le nom du dossier part
  # chez ntfy.sh : ni code, ni contenu de la demande. Priorité haute : une demande en
  # attente doit réveiller un téléphone en veille. Piège constaté le 16/11/2026 : le Cyberfiltre d'Orange
  # détourne ntfy.sh sur le réseau mobile (certificat cyberfiltre-alerte.orange.fr) ; l'application ne
  # reçoit alors que par Firebase et ne rattrape pas les messages manqués. Contournement : DNS privé
  # (dns.quad9.net) sur le téléphone.
  claudeNotify = pkgs.writeShellApplication {
    name = "claude-notify";
    runtimeInputs = [ pkgs.curl pkgs.jq pkgs.coreutils ];
    text = ''
      dossier="$(jq -r '.cwd // empty' 2>/dev/null || true)"
      topic="$(cat ${config.sops.secrets.ntfy_topic_claude.path})"
      curl -fsS --max-time 10 -H "Title: [${settings.hostName}] Claude attend" -H "Tags: robot" -H "Priority: high" \
        -d "Projet : $(basename "''${dossier:-inconnu}")" "https://ntfy.sh/$topic" >/dev/null
    '';
  };
in
{
  # Paquet nixpkgs plutôt que l'installeur natif : déclaratif, version figée par
  # flake.lock (mise à jour automatique désactivée par le paquet), patché pour NixOS.
  # Non libre : on n'autorise que lui.
  nixpkgs.config.allowUnfreePredicate = pkg: lib.getName pkg == "claude-code";

  # Indispensable : permet de lancer les binaires précompilés (outils téléchargés
  # par npm/pip, extensions VS Code Server…).
  programs.nix-ld.enable = true;

  # Docker SANS privilèges root : l'utilisateur n'est pas dans le groupe "docker"
  # (qui équivaut à root). Claude Code peut lancer des conteneurs sans pouvoir
  # prendre la main sur le système.
  virtualisation.docker.rootless = {
    enable = true;
    setSocketVariable = true;
  };

  # Environnements de dev par projet : un flake.nix + .envrc ("use flake")
  # dans chaque projet, chargé automatiquement en entrant dans le dossier.
  programs.direnv.enable = true;

  environment.systemPackages = with pkgs; [
    nodejs
    python3
    uv
    gcc
    gnumake
    gh
    docker-compose
    just        # commandes de projet (just test, just env-up…) : les mêmes pour l'humain, Claude et la CI
    shellcheck
    # Bac à sable de Claude Code (/sandbox) : isole les commandes au niveau du système,
    # ce que les règles de permission seules ne font pas.
    bubblewrap
    socat
    t
    bac
  ] ++ lib.optional claudeCode claudeCodePkg
    ++ lib.optional ntfy claudeNotify;

  # Même sujet ntfy que les alertes de sauvegarde, lisible par l'utilisateur (l'autre copie
  # reste réservée à root).
  sops.secrets = lib.mkIf ntfy {
    ntfy_topic_claude = { key = "ntfy_topic"; owner = user; };
  };

  # Les sessions de l'utilisateur (Claude Code, tests, conteneurs rootless, VM de test)
  # passent après les services du serveur : moitié moins de poids CPU en cas de concurrence,
  # ralentissement au-delà de 20 Go, plafond dur à 24 Go sur 32.
  systemd.slices."user-1000" = lib.mkIf (!settings.lowSpecHardware) {
    overrideStrategy = "asDropin";
    sliceConfig = {
      CPUWeight = 50;
      MemoryHigh = "20G";
      MemoryMax = "24G";
    };
  };

  programs.tmux = {
    enable = true;
    historyLimit = 50000;
    escapeTime = 10;
    terminal = "tmux-256color";
    extraConfig = ''
      set -g mouse on            # défilement au doigt dans Termius
      set -g focus-events on
      set -g set-clipboard on
      setw -g aggressive-resize on  # poste et téléphone attachés à la même session
    '';
  };

  # Garde les services utilisateur (docker rootless, sessions tmux…) actifs
  # même quand aucune session SSH n'est ouverte.
  users.users.${user} = {
    linger = true;
    uid = 1000; # fixe : la tranche user-1000 ci-dessus est nommée d'après lui
  };
}
