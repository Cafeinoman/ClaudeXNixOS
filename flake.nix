{
  description = "Configuration NixOS des serveurs Kimsufi";

  inputs = {
    # Branche stable. 26.05 est maintenue jusqu'au 31/12/2026 :
    # passer à nixos-26.11 en décembre (voir README, phase 5).
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

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

  outputs = { nixpkgs, disko, vpn-confinement, sops-nix, ... }:
    let
      # Une machine = un dossier hosts/<nom>/ (settings.nix, network.nix,
      # hardware-configuration.nix) + le socle commun modules/system.nix.
      mkHost = name: nixpkgs.lib.nixosSystem {
        specialArgs.settings = import ./hosts/${name}/settings.nix;
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
        atom = mkHost "atom"; # ancien KS-3 Atom : rodage, dev, seedbox
        ks3 = mkHost "ks3";   # KS-3 Xeon 1245 v5 : serveur principal
      };
    };
}
