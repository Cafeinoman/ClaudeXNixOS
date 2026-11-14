# Nom de domaine gratuit DuckDNS (<nom>.duckdns.org) pointant vers l'IP publique du serveur.
#
# Sert d'adresse publique à Locanalyse : elle est inscrite dans les codes de jumelage, et un nom
# évite de rejumeler tous les membres au prochain changement de serveur (seul le DNS bouge).
# L'IP d'un Kimsufi est fixe ; la mise à jour quotidienne garde le nom actif et le recale tout seul
# après un déménagement. DuckDNS répond aussi pour tous les sous-noms (*.<nom>.duckdns.org).
#
# Réglage : duckdns.domain = "<nom>" (sans .duckdns.org) ; null = rien.
# Secret : duckdns_token dans secrets/<machine>.yaml (sops). Le jeton ne passe jamais en argument
# de commande (visible dans `ps`) : curl le lit sur son entrée standard.
# Procédure complète : README, « Locanalyse sur NixKS avec DuckDNS ».
{ config, lib, pkgs, settings, ... }:
let
  domain = (settings.duckdns or { domain = null; }).domain;
  name = if domain == null then null else lib.removeSuffix ".duckdns.org" domain;

  update = pkgs.writeShellScript "duckdns-update" ''
    set -eu
    token="$(cat ${config.sops.secrets.duckdns_token.path})"
    # ip= vide : DuckDNS prend l'adresse d'où vient la requête (forcée en IPv4 par -4).
    # Le trafic de l'hôte ne passe pas par Proton (seul qBittorrent est dans le namespace VPN).
    answer="$(printf 'url = "https://www.duckdns.org/update?domains=%s&token=%s&ip="\n' \
      ${lib.escapeShellArg name} "$token" \
      | ${pkgs.curl}/bin/curl -4 -fsS --max-time 30 --retry 3 -K -)"
    if [ "$answer" != "OK" ]; then
      echo "DuckDNS a répondu « $answer » : nom ${name} ou jeton duckdns_token incorrect." >&2
      exit 1
    fi
    echo "${name}.duckdns.org → $(${pkgs.curl}/bin/curl -4 -fsS --max-time 15 https://ipv4.icanhazip.com || echo '?')"
  '';
in
lib.mkIf (name != null) {
  sops.defaultSopsFile = ../secrets/${settings.hostName}.yaml;
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  sops.secrets.duckdns_token = { };

  systemd.services.duckdns-update = {
    description = "Mise à jour du nom ${name}.duckdns.org";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${update}";
    };
  };
  systemd.timers.duckdns-update = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnCalendar = "daily";
      RandomizedDelaySec = "1h";
      Persistent = true;
    };
  };
}
