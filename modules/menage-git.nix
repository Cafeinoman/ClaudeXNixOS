# Ménage quotidien des dépôts Git de l'utilisateur (scripts/menage-git.sh) : branches fusionnées
# supprimées (locales et sur GitHub), retour sur main, notification ntfy des PR ouvertes.
# Un script, pas un agent Claude : supprimer des branches doit être déterministe et testé
# (scripts/tests/menage-git-test.sh, aussi lancé par « nix flake check »).
# Essai sans rien changer : menage-git --dry-run
# Journal : journalctl -u menage-git
{ config, lib, pkgs, settings, ... }:
let
  user = settings.userName;
  # Le sujet ntfy (ntfy_topic_claude, lisible par l'utilisateur) est déclaré par dev.nix.
  ntfy = settings.backup.enable;

  menageGit = pkgs.writeShellApplication {
    name = "menage-git";
    runtimeInputs = with pkgs; [ git gh openssh coreutils findutils gnugrep gnused ];
    # Le script gère ses erreurs lui-même (sans errexit) : on le lance tel quel.
    text = ''exec ${pkgs.bash}/bin/bash ${../scripts/menage-git.sh} "$@"'';
  };

  # $1 = titre ; corps sur l'entrée standard. Seuls les noms de dépôts et les titres de PR partent
  # chez ntfy.sh. Piège connu : le Cyberfiltre d'Orange bloque ntfy.sh en réseau mobile (voir dev.nix).
  notifier = pkgs.writeShellApplication {
    name = "menage-git-notifier";
    runtimeInputs = [ pkgs.curl pkgs.coreutils ];
    text = ''
      topic="$(cat ${config.sops.secrets.ntfy_topic_claude.path})"
      curl -fsS --max-time 15 -H "Title: [${settings.hostName}] $1" -H "Tags: git" \
        --data-binary @- "https://ntfy.sh/$topic" >/dev/null
    '';
  };
in
{
  environment.systemPackages = [ menageGit ];

  # Service système lancé sous l'utilisateur (ses clés gh, ses dépôts), pas en root.
  systemd.services.menage-git = {
    description = "Ménage des branches Git fusionnées et rappel des PR ouvertes";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    environment = lib.mkIf ntfy { MENAGE_NOTIFIER = "${notifier}/bin/menage-git-notifier"; };
    serviceConfig = {
      Type = "oneshot";
      User = user;
      ExecStart = "${menageGit}/bin/menage-git /home/${user}";
      Nice = 10;
    };
  };
  systemd.timers.menage-git = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "08:00"; Persistent = true; RandomizedDelaySec = "10m"; };
  };
}
