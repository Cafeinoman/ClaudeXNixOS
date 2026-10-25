# Seedbox Servarr : qBittorrent + Prowlarr + Sonarr + Radarr (+ Bazarr, Lidarr en option).
# Activée par seedbox.enable = true dans settings.nix. Arborescence : modules/media.nix.
#
# Toutes les interfaces web ne sont joignables QUE via Tailscale (aucun port web ouvert
# au public ; tailscale0 est une interface de confiance dans base.nix).
{ config, lib, settings, ... }:
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

  # ---------- Recyclarr (profils de qualité TRaSH Guides) ----------
  # Crée et tient à jour dans Sonarr/Radarr les profils « WEB-1080p » et « HD Bluray + WEB »
  # (formats largement lisibles en direct) et leurs formats personnalisés, chaque nuit.
  # Les profils sont dans Git ; seules les clés API sont secrètes (sops, secrets/<machine>.yaml :
  # sonarr_api_key, radarr_api_key). À assigner ensuite aux films/séries dans Sonarr/Radarr.
  (lib.mkIf cfg.recyclarr {
    sops.defaultSopsFile = ../secrets/${settings.hostName}.yaml;
    sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    sops.secrets.sonarr_api_key = { };
    sops.secrets.radarr_api_key = { };

    services.recyclarr = {
      enable = true;
      schedule = "*-*-* 05:30:00"; # après la sauvegarde de 04:00
      configuration = {
        sonarr.series = {
          base_url = "http://localhost:8989";
          api_key._secret = config.sops.secrets.sonarr_api_key.path;
          quality_definition.type = "series";
          quality_profiles = [{
            trash_id = "72dae194fc92bf828f32cde7744e51a1"; # WEB-1080p
            reset_unmatched_scores.enabled = true;
          }];
        };
        radarr.movies = {
          base_url = "http://localhost:7878";
          api_key._secret = config.sops.secrets.radarr_api_key.path;
          quality_definition.type = "movie";
          quality_profiles = [{
            trash_id = "d1d67249d3890e49bc12e275d989a7e9"; # HD Bluray + WEB
            reset_unmatched_scores.enabled = true;
          }];
        };
      };
    };
  })

  # ---------- Lidarr (musique) ----------
  (lib.mkIf cfg.lidarr {
    services.lidarr = { enable = true; group = "media"; }; # port 8686
    systemd.services.lidarr.serviceConfig = shared;
  })
])
