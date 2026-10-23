# Socle : utilisateur, SSH durci, pare-feu, Tailscale, mosh, entretien de Nix.
{ lib, pkgs, settings, ... }:
let
  low = settings.lowSpecHardware;
in
{
  time.timeZone = settings.timeZone;
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings.LC_TIME = "fr_FR.UTF-8";
  console.keyMap = "fr";

  # ---------- Utilisateur ----------
  # Mot de passe défini pendant l'installation (pas stocké dans Git).
  users.users.${settings.userName} = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = settings.sshKeys;
  };
  # sudo DEMANDE le mot de passe : c'est le garde-fou entre Claude Code et root.
  security.sudo.wheelNeedsPassword = true;

  # ---------- SSH ----------
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # ---------- Réseau ----------
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ]; # à fermer en phase 3, une fois Tailscale validé
    trustedInterfaces = [ "tailscale0" ];
  };
  services.tailscale = {
    enable = true;
    openFirewall = true;
  };
  # Shell qui survit aux coupures réseau du téléphone (UDP 60000-61000).
  programs.mosh.enable = true;

  # ---------- Mémoire ----------
  # Swap compressé en RAM, prioritaire sur le swap disque (bien plus lent).
  zramSwap = {
    enable = true;
    algorithm = if low then "lz4" else "zstd"; # lz4 : le moins gourmand en CPU
    memoryPercent = if low then 50 else 25;
  };
  # Petite machine : accélère nettement nixos-rebuild et réduit la RAM nécessaire.
  documentation.nixos.enable = !low;
  documentation.man.cache.enable = lib.mkIf low false;

  # ---------- Santé des disques ----------
  # Disques durs probablement âgés : surveillance SMART en continu.
  # Les alertes apparaissent dans le journal : journalctl -u smartd
  services.smartd = {
    enable = true;
    autodetect = true;
  };
  services.btrfs.autoScrub = {
    enable = true; # détecte la corruption silencieuse des données, une fois par mois
    interval = "monthly";
  };

  # ---------- Nix ----------
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store = true;
  } // lib.optionalAttrs low {
    # Petite machine : ne jamais compiler en parallèle, on vit du cache binaire.
    max-jobs = 1;
    cores = 2;
  };
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  # Pas de mise à jour automatique : on met à jour à la main (README, phase 5),
  # pour qu'aucun changement n'arrive sans qu'un humain l'ait vu.

  # ---------- Outils ----------
  environment.systemPackages = with pkgs; [
    git vim tmux htop btop curl wget rsync jq ripgrep fd tree ncdu
    nvd # montre ce qui change entre deux générations
    smartmontools # smartctl -a /dev/sda : état du disque
    ffmpeg-headless # inspecter un fichier vidéo : ffprobe film.mkv
  ];

  environment.shellAliases = {
    rebuild = "sudo nixos-rebuild switch --flake ~/nixos-config#${settings.hostName}";
    rebuild-test = "sudo nixos-rebuild test --flake ~/nixos-config#${settings.hostName}";
    rebuild-check = "nixos-rebuild build --flake ~/nixos-config#${settings.hostName} && nvd diff /run/current-system ./result";
  };
}
