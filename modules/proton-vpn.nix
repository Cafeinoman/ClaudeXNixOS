# qBittorrent confiné derrière Proton VPN (WireGuard), avec redirection de port NAT-PMP.
# Activé par seedbox.enable = true ET seedbox.vpn = true dans settings.nix.
#
# Principe : qBittorrent tourne dans un espace réseau ("namespace") nommé "proton" dont
# la seule sortie vers Internet est le tunnel WireGuard. Si le VPN tombe, qBittorrent
# n'a plus aucune connexion : il ne peut pas fuiter par l'IP du serveur (kill switch).
#
# Le fichier WireGuard de Proton contient une clé privée : il n'est PAS dans Git.
# Il doit être déposé à la main sur le serveur (voir README, phase 4 bis).
{ lib, pkgs, settings, ... }:
let
  cfg = settings.seedbox;
  ns = "proton";                 # nom du namespace (7 caractères maximum)
  wgInterface = "${ns}0";        # interface WireGuard créée par VPN-Confinement
  bridge = "${ns}-br";           # pont entre le système et le namespace
  nsAddress = "192.168.15.1";    # adresse de qBittorrent vue depuis le système
  webuiPort = 8090;
  secretFile = "/var/lib/secrets/proton.conf";

  tailscaleV4 = "100.64.0.0/10";
  tailscaleV6 = "fd7a:115c:a1e0::/48";

  # Demande un port à Proton toutes les 45 s (le bail dure 60 s), ouvre ce port dans
  # le pare-feu du namespace et le donne à qBittorrent s'il a changé.
  portForward = pkgs.writeShellApplication {
    name = "proton-port-forward";
    runtimeInputs = with pkgs; [ libnatpmp curl jq iptables gawk coreutils ];
    text = ''
      GW=10.2.0.1
      QBT=http://127.0.0.1:${toString webuiPort}

      # Chaîne dédiée dans le pare-feu du namespace, vidée à chaque changement de port.
      iptables -N pf 2>/dev/null || true
      iptables -C INPUT -j pf 2>/dev/null || iptables -I INPUT -j pf

      current=""
      warned=""
      while true; do
        natpmpc -a 1 0 udp 60 -g "$GW" >/dev/null \
          || { echo "natpmpc (UDP) a échoué : serveur Proton sans NAT-PMP, ou tunnel coupé" >&2; exit 1; }
        out="$(natpmpc -a 1 0 tcp 60 -g "$GW")" \
          || { echo "natpmpc (TCP) a échoué" >&2; exit 1; }
        port="$(awk '/Mapped public port/ { print $4; exit }' <<<"$out")"
        [[ "$port" =~ ^[0-9]+$ ]] || { echo "réponse NAT-PMP illisible : $out" >&2; exit 1; }

        if [[ "$port" != "$current" ]]; then
          iptables -F pf
          iptables -A pf -i ${wgInterface} -p tcp --dport "$port" -j ACCEPT
          iptables -A pf -i ${wgInterface} -p udp --dport "$port" -j ACCEPT
          echo "Port attribué par Proton : $port"
          current="$port"
        fi

        # qBittorrent répond sans mot de passe sur localhost si l'option
        # « Contourner l'authentification pour localhost » est cochée.
        if qbt_port="$(curl -fsS --max-time 5 "$QBT/api/v2/app/preferences" | jq -er .listen_port)"; then
          warned=""
          if [[ "$qbt_port" != "$port" ]]; then
            curl -fsS --max-time 5 "$QBT/api/v2/app/setPreferences" \
              --data-urlencode "json={\"listen_port\":$port,\"upnp\":false,\"random_port\":false}" \
              && echo "qBittorrent écoute maintenant sur le port $port"
          fi
        elif [[ -z "$warned" ]]; then
          echo "qBittorrent injoignable sur localhost : démarrage en cours, ou option" \
               "« Contourner l'authentification pour localhost » non cochée" >&2
          warned=1
        fi

        sleep 45
      done
    '';
  };
in
lib.mkIf (cfg.enable && cfg.vpn) {
  systemd.tmpfiles.rules = [ "d /var/lib/secrets 0700 root root - -" ];

  vpnNamespaces.${ns} = {
    enable = true;
    wireguardConfigFile = secretFile;
    # Qui peut joindre l'interface web de qBittorrent : tes appareils Tailscale
    # (le système lui-même y accède directement par ${nsAddress}).
    accessibleFrom = [ tailscaleV4 tailscaleV6 ];
    portMappings = [{ from = webuiPort; to = webuiPort; }];
  };

  systemd.services.qbittorrent = {
    vpnConfinement = {
      enable = true;
      vpnNamespace = ns;
    };
    # Ne démarre pas tant que le fichier Proton n'est pas en place.
    unitConfig.ConditionPathExists = secretFile;
  };

  systemd.services.proton-port-forward = {
    description = "Redirection de port Proton VPN (NAT-PMP) pour qBittorrent";
    wantedBy = [ "multi-user.target" ];
    after = [ "qbittorrent.service" ];
    vpnConfinement = {
      enable = true;
      vpnNamespace = ns;
    };
    unitConfig.ConditionPathExists = secretFile;
    serviceConfig = {
      ExecStart = lib.getExe portForward;
      Restart = "always";
      RestartSec = 15;
    };
  };

  # Garde-fou : VPN-Confinement redirige le port ${toString webuiPort} vers le namespace
  # quelle que soit l'interface d'arrivée, et le pare-feu iptables de NixOS ne filtre
  # pas le routage. Sans cette règle, l'interface web pourrait être atteinte depuis
  # Internet. Seul Tailscale est autorisé à ouvrir une connexion vers le namespace.
  networking.firewall.extraCommands = ''
    for ipt in iptables ip6tables; do
      $ipt -C FORWARD -o ${bridge} ! -i tailscale0 -m conntrack --ctstate NEW -j DROP 2>/dev/null \
        || $ipt -I FORWARD 1 -o ${bridge} ! -i tailscale0 -m conntrack --ctstate NEW -j DROP
    done
  '';
  networking.firewall.extraStopCommands = ''
    for ipt in iptables ip6tables; do
      $ipt -D FORWARD -o ${bridge} ! -i tailscale0 -m conntrack --ctstate NEW -j DROP 2>/dev/null || true
    done
  '';
}
