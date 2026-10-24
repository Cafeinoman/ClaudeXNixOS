# Journal des changements système

| Date | Changement | Pourquoi | Retour arrière |
|------|-----------|----------|----------------|
| AAAA-MM-JJ | Installation initiale NixOS 26.05 | Socle du serveur | Réinstallation depuis le mode rescue |
| 2026-10-23 | `settings-common.nix` : userName `fdelalleau`, clé SSH du téléphone | Retirer les CHANGE_ME avant l'installation | `git revert` du commit |
| 2026-10-23 | `install-from-rescue.sh` : chemin d'évaluation `nixosConfigurations.<machine>` | Le garde-fou échouait avant tout changement de disque | `git revert` du commit |
| 2026-10-23 | `install-from-rescue.sh` : option TEMP_SWAP (swap provisoire avant disko) | Le rescue de l'Atom (4 Go, sans zram) tuait nix par manque de mémoire | `git revert` du commit |
| 2026-10-24 | `install-from-rescue.sh` : disko construit depuis la config, store Nix déplacé sur le disque cible, système construit sans `nixos-install` | RAM saturée par le CLI disko ; bac à sable impossible sur le rootfs du rescue pour un store détourné | `git revert` du commit |
