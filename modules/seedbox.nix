# Seedbox Servarr : qBittorrent + Prowlarr + Sonarr + Radarr (+ Bazarr, Lidarr en option).
# Activée par seedbox.enable = true dans settings.nix. Arborescence : modules/media.nix.
#
# Toutes les interfaces web ne sont joignables QUE via Tailscale (aucun port web ouvert
# au public ; tailscale0 est une interface de confiance dans base.nix).
{ lib, settings, ... }:
let
  cfg = settings.seedbox;
  torrentPort = 50000;

  # Les services tournent avec "media" comme groupe PRINCIPAL : leur bac à sable systemd
  # (PrivateUsers) ignore les groupes secondaires. UMask 0002 : fichiers modifiables
  # par tout le groupe, sinon Sonarr ne peut pas déplacer ce que qBittorrent a écrit.
  shared = {
    UMask = lib.mkForce "0002";
    Nice = 5;
  };
in
lib.mkIf cfg.enable (lib.mkMerge [
  {
    # ---------- qBittorrent (client torrent) ----------
    # Réglages faits dans l'interface web (voir README) : ils y restent modifiables.
    # Avec seedbox.vpn = true, qBittorrent passe par Proton (modules/proton-vpn.nix) et
    # son port d'écoute est fixé automatiquement par la redirection de port Proton.
    services.qbittorrent = {
      enable = true;
      group = "media";
      webuiPort = 8090; # 8080 laissé libre pour tes side projects
      torrentingPort = if cfg.vpn then null else torrentPort;
    };
    systemd.services.qbittorrent.serviceConfig = shared // {
      # Disques durs : le torrent passe après tout le reste (streaming, Claude Code).
      Nice = 10;
      IOSchedulingClass = "idle";
    };

    # ---------- Prowlarr (indexeurs, une seule fois pour tous les *arr) ----------
    services.prowlarr.enable = true; # port 9696

    # ---------- Sonarr (séries) et Radarr (films) ----------
    services.sonarr = { enable = true; group = "media"; }; # port 8989
    services.radarr = { enable = true; group = "media"; }; # port 7878
    systemd.services.sonarr.serviceConfig = shared;
    systemd.services.radarr.serviceConfig = shared;
  }

  # Sans VPN : port des pairs BitTorrent ouvert sur l'IP du serveur.
  (lib.mkIf (!cfg.vpn) {
    networking.firewall.allowedTCPPorts = [ torrentPort ];
    networking.firewall.allowedUDPPorts = [ torrentPort ];
  })

  # ---------- Bazarr (sous-titres) ----------
  (lib.mkIf cfg.bazarr {
    services.bazarr = { enable = true; group = "media"; }; # port 6767
    systemd.services.bazarr.serviceConfig = shared;
  })

  # ---------- Lidarr (musique) ----------
  (lib.mkIf cfg.lidarr {
    services.lidarr = { enable = true; group = "media"; }; # port 8686
    systemd.services.lidarr.serviceConfig = shared;
  })
])
