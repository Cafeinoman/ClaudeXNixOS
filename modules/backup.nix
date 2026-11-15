# Sauvegardes de l'état des applications et du dossier personnel.
#
#  1. B2 (principal, chaque nuit) : restic vers Backblaze B2, chiffré côté serveur avant
#     envoi, avec historique (7 jours, 4 semaines, 3 mois). Gratuit tant que le dépôt
#     reste sous 10 Go ; les plafonds à 0 $ côté B2 transforment tout dépassement en
#     refus, jamais en facture (README, « Sauvegardes »).
#  2. Alertes : notification ntfy sur le téléphone si une sauvegarde échoue, et chien de
#     garde quotidien si la dernière sauvegarde B2 est trop ancienne.
#
# Copie Proton Drive (archive age à la demande) retirée le 15/11/2026 : voir l'historique Git.
#
# Secrets (sops-nix, chiffrés dans Git) : secrets/<machine>.yaml — voir secrets/README.md.
{ config, lib, pkgs, settings, ... }:
let
  cfg = settings.backup;
  host = settings.hostName;
  user = settings.userName;
  home = "/home/${user}";
  stampDir = "/var/lib/backup-stamps";

  # Services arrêtés pendant la copie : leurs bases SQLite doivent être au repos.
  appServices = [
    "sonarr" "radarr" "prowlarr" "qbittorrent" "bazarr" "lidarr"
    "jellyfin" "seerr" "navidrome" "audiobookshelf"
    "container@locanalyse" # le conteneur entier : base SQLite de Locanalyse et base d'utilisateurs de ntfy
  ];
  appDirs = [
    "/var/lib/sonarr" "/var/lib/radarr" "/var/lib/private/prowlarr" "/var/lib/qBittorrent"
    "/var/lib/bazarr" "/var/lib/lidarr" "/var/lib/jellyfin" "/var/lib/private/seerr"
    "/var/lib/navidrome" "/var/lib/audiobookshelf" "/var/lib/secrets"
    # Locanalyse : clé de signature et secrets des jumelages (les perdre = rejumeler tous les membres),
    # base, paquets du flux ; utilisateurs et jetons ntfy. Le cache des API est exclu par « **/cache ».
    "/var/lib/nixos-containers/locanalyse/var/lib/locanalyse"
    "/var/lib/nixos-containers/locanalyse/var/lib/private/ntfy-sh"
  ];
  excludes = [
    # Caches et fichiers régénérables
    "**/MediaCover" "**/cache" "**/.cache" "**/logs" "**/Backups" "**/transcodes"
    "/var/lib/jellyfin/metadata"
    # Dossier personnel : dépendances et artefacts reconstruits par les projets
    "${home}/.local/share/docker" "${home}/.local/share/containers"
    "**/node_modules" "**/.direnv" "**/target" "**/result" "**/.venv" "**/__pycache__"
    "${home}/.npm" "${home}/.cargo/registry" "${home}/go/pkg" "${home}/.bun"
  ];
  backupPaths = pkgs.writeShellScript "backup-paths" ''
    for d in ${lib.concatStringsSep " " (appDirs ++ [ home ])}; do
      [ -e "$d" ] && echo "$d"
    done
    exit 0
  '';

  appStop = pkgs.writeShellScript "backup-apps-stop" ''
    # Ne pas arrêter les applications si le prune B2 est en cours
    # ou en train de démarrer/s'arrêter.
    prune_state="$(${pkgs.systemd}/bin/systemctl show \
      --property=ActiveState --value restic-backups-b2-prune.service)"

    case "$prune_state" in
      active|activating|deactivating|reloading)
        echo "Prune Restic B2 en cours : arrêt des applications refusé." >&2
        exit 1
        ;;
    esac

    : > /run/backup-stopped-services
    for s in ${lib.concatStringsSep " " appServices}; do
      if ${pkgs.systemd}/bin/systemctl is-active --quiet "$s.service"; then
        echo "$s" >> /run/backup-stopped-services
        ${pkgs.systemd}/bin/systemctl stop "$s.service"
      fi
    done
  '';
  appStart = pkgs.writeShellScript "backup-apps-start" ''
    [ -f /run/backup-stopped-services ] || exit 0
    while read -r s; do
      ${pkgs.systemd}/bin/systemctl start "$s.service" || true
    done < /run/backup-stopped-services
    rm -f /run/backup-stopped-services
  '';

  notify = pkgs.writeShellScript "backup-notify" ''
    # $1 = titre, $2 = message, $3 = priorité (high par défaut).
    # Le sujet ntfy est un secret : qui le connaît lit les alertes.
    topic="$(cat ${config.sops.secrets.ntfy_topic.path})"
    ${pkgs.curl}/bin/curl -fsS --max-time 15 -H "Title: [${host}] $1" -H "Priority: ''${3:-high}" \
      -H "Tags: warning" -d "$2" "https://ntfy.sh/$topic" >/dev/null
  '';

  watchdog = pkgs.writeShellScript "backup-watchdog" ''
    now=$(date +%s)
    check() { # $1 = nom, $2 = âge max en heures
      f=${stampDir}/$1
      if [ ! -f "$f" ]; then
        ${notify} "Sauvegarde $1 jamais réussie" "Aucune sauvegarde $1 réussie enregistrée sur ${host}. Voir : journalctl -u $3"
        return
      fi
      age=$(( (now - $(stat -c %Y "$f")) / 3600 ))
      if [ "$age" -gt "$2" ]; then
        ${notify} "Sauvegarde $1 en retard" "Dernière sauvegarde $1 réussie il y a $age h sur ${host}. Voir : journalctl -u $3"
      fi
    }
    check b2 36 restic-backups-b2
    exit 0
  '';
