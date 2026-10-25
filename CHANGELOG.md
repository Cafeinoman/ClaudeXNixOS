# Journal des changements système

| Date | Changement | Pourquoi | Retour arrière |
|------|-----------|----------|----------------|
| 2026-10-24 | Installation initiale NixOS 26.05 sur `atom` | Socle du serveur | Réinstallation depuis le mode rescue |
| 2026-10-23 | `settings-common.nix` : userName `fdelalleau`, clé SSH du téléphone | Retirer les CHANGE_ME avant l'installation | `git revert` du commit |
| 2026-10-23 | `install-from-rescue.sh` : chemin d'évaluation `nixosConfigurations.<machine>` | Le garde-fou échouait avant tout changement de disque | `git revert` du commit |
| 2026-10-23 | `install-from-rescue.sh` : option TEMP_SWAP (swap provisoire avant disko) | Le rescue de l'Atom (4 Go, sans zram) tuait nix par manque de mémoire | `git revert` du commit |
| 2026-10-24 | `install-from-rescue.sh` : disko construit depuis la config, store Nix déplacé sur le disque cible, système construit sans `nixos-install` | RAM saturée par le CLI disko ; bac à sable impossible sur le rootfs du rescue pour un store détourné | `git revert` du commit |
| 2026-10-25 | `settings-common.nix` : clé SSH du téléphone ajoutée, l'ancienne renommée « poste » | Se connecter (SSH/mosh) depuis le téléphone ; la première clé est celle du poste | Retirer la ligne puis `rebuild` |
| 2026-10-25 | `modules/dev.nix` : `pkgs.claude-code` (non libre, autorisé seul) sur `ks3` uniquement | Installation déclarative ; le CPU de l'Atom ne peut pas l'exécuter | Retirer la ligne puis `rebuild` |
| 2026-10-25 | `hosts/atom/settings.nix` : `seedbox.enable = true` (sans VPN) | Tester qBittorrent + Prowlarr + Sonarr + Radarr avant les sauvegardes ; torrents libres seulement tant que `vpn = false` | `enable = false` puis `rebuild` |
| 2026-10-25 | `modules/media.nix` : dossier `/srv/data/media/.corbeille` | Corbeille des *arr : sans elle, une suppression dans Radarr est définitive ; le dossier doit exister pour être accepté | Retirer l'entrée puis `rebuild` (le dossier reste) |
| 2026-10-25 | `atom` : Jellyfin + partage SMB en lecture seule (`streaming.smb`, via Tailscale) | Tester la lecture directe et le débit réel avant de choisir le serveur suivant | `jellyfin = false; smb = false;` puis `rebuild` |
| 2026-10-25 | `hosts/atom/settings.nix` : `seedbox.vpn = true` | qBittorrent confiné derrière Proton VPN (kill switch, NAT-PMP) : l'IP du serveur n'est plus exposée aux pairs | `vpn = false` puis `rebuild` |
| 2026-10-25 | `atom` : sauvegarde B2 nocturne (restic, bucket `NixOS-save`), `.sops.yaml` rempli | Phase 7 : l'état des applications n'existait qu'en un exemplaire ; pas de copie Proton (CLI incompatible avec le CPU) | `backup.enable = false` puis `rebuild` |
