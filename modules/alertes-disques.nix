# Alertes disques sur le téléphone (ntfy) : RAID mdadm et SMART.
#
# Sans ce module, mdadm (via le script mdadm-alert de disko.nix) et smartd n'écrivent que dans le
# journal, que personne ne lit. Ici, deux mécanismes complémentaires :
#   1. En direct : un service suit le journal (identifiant mdadm-alert, et smartd au niveau
#      « warning » ou plus grave) et envoie chaque alerte sur ntfy. Un même message n'est pas
#      renvoyé avant 24 h (smartd répète ses alertes toutes les 30 min).
#   2. Chaque jour à 12:00 : l'état est relu (RAID dégradé dans /proc/mdstat, verdict SMART de
#      chaque disque). Rattrape une alerte perdue pendant un redémarrage du service ou du serveur.
#
# Le sujet ntfy est le secret ntfy_topic, déclaré par backup.nix : actif seulement si
# backup.enable = true.
#
# Tester de bout en bout (envoie un « TestMessage » par RAID) :
#   sudo mdadm --monitor --scan --oneshot --test
{ config, lib, pkgs, settings, ... }:
let
  host = settings.hostName;
  stateDir = "/var/lib/alertes-disques";

  notify = pkgs.writeShellScript "disk-notify" ''
    # $1 = titre, $2 = message, $3 = priorité ntfy (urgent, high, default).
    topic="$(cat ${config.sops.secrets.ntfy_topic.path})"
    ${pkgs.curl}/bin/curl -fsS --max-time 15 --retry 3 -H "Title: [${host}] $1" \
      -H "Priority: $3" -H "Tags: floppy_disk" -d "$2" "https://ntfy.sh/$topic" >/dev/null
  '';

  # Lit les lignes du journal sur l'entrée standard et décide quoi envoyer.
  relay = pkgs.writeShellScript "disk-alert-relay" ''
    set -u
    while IFS= read -r line; do
      case "$line" in
        # Format de mdadm-alert (disko.nix) : « RAID : <événement> sur <RAID> [disque] »
        "RAID : Fail "*|"RAID : FailSpare "*|"RAID : DegradedArray "*|"RAID : DeviceDisappeared "*)
          title="RAID dégradé"; prio=urgent ;;
        "RAID : TestMessage "*|"RAID : RebuildFinished "*|"RAID : SpareActive "*)
          title="RAID"; prio=default ;;
        "RAID : "*)
          continue ;; # NewArray, RebuildStarted, Rebuild20… : rien à faire
        *)
          title="SMART"; prio=high ;;
      esac
      stamp="${stateDir}/$(printf '%s' "$line" | ${pkgs.coreutils}/bin/sha1sum | ${pkgs.coreutils}/bin/cut -c1-16)"
      if [ -n "$(${pkgs.findutils}/bin/find "$stamp" -mmin -1440 2>/dev/null)" ]; then
        continue # déjà envoyé il y a moins de 24 h
      fi
      if ${notify} "$title" "$line" "$prio"; then
        touch "$stamp"
      else
        echo "Envoi ntfy impossible : $line" >&2
      fi
    done
  '';

  dailyCheck = pkgs.writeShellScript "disk-health-check" ''
    set -u
    if ${pkgs.gnugrep}/bin/grep -q '\[[U_]*_[U_]*\]' /proc/mdstat; then
      ${notify} "RAID dégradé" "$(${pkgs.gnugrep}/bin/grep -B1 '_' /proc/mdstat)" urgent
    fi
    for disk in /dev/sd? /dev/nvme?n1; do
      [ -b "$disk" ] || continue
      ${pkgs.smartmontools}/bin/smartctl -H "$disk" >/dev/null
      rc=$?
      # Bit 3 (8) : le disque se déclare en panne ; bit 4 (16) : seuil d'un attribut
      # « Prefailure » dépassé. Les bits 0-2 (commande impossible) ne sont pas des pannes.
      if [ $((rc & 24)) -ne 0 ]; then
        ${notify} "SMART : disque en fin de vie" \
          "$disk : verdict SMART négatif (code $rc). Voir : sudo smartctl -a $disk" urgent
      fi
    done
    exit 0
  '';
in
lib.mkIf (settings.backup.enable or false) {
  systemd.tmpfiles.rules = [ "d ${stateDir} 0700 root root - -" ];

  systemd.services.disk-alerts = {
    description = "Alertes RAID et SMART envoyées sur ntfy";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    # Groupe 1 : mdadm-alert écrit par root. Groupe 2 : smartd. -p warning s'applique aux deux.
    script = ''
      ${config.systemd.package}/bin/journalctl -f -n 0 -o cat -p warning \
        SYSLOG_IDENTIFIER=mdadm-alert _UID=0 + _SYSTEMD_UNIT=smartd.service | ${relay}
    '';
    serviceConfig = {
      Restart = "always";
      RestartSec = 30;
    };
  };

  systemd.services.disk-health-check = {
    description = "Vérification quotidienne du RAID et de SMART (alerte ntfy)";
    serviceConfig.Type = "oneshot";
    script = "${dailyCheck}";
  };
  systemd.timers.disk-health-check = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "12:00"; Persistent = true; };
  };
}