in
lib.mkIf cfg.enable {
  assertions = [
    { assertion = cfg.b2Bucket != "";
      message = "backup.b2Bucket : indique le nom de ton bucket B2 dans settings-common.nix."; }
  ];

  # ---------- Secrets (sops-nix) ----------
  sops = {
    defaultSopsFile = ../secrets/${host}.yaml;
    # La machine déchiffre avec sa propre clé SSH d'hôte (convertie en clé age).
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    secrets = {
      restic_password = { };
      b2_account_id = { };
      b2_account_key = { };
      ntfy_topic = { };
    };
    templates."restic-b2.env".content = ''
      B2_ACCOUNT_ID=${config.sops.placeholder.b2_account_id}
      B2_ACCOUNT_KEY=${config.sops.placeholder.b2_account_key}
    '';
  };

  systemd.tmpfiles.rules = [ "d ${stampDir} 0755 root root - -" ];

  # ---------- B2 : restic chaque nuit ----------
  services.restic.backups.b2 = {
    repository = "b2:${cfg.b2Bucket}:${host}";
    passwordFile = config.sops.secrets.restic_password.path;
    environmentFile = config.sops.templates."restic-b2.env".path;
    initialize = true;
    dynamicFilesFrom = "${backupPaths}";
    exclude = excludes;
    extraBackupArgs = [
      "--exclude-caches"
      "--exclude-larger-than=200M" # garde-fou : rien de volumineux ne part vers B2
      "--pack-size=32"             # moins d'objets → moins de transactions B2
    ];
    pruneOpts = [];
    backupPrepareCommand = "${appStop}";
    backupCleanupCommand = "${appStart}";
    timerConfig = {
      OnCalendar = "04:00";
      RandomizedDelaySec = "30m";
      Persistent = true;
    };
  };
  # ---------- B2 : nettoyage indépendant ----------
  services.restic.backups.b2-prune = {
    repository = "b2:${cfg.b2Bucket}:${host}";
    passwordFile = config.sops.secrets.restic_password.path;
    environmentFile = config.sops.templates."restic-b2.env".path;

    initialize = false;

    # Aucun fichier à sauvegarder : uniquement forget --prune.
    paths = [];
    pruneOpts = [
      "--keep-daily 7"
      "--keep-weekly 4"
      "--keep-monthly 3"
      "--max-unused 10%"
    ];

    timerConfig = {
      OnCalendar = "05:00";
      Persistent = true;
    };
  };

  # Le prune attend la fin complète de la sauvegarde,
  # y compris son ExecStopPost (redémarrage des applications).
  systemd.services.restic-backups-b2-prune = {
    preStart = ''
      set -euo pipefail

      while true; do
        backup_state="$(${pkgs.systemd}/bin/systemctl show \
          --property=ActiveState --value restic-backups-b2.service)"

        case "$backup_state" in
          active|activating|deactivating|reloading)
            ${pkgs.coreutils}/bin/sleep 10
            ;;
          *)
            break
            ;;
        esac
      done
    '';

    onFailure = [
      "backup-alert@restic-backups-b2-prune.service"
    ];
  };
  systemd.services.restic-backups-b2 = {
    onFailure = [ "backup-alert@restic-backups-b2.service" ];
    onSuccess = [ "backup-stamp@b2.service" ];
  };

  # ---------- Alertes ----------
  systemd.services."backup-alert@" = {
    description = "Alerte d'échec de sauvegarde (%i)";
    serviceConfig.Type = "oneshot";
    scriptArgs = "%i";
    script = ''
      ${notify} "Échec de sauvegarde" "Le service $1 a échoué sur ${host}. Voir : journalctl -u $1 -n 50"
    '';
  };
  systemd.services."backup-stamp@" = {
    description = "Horodatage de réussite de sauvegarde (%i)";
    serviceConfig.Type = "oneshot";
    scriptArgs = "%i";
    script = ''touch ${stampDir}/"$1"'';
  };
  systemd.services.backup-watchdog = {
    description = "Vérifie que les sauvegardes sont récentes";
    serviceConfig.Type = "oneshot";
    script = "${watchdog}";
  };
  systemd.timers.backup-watchdog = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "12:00"; Persistent = true; };
  };

  environment.systemPackages = [ pkgs.restic pkgs.age pkgs.sops pkgs.ssh-to-age ];
}
