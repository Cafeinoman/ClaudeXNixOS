# Poste de travail distant pour Claude Code et les side projects.
{ lib, pkgs, settings, ... }:
let
  # Claude Code est un binaire compilé avec Bun : il exige au moins SSE4.2/POPCNT, et en
  # pratique AVX. L'Atom N2800 n'a aucun des trois (`grep -w avx /proc/cpuinfo` vide) :
  # « Illegal instruction ». Donc seulement sur le Xeon (ks3), qui a l'AVX2.
  claudeCode = !settings.lowSpecHardware;
in
{
  # Paquet nixpkgs plutôt que l'installeur natif : déclaratif, version figée par
  # flake.lock (mise à jour automatique désactivée par le paquet), patché pour NixOS.
  # Non libre : on n'autorise que lui.
  nixpkgs.config.allowUnfreePredicate = pkg: lib.getName pkg == "claude-code";

  # Indispensable : permet de lancer les binaires précompilés (outils téléchargés
  # par npm/pip, extensions VS Code Server, CLI Proton Drive…).
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
  ] ++ lib.optional claudeCode claude-code;

  # Garde les services utilisateur (docker rootless, sessions tmux…) actifs
  # même quand aucune session SSH n'est ouverte.
  users.users.${settings.userName}.linger = true;
}
