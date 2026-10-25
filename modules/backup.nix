# Sauvegardes de l'état des applications et du dossier personnel.
#
#  1. B2 (principal, chaque nuit) : restic vers Backblaze B2, chiffré côté serveur avant
#     envoi, avec historique (7 jours, 4 semaines, 3 mois). Gratuit tant que le dépôt
#     reste sous 10 Go ; les plafonds à 0 $ côté B2 transforment tout dépassement en
#     refus, jamais en facture (README, « Sauvegardes »).
#  2. Proton Drive (secondaire, À LA DEMANDE) : commande `sauvegarde-proton`. Archive tar
#     chiffrée avec age pour TA clé publique (le serveur ne peut pas la relire), envoyée
#     par le CLI officiel, 4 archives conservées. Manuel, car la session Proton est pensée
#     pour un humain : si elle a expiré, tu es là pour te reconnecter.
#  3. Alertes : notification ntfy sur le téléphone si une sauvegarde échoue, chien de
#     garde quotidien si la dernière sauvegarde B2 est trop ancienne, et simple rappel
#     si la dernière copie Proton date de plus de `protonReminderDays` jours.
#
# Secrets (sops-nix, chiffrés dans Git) : secrets/<machine>.yaml — voir secrets/README.md.
{ config, lib, pkgs, settings, ... }:
let
  cfg = settings.backup;
  host = settings.hostName;
  user = settings.userName;
  home = "/home/${user}";
  stampDir = "/var/lib/backup-stamps";
  protonHome = "/var/lib/proton-backup";

  # Services arrêtés pendant la copie : leurs bases SQLite doivent être au repos.
  appServices = [
    "sonarr" "radarr" "prowlarr" "qbittorrent" "bazarr" "lidarr"
    "jellyfin" "seerr" "navidrome" "audiobookshelf"
  ];
  appDirs = [
    "/var/lib/sonarr" "/var/lib/radarr" "/var/lib/private/prowlarr" "/var/lib/qBittorrent"
    "/var/lib/bazarr" "/var/lib/lidarr" "/var/lib/jellyfin" "/var/lib/private/seerr"
    "/var/lib/navidrome" "/var/lib/audiobookshelf" "/var/lib/secrets"
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
  # Même liste pour tar, qui travaille en chemins relatifs à / (« var/lib/... »).
  tarExcludes = map (e: lib.removePrefix "/" (lib.removePrefix "**/" e)) excludes;

  backupPaths = pkgs.writeShellScript "backup-paths" ''
    for d in ${lib.concatStringsSep " " (appDirs ++ [ home ])}; do
      [ -e "$d" ] && echo "$d"
    done
    exit 0
  '';

  appStop = pkgs.writeShellScript "backup-apps-stop" ''
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

  # Arguments du CLI Proton Drive (version 0.8+). L'interface du CLI évolue encore :
  # en cas d'erreur après une mise à jour, vérifier `proton-drive filesystem upload --help`.
  protonEnv = {
    HOME = protonHome;
    GNUPGHOME = "${protonHome}/.gnupg";
    PASSWORD_STORE_DIR = "${protonHome}/.password-store";
    PROTON_DRIVE_CREDENTIALS_STORE = "pass";
    PROTON_DRIVE_CACHE_DIR = "${protonHome}/cache";
    PROTON_DRIVE_LOG_LEVEL = "WARNING";
  };
  protonBin = "${protonHome}/bin/proton-drive";
  protonDir = "${cfg.protonFolder}/${host}";

  protonUpload = pkgs.writeShellScript "proton-backup-upload" ''
    set -euo pipefail
    out=${protonHome}/out
    archive="$(ls -1t "$out"/*.tar.gz.age | head -n1)"
    name="$(basename "$archive")"
    ${protonBin} filesystem upload --json \
      --file-conflict-strategy skip --skip-thumbnails \
      "$archive" ${lib.escapeShellArg protonDir}
    echo "$name" >> ${protonHome}/uploaded.txt
    rm -f "$out"/*.tar.gz.age

    # Rétention : on garde les 4 dernières archives envoyées.
    total=$(wc -l < ${protonHome}/uploaded.txt)
    if [ "$total" -gt 4 ]; then
      head -n $((total - 4)) ${protonHome}/uploaded.txt | while read -r old; do
        ${protonBin} filesystem delete --json ${lib.escapeShellArg protonDir}/"$old" \
          || echo "Suppression impossible de $old (à faire à la main)" >&2
      done
      tail -n 4 ${protonHome}/uploaded.txt > ${protonHome}/uploaded.tmp
      mv ${protonHome}/uploaded.tmp ${protonHome}/uploaded.txt
    fi
  '';

  protonArchive = pkgs.writeShellScript "proton-backup-archive" ''
    set -euo pipefail
    out=${protonHome}/out
    install -d -o proton-backup -g proton-backup -m 700 "$out"
    file="$out/${host}-$(date +%Y%m%d).tar.gz.age"
    ${backupPaths} | sed 's|^/||' > /run/proton-backup-paths
    ${appStop}
    trap '${appStart}; rm -f /run/proton-backup-paths' EXIT
    set +e +o pipefail
    ${pkgs.gnutar}/bin/tar -czpf - -C / --warning=no-file-changed \
      ${lib.concatMapStringsSep " " (e: "--exclude=${lib.escapeShellArg e}") tarExcludes} \
      -T /run/proton-backup-paths \
      | ${pkgs.age}/bin/age -r ${lib.escapeShellArg cfg.ageRecipient} > "$file"
    status=("''${PIPESTATUS[@]}")
    set -e
    # tar renvoie 1 si un fichier a changé pendant la lecture (dossier personnel actif) :
    # l'archive reste valide. Au-delà, ou si age échoue, c'est une vraie erreur.
    if [ "''${status[0]}" -gt 1 ] || [ "''${status[1]}" -ne 0 ]; then
      rm -f "$file"
      echo "Échec de l'archive (tar=''${status[0]}, age=''${status[1]})" >&2
      exit 1
    fi
    chown proton-backup:proton-backup "$file"
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
    ${lib.optionalString (cfg.protonCopy && cfg.protonReminderDays > 0) ''
      # Proton est manuel : pas une alerte, un rappel, au plus une fois par semaine.
      f=${stampDir}/proton
      last=${stampDir}/proton-reminder
      days=-1
      [ -f "$f" ] && days=$(( (now - $(stat -c %Y "$f")) / 86400 ))
      if [ "$days" -lt 0 ] || [ "$days" -gt ${toString cfg.protonReminderDays} ]; then
        if [ ! -f "$last" ] || [ $(( (now - $(stat -c %Y "$last")) / 86400 )) -ge 7 ]; then
          if [ "$days" -lt 0 ]; then msg="Aucune copie Proton Drive encore faite sur ${host}."
          else msg="Dernière copie Proton Drive il y a $days jours sur ${host}."; fi
          ${notify} "Rappel : copie Proton" "$msg Lance : sauvegarde-proton" default
          touch "$last"
        fi
      fi
    ''}
    exit 0
  '';

  # Exécuté en tant que proton-backup, avec l'environnement de la session Proton.
  asProton = "sudo -u proton-backup env ${lib.concatStringsSep " " (lib.mapAttrsToList (k: v: "${k}=${v}") protonEnv)} PATH=${lib.makeBinPath [ pkgs.gnupg pkgs.pass pkgs.coreutils pkgs.curl ]}";

  protonLogin = pkgs.writeShellScript "proton-backup-login" ''
    set -euo pipefail
    # Coffre local de la session : clé GPG sans phrase de passe + magasin pass.
    if ! gpg --list-secret-keys proton-backup >/dev/null 2>&1; then
      gpg --batch --passphrase "" --quick-gen-key proton-backup default default never
    fi
    [ -f "$PASSWORD_STORE_DIR/.gpg-id" ] || pass init proton-backup
    echo "Ouvre l'URL affichée ci-dessous sur ton téléphone pour autoriser le serveur."
    ${protonBin} auth login
    ${protonBin} filesystem list ${lib.escapeShellArg protonDir} >/dev/null \
      && echo "Connexion OK, dossier ${protonDir} trouvé." \
      || echo "Connecté, mais dossier ${protonDir} introuvable : crée-le dans l'app Proton Drive."
  '';

  # Commande manuelle : `sauvegarde-proton` (copie), `login`, `install <lien>`.
  protonCommand = pkgs.writeShellScriptBin "sauvegarde-proton" ''
    set -uo pipefail
    case "''${1:-}" in
      install)
        url="''${2:-}"
        [ -n "$url" ] || { echo "Usage : sauvegarde-proton install '<lien Linux x64 baseline>'"; exit 1; }
        ${asProton} curl -fL -o ${protonBin} "$url" && sudo chmod 755 ${protonBin} \
          && ${asProton} ${protonBin} --version
        ;;
      login)
        exec ${asProton} ${protonLogin}
        ;;
      ""|now)
        if [ ! -x ${protonBin} ]; then
          echo "Binaire Proton Drive absent : ${protonBin} (README, phase 7)." >&2; exit 1
        fi
        echo "Copie vers Proton Drive en cours (les applications s'arrêtent quelques minutes)…"
        start=$(date '+%Y-%m-%d %H:%M:%S')
        if sudo systemctl start proton-backup.service; then
          echo "Terminé. Archives sur Proton Drive : ${protonDir}"
        else
          echo "ÉCHEC. Dernières lignes du journal :" >&2
          sudo journalctl -u proton-backup --since "$start" -n 25 --no-pager >&2
          echo "Si la session a expiré : sauvegarde-proton login, puis relance." >&2
          exit 1
        fi
        ;;
      *)
        echo "Usage : sauvegarde-proton            copie vers Proton Drive"
        echo "        sauvegarde-proton login      (re)connecter le serveur à Proton"
        echo "        sauvegarde-proton install '<lien>'  installer le CLI officiel"
        exit 1 ;;
    esac
  '';

  # Vérifie la session Proton AVANT d'arrêter les applications pour rien.
  protonPreflight = pkgs.writeShellScript "proton-backup-preflight" ''
    if ! ${protonBin} filesystem list --json ${lib.escapeShellArg protonDir} >/dev/null; then
      echo "Session Proton invalide ou dossier ${protonDir} introuvable." >&2
      echo "Reconnecte le serveur : sauvegarde-proton login" >&2
      exit 1
    fi
  '';
in
lib.mkIf cfg.enable (lib.mkMerge [
  {
    assertions = [
      { assertion = cfg.b2Bucket != "";
        message = "backup.b2Bucket : indique le nom de ton bucket B2 dans settings-common.nix."; }
      { assertion = !cfg.protonCopy || lib.hasPrefix "age1" cfg.ageRecipient;
        message = "backup.ageRecipient : indique ta clé publique age (age1...) pour la copie Proton."; }
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
      pruneOpts = [ "--keep-daily 7" "--keep-weekly 4" "--keep-monthly 3" "--max-unused 10%" ];
      backupPrepareCommand = "${appStop}";
      backupCleanupCommand = "${appStart}";
      timerConfig = {
        OnCalendar = "04:00";
        RandomizedDelaySec = "30m";
        Persistent = true;
      };
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

  # ---------- Proton Drive : archive chiffrée, à la demande ----------
  (lib.mkIf cfg.protonCopy {
    users.users.proton-backup = {
      isSystemUser = true;
      group = "proton-backup";
      home = protonHome;
      createHome = true;
      homeMode = "700";
    };
    users.groups.proton-backup = { };
    systemd.tmpfiles.rules = [ "d ${protonHome}/bin 0755 proton-backup proton-backup - -" ];

    # Pas de timer : ce service ne démarre que via `sauvegarde-proton`.
    systemd.services.proton-backup = {
      description = "Copie de sauvegarde chiffrée vers Proton Drive (manuelle)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      environment = protonEnv;
      path = [ pkgs.gnupg pkgs.pass pkgs.coreutils ];
      serviceConfig = {
        Type = "oneshot";
        User = "proton-backup";
        Group = "proton-backup";
        ExecStartPre = [
          "${protonPreflight}"  # session valide ? sinon on s'arrête là
          "+${protonArchive}"   # le "+" exécute en root : lire l'état des applications
        ];
        ExecStart = "${protonUpload}";
        Nice = 10;
        IOSchedulingClass = "idle";
      };
      onSuccess = [ "backup-stamp@proton.service" ];
    };

    # `sauvegarde-proton` ; pass + gpg pour stocker la session (README).
    environment.systemPackages = [ protonCommand pkgs.pass pkgs.gnupg ];
  })
])
