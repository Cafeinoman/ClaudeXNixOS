{
  description = "Configuration NixOS des serveurs Kimsufi";

  inputs = {
    # Branche stable. 26.05 est maintenue jusqu'au 31/12/2026 :
    # passer à nixos-26.11 en décembre (voir README, phase 5).
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    # Sert UNIQUEMENT à prendre un Claude Code récent (modules/dev.nix) : la branche stable
    # reste à 2.1.223, trop ancien pour Remote Control avec la télémétrie coupée (2.1.283 requis).
    # Le reste du système vient de la branche stable.
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    disko = {
      url = "github:nix-community/disko/latest";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Confine un service dans un namespace réseau qui ne sort que par WireGuard.
    vpn-confinement.url = "github:Maroka-chan/VPN-Confinement";

    # Secrets chiffrés dans Git (mots de passe de sauvegarde, clés B2…).
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, nixpkgs-unstable, disko, vpn-confinement, sops-nix, ... }:
    let
      # Une machine = un dossier hosts/<nom>/ (settings.nix, network.nix,
      # hardware-configuration.nix) + le socle commun modules/system.nix.
      mkHost = name: nixpkgs.lib.nixosSystem {
        specialArgs = {
          settings = import ./hosts/${name}/settings.nix;
          inherit nixpkgs-unstable;
        };
        modules = [
          disko.nixosModules.disko
          vpn-confinement.nixosModules.default
          sops-nix.nixosModules.sops
          ./modules/system.nix
          ./hosts/${name}/network.nix
          ./hosts/${name}/hardware-configuration.nix
        ];
      };
    in
    {
      nixosConfigurations = {
        NixKS = mkHost "NixKS"; # KS-5 Xeon E3-1270 v6 : serveur principal
      };

      # nix flake check : tests des scripts (dépôts Git jetables, sans réseau).
      checks.x86_64-linux.menage-git =
        let pkgs = nixpkgs.legacyPackages.x86_64-linux; in
        pkgs.runCommand "menage-git-test" {
          nativeBuildInputs = with pkgs; [ bash git shellcheck coreutils findutils gnugrep gnused ];
        } ''
          shellcheck ${./scripts/menage-git.sh} ${./scripts/tests/menage-git-test.sh}
          MENAGE_SCRIPT=${./scripts/menage-git.sh} bash ${./scripts/tests/menage-git-test.sh}
          touch $out
        '';
    };
}
