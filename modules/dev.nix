# Poste de travail distant pour Claude Code et les side projects.
{ pkgs, settings, ... }:
{
  # Indispensable : permet de lancer les binaires précompilés (installeur natif
  # de Claude Code, outils téléchargés par npm/pip, extensions VS Code Server…).
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
  ];

  # Garde les services utilisateur (docker rootless, sessions tmux…) actifs
  # même quand aucune session SSH n'est ouverte.
  users.users.${settings.userName}.linger = true;
}
