# CLAUDE.md — projet « serveur Kimsufi sous NixOS »

Ce fichier a deux parties :
1. **Contexte et état d'avancement** (pour toute session de travail, y compris sur
   l'ordinateur de l'utilisateur) ;
2. **Règles sur le serveur** (valables seulement quand Claude Code tourne sur la machine
   NixOS, dans `~/nixos-config`).

Lis tout avant d'agir. Sur l'ordinateur, la partie 2 ne s'applique pas (pas de `rebuild`,
pas de `sudo` sur le serveur) ; seule la partie 1 compte.

---

# Partie 1 — Contexte et état d'avancement

## L'utilisateur et la façon de lui répondre

- Francophone. Répondre en français, concis, sans préambule.
- Premier énoncé d'une réponse : contester une hypothèse, signaler ce qui manque, ou poser
  la question qui révèle une faille. Jamais commencer par approuver.
- Étiqueter les affirmations : **[Certain]** (preuve solide), **[Probable]** (forte
  inférence), **[Suppose]** (comble un trou). Si l'essentiel de la réponse est
  de la supposition, le dire d'abord.
- La vérité désagréable d'abord, pas enfouie au troisième paragraphe.
- Désaccord structuré : « Je ne suis pas d'accord parce que… Voici ce que je ferais à la
  place… Le risque de ton approche est… ». Ne pas céder à un « mais je pense que… » ;
  ne changer d'avis que sur un fait nouveau.
- Interdits : « Excellente question », « Tu as tout à fait raison », « Ça a beaucoup de
  sens », « Absolument », « Définitivement ».
- Si des ressources externes sont utilisées : liste **[Sources]** en fin de réponse.

## Objectif du projet

Un serveur Kimsufi/OVH sous **NixOS 26.05**, reconstruit à l'identique depuis ce dépôt Git,
qui sert à :
- travailler à distance avec Claude Code **depuis le téléphone** (SSH/mosh via Tailscale) ;
- tester des side projects (Docker rootless, direnv) ;
- seedbox **Servarr** derrière **Proton VPN** ;
- streaming (Jellyfin, Seerr, Navidrome, Audiobookshelf), sur la machine Xeon suivante ;
- serveur de veille **Locanalyse** (conteneur isolé, seul service exposé à Internet).

Contraintes : budget serveur ≤ **30 € TTC/mois**, 2 To suffisent. **KS-5 obtenu et installé le
11/11/2026** : `ns3109411.ip-54-36-110.eu`, IP `54.36.110.44`, datacenter **Limburg** (`lim1`, Allemagne).

## Deux machines, un dépôt

| Machine | Matériel | Rôle |
|---|---|---|
| `atom` (déjà louée) | KS-3 ancien : Atom N2800, 4 Go, 1 × 2 To, pas de VT-x, ni AVX ni SSE4.2 | rodage, seedbox + VPN, sauvegarde B2 ; Jellyfin et SMB en lecture directe (Jellyfin instable : SQLite en SIGILL) ; **pas de Claude Code** |
| `NixKS` (installée le 11/11/2026, services pas encore activés) | KS-5 : Xeon E3-1270 v6 (4 c / 8 f, AVX2, **sans iGPU**), 32 Go, 2 × 2 To HGST HUS724020ALA640 en RAID 1 mdadm, démarrage **UEFI** | serveur principal : dev + seedbox + streaming |

- Nom Tailscale / DNS de `NixKS` : `nixks` (les noms d'hôte sont insensibles à la casse).
- Machine suivante : **KS-5 (`24sk50-v1`, Xeon E3-1270 v6, 4 cœurs / 8 fils, sans iGPU donc
  transcodage logiciel seulement)**, 2 × 2 To HDD, 32 Go, 17,99 € HT = 21,59 € TTC (catalogue du
  25/10/2026). Datacenters : gra, rbx, sbg, lon, fra. Config : `hosts/NixKS/`.
  KS-5-A (`26sk50a-v1`, Xeon E-2274G avec iGPU) : 26,99 € HT = 32,39 € TTC, hors budget.
- Tâche planifiée d'alerte de stock : **supprimée le 11/11/2026**. `scripts/ks-stock-check.sh` ne sert plus.

## Décisions d'architecture (et pourquoi)

- **Mode rescue + `scripts/install-from-rescue.sh <machine>`**, pas BYOI/BYOLinux :
  image < RAM − 3 Gio, pas de RAID logiciel, une seule partition. [Certain, doc OVH]
- **disko** : partitionnement déclaratif (GPT hybride BIOS+UEFI, btrfs @root/@nix/@home/@srv,
  RAID 1 mdadm métadonnées 1.0 pour /boot).
- **Flake** : `mkHost name` ; réglages dans `settings-common.nix` + `hosts/<machine>/settings.nix`.
- **Bases SQLite des *arr et de Jellyfin volontairement HORS de Git** (binaires, secrets,
  risque de corruption). Elles sont sauvegardées (restic) et déménagées avec
  `scripts/migrate-app-state.sh export|import`. Compromis accepté par l'utilisateur.
- **VPN** : VPN-Confinement (netns `proton`), fichier WireGuard `/var/lib/secrets/proton.conf`
  **jamais dans Git**, boucle NAT-PMP vers 10.2.0.1 pour le port de qBittorrent (50000),
  coupe-circuit : FORWARD refusé hors `tailscale0`.
- **Accès aux services : uniquement par Tailscale** (sauf `streaming.publicDomain`, null par défaut).
- **Sauvegardes (`modules/backup.nix`)** :
  - **B2 : automatique**, nuit 04:00, restic, coût **zéro** exigé (10 Go gratuits ; plafonds
    de transactions et de stockage à régler manuellement à 0 $ dans la console B2 ; cycle de vie
    « garder seulement la dernière version » ; pas de carte bancaire ; `--exclude-larger-than=200M`).
    [Suppose] la valeur par défaut des plafonds d'un nouveau compte B2 : inconnue, donc à vérifier.
  - **Proton Drive : à la demande**, commande `sauvegarde-proton` (sous-commandes `install '<lien>'`,
    `login`, défaut = copie). Archive tar.gz chiffrée avec **age**, garde les 4 dernières.
    Pas de timer. Vérification de session **avant** l'arrêt des applications. Rappel ntfy si
    aucune copie depuis `protonReminderDays` (30 ; 0 = jamais), au plus une fois par 7 jours.
    Recommandation faite : un **compte Proton dédié** (la session CLI donne accès à tout le Drive).
  - Secrets via **sops-nix + age** (clé machine = clé SSH hôte). Clés attendues dans
    `secrets/<machine>.yaml` : `restic_password`, `b2_account_id`, `b2_account_key`, `ntfy_topic`.
    Détails : `secrets/README.md`.
  - Alertes : ntfy (échec B2, surveillance quotidienne 12:00, rappel Proton).
  - **Prune B2 séparé** (`restic-backups-b2-prune`, 05:00) : la sauvegarde de 04:00 ne fait plus
    `forget --prune` ; le prune attend la fin de la sauvegarde, et la sauvegarde refuse d'arrêter les
    applications si un prune tourne (correctif de l'utilisateur, 10/11/2026).
- **Recyclarr** (`seedbox.recyclarr`) : profils TRaSH **français** 1080p (MULTi.VF, VOSTFR), plafonds de
  taille (séries 19 Mo/min, films 21 Mo/min), 05:30. Clés API `sonarr_api_key` / `radarr_api_key` dans sops.
- **Locanalyse** (`modules/locanalyse.nix`) : conteneur NixOS à utilisateurs privés, chargé depuis une
  archive **hors de Git** (`/var/lib/locanalyse-src/locanalyse-serveur.tar.gz`) épinglée par `narHash`.
  Ports 80/443 (+ 8443 pour ntfy). `publicHost` est inscrit dans les codes de jumelage : changer d'adresse
  = rejumeler tous les membres. [Certain] Conséquence : **`atom` ne s'évalue plus hors du serveur**
  (l'archive manque) ; `NixKS` s'évalue tant que `locanalyse.enable = false`.

## Ce qui est testé / non testé

- [Certain] `NixKS` s'évalue sans avertissement (11/11/2026, `flake.lock` de `da6dc0e`) : trois RAID 1
  (`/dev/md/boot`, `/dev/md/swap`, `/dev/md/root`), GRUB sur `/dev/sda` et `/dev/sdb`, `boot.swraid` actif.
  `atom` ne s'évalue que sur le serveur (archive Locanalyse).
- [Certain] Jusqu'au 25/10/2026, les deux machines s'évaluaient sans avertissement, options activées et désactivées ;
  `shellcheck` propre sur tous les scripts et scripts générés ; allers-retours restic et age testés
  en local.
- [Certain] **`atom` installé et démarré le 24/10/2026** (NixOS 26.05, nixpkgs `da6dc0e`,
  `flake.lock` et fichiers générés commités). Démarrage en 30 s, SSH par clé OK (clé `~/.ssh/nix`
  du poste), aucun service en échec.
- [Certain] **`NixKS` installé et démarré le 11/11/2026** (UEFI, trois RAID 1 `boot`/`swap`/`root` en
  `[UU]`, aucun service en échec, SSH vérifié par empreinte). Disques SMART sains mais **très vieux** :
  82 720 h (`sda`) et 99 988 h (`sdb`) au 11/11/2026. Les alertes RAID et SMART ne vont que dans le journal.
- [Certain] **Jamais testé en réel** : copie Proton Drive.
- Le CLI Proton Drive (`proton-drive`, ~v0.8) est un binaire précompilé (build `x64-baseline`),
  lancé via `nix-ld`. Ses options peuvent changer. [Probable] Le build « baseline » de Bun exige
  SSE4.2/POPCNT, que l'Atom n'a pas : `sauvegarde-proton` risque de planter sur l'Atom, à tester.
- [Certain] **Claude Code ne tourne pas sur l'Atom** : le CPU N2800 n'a ni AVX, ni SSE4.2, ni POPCNT
  (`grep` dans `/proc/cpuinfo` vide). Le paquet `claude-code` n'est installé que si
  `lowSpecHardware = false` (donc `NixKS`). Sur l'Atom, travailler depuis le poste.

## Avancement

- Phase 0 : faite (dépôt public `github.com/Cafeinoman/ClaudeXNixOS`, commits en
  `Cafeinoman@users.noreply.github.com`, `settings-common.nix` rempli, README corrigé ;
  `atom` et le Xeon (alors `ks3`, aujourd'hui `NixKS`) évalués avec le `flake.lock` du 24/10/2026).
- Phase 1 : `atom` installé depuis le rescue avec `TEMP_SWAP=/dev/sda3` (partition provisoire
  de 8 Go créée à la main) et `NIX_CONFIG="max-jobs = 1 / cores = 1"`.
- Phase 2 : faite (Tailscale, mosh + tmux depuis le téléphone, clé du téléphone ajoutée).
  Claude Code impossible sur l'Atom (CPU) : prévu pour `NixKS` uniquement.
- Phase 4 : seedbox active sur `atom` **sans VPN** (qBittorrent, Prowlarr, Sonarr, Radarr).
  Chaîne Prowlarr → Radarr → qBittorrent → import validée le 25/10/2026 ; lien physique
  pas encore vérifié. Corbeille des *arr : `/srv/data/media/.corbeille`. Réglages des
  applications **non sauvegardés** (seulement `migrate-app-state.sh export` à la main).
- Phase 4 bis : faite le 25/10/2026, `vpn = true` sur `atom`. Selon l'utilisateur, tout passe :
  services `proton`, `qbittorrent`, `proton-port-forward` actifs, port NAT-PMP attribué, IP
  Proton différente de celle du serveur, *arr branchés sur `192.168.15.1:8090`.
  `/var/lib/secrets/proton.conf` est hors de Git et hors sauvegarde : à redéposer après une
  réinstallation (suggestion : le passer dans sops-nix).
- Test streaming sur `atom` (25/10/2026) : SMB + VLC et Jellyfin en lecture directe OK en 1080p
  et 4K H.264. `tailscaled` ~22 % d'un fil en 1080p, ~52 % en 4K (~8,5 Mbit/s) : pas de 4K à fort
  débit possible. [Certain] Jellyfin plante parfois en SIGILL (`status=4/ILL`) dans SQLite (CPU
  sans SSE4.2/POPCNT) ; systemd le relance. Rien à corriger sur l'Atom : réglé par le serveur suivant.
- Après le 25/10/2026 (commits de l'utilisateur, sans Claude) : Seerr et Recyclarr sur `atom`
  (26-28/10), Locanalyse activé sur `atom` le 08/11 (adresse IP `37.187.126.47`, provisoire),
  prune B2 séparé et port-forward Proton silencieux pendant les sauvegardes (09-10/11).
- Phase 7 : faite le 25/10/2026 sur `atom`. restic → B2 (`b2:NixOS-save:atom`) chaque nuit à 04:00,
  première sauvegarde manuelle réussie, alerte ntfy testée. Secrets dans `secrets/atom.yaml`
  (vérifié chiffré). Pas de copie Proton sur l'Atom (CLI Bun incompatible avec le CPU).
- Déménagement vers `NixKS` (constaté le 14/11/2026, diagnostic en lecture seule) :
  - [Certain] `secrets/NixKS.yaml` en place ; `hosts/NixKS/settings.nix` active seedbox + VPN, Recyclarr,
    B2, Jellyfin, Seerr, SMB (Locanalyse et `protonCopy` désactivés). Appliqué : la configuration
    en service ne diffère du dépôt que par le commit `a3d5584` (message d'erreur de `proton-port-forward`).
  - [Certain] `nixks` dans Tailscale ; RAID `[UU]` ×3 ; `/srv` 397 Go utilisés sur 1,9 To.
  - [Certain] `proton.conf` présent (service `proton` actif, port NAT-PMP attribué à 07:21).
  - [Certain] Données copiées (`/srv/data` 423 Go, 51 fichiers de `media/` en liens physiques) et
    état d'atom importé le 14/11 à 07:20 (`migrate-app-state.sh import`, archive `…-20261114-0718`).
    Après l'import, le 403 de `proton-port-forward` a cessé. [Suppose] archives pas encore `shred`.
  - [Certain] Sauvegarde B2 de `NixKS` OK le 14/11 à 04:01, mais AVANT l'import : l'état importé
    part dans B2 la nuit suivante.
  - [Certain] **Recyclarr en échec** depuis l'import : « Quality 'Bluray-1080p': min (50.8/50.4) cannot
    be greater than preferred (17/15) » — les plafonds de `tailles` sont sous le minimum TRaSH du
    Bluray-1080p. [Probable] même échec silencieux sur `atom` depuis le 27/10.
  - Non vérifié (sudo) : IP de qBittorrent = IP Proton.

## Reste à faire

1. Phase 3 : retirer le port 22 (`modules/base.nix`) — toujours ouvert au 11/11/2026. À faire
   plutôt sur `NixKS`, après le déménagement (`rebuild-test`, vérification via Tailscale, `rebuild`).
2. Tester une **restauration** B2 une fois (README, « Restaurer »), avant d'en avoir besoin.
3. Première semaine : surveiller la console B2 (« Caps & Alerts ») et la taille du dépôt.
4. Vérifier le **lien physique** au prochain import Radarr (même inode dans `torrents/` et `media/`).
5. **`NixKS` : fin du déménagement** (étapes 1 à 5 faites au 14/11/2026) : `rebuild` pour `a3d5584`,
   corriger Recyclarr (Bluray-1080p), vérifications de l'étape 6 (IP Proton, test ntfy, interfaces web),
   Locanalyse (**nom de domaine** à choisir, archive à déposer), puis fin d'`atom` (étape 7) : couper
   sa sauvegarde B2 et supprimer `b2:NixOS-save:atom` (deux dépôts dans les 10 Go gratuits).
6. `NixKS` : envoyer les alertes RAID (`mdadm-alert`) et SMART (`smartd`) sur ntfy, une fois
   `secrets/NixKS.yaml` en place (disques de 9 et 11 ans). Envisager une sortie console série
   (`console=ttyS…`) pour diagnostiquer par SoL.
7. Décembre 2026 : passer à NixOS 26.11 (26.05 supporté jusqu'au 31/12/2026).
8. Suggestions du README : `proton.conf` dans sops-nix, plugins Jellyfin.

## Le rescue OVH de l'Atom (leçons de l'installation)

- `/` est un **rootfs (ramfs) de 3,9 Go, non swappable** : le store Nix y occupe la RAM. Pas de
  module zram. Ne pas faire `nix run github:nix-community/disko` (2ᵉ nixpkgs + documentation
  construite sur place → OOM, `sshd` tué). Le script construit `destroyFormatMount` depuis la config.
- Le bac à sable de Nix ne marche pas sur un rootfs (`pivot_root`), et un store « détourné »
  (`nixos-install --store /mnt`) l'impose : le script déplace le store sur `/mnt/nix` après disko
  et construit le système directement.
- Un swap énorme (1,8 To) consomme ~490 Mo de RAM noyau et a fait tomber le rescue : ≤ 16 Go.
- Lancer le script dans `tmux` (les coupures SSH tuent le script). `git` n'est pas toujours
  présent dans un rescue neuf : `apt-get install -y git tmux`.
- Le rescue change de clé d'hôte à chaque redémarrage, NixOS aussi au premier boot :
  `ssh-keygen -R <ip>`.
- Le Nix du rescue est mono-utilisateur dans `/home/setupuser/.nix-profile/bin` ; pour un
  `nix-collect-garbage`, le lancer en root avec ce PATH.

## Le rescue et le démarrage du KS-5 (leçons de l'installation du 11/11/2026)

- Rescue OVH : mdadm 4.2 et `HOMEHOST <ignore>` → udev ne crée pas `/dev/md/<nom>` pour les RAID
  `any:<nom>` de disko. Le script pose une règle udev provisoire. Les RAID s'assemblent en `md125-127`
  dans un ordre qui **change à chaque démarrage** : désigner un RAID par son contenu (`blkid -t TYPE=…`).
- Restes d'une tentative précédente retrouvés DANS un RAID neuf → le script fait `wipefs -a` sur chaque
  RAID avant formatage. Pas de table GPT à l'intérieur d'un RAID (le noyau du rescue ne la relisait pas) :
  trois miroirs `boot` (metadata 1.0), `swap`, `root`.
- Démarrage UEFI chez OVH : iPXE (réseau) charge le fichier `efiBootloaderPath` du serveur, réglé par
  l'API (`PUT /dedicated/server/{serviceName}`) à `\efi\boot\bootx64.efi` ; sinon repli sur rEFInd. Une
  installation manuelle ne le règle pas.
- [Certain] Le drapeau `pmbr_boot` sur le MBR protecteur empêchait iPXE et rEFInd de voir l'ESP : retiré
  à la main, et le script ne le pose plus qu'en BIOS legacy. L'étiquette FAT `EFI_SYSPART` (celle des
  installations OVH) a été posée à la main avant ; rien ne prouve qu'elle soit nécessaire.
- Console : SoL (série) et KVM (graphique) disponibles dans le manager. GRUB et le noyau n'écrivent que
  sur l'écran graphique : SoL reste muet après iPXE.

## Pièges à ne pas répéter

- Derrière un proxy qui bloque GitHub, évaluer avec
  `--override-input <nom> 'git+https://github.com/<org>/<dépôt>?shallow=1'` (ne pas modifier `flake.nix` pour ça).
- Option renommée : `documentation.man.generateCaches` → `documentation.man.cache.enable`.
- Les pages Intel ARK ne sont pas lisibles par WebFetch ; utiliser une recherche web ou technical.city.
- NixOS 26.05 est supporté jusqu'au **31/12/2026** : migrer vers 26.11 en décembre.

## Règles absolues (aussi sur l'ordinateur)

- Ne jamais lire, afficher, copier ni committer : clé privée du VPN, archives
  `app-state-*.tar.gz`, `keys.txt` age, `/run/secrets/*`, clés/jetons B2, mot de passe restic.
- Ne jamais saisir de mots de passe, clés API ou identifiants à la place de l'utilisateur ;
  lui indiquer la commande à lancer lui-même.
- Ne jamais lancer `disko` ni `install-from-rescue.sh` ailleurs que dans le rescue du bon serveur
  (efface les disques).
- Pas d'écriture publique (push, dépôt public, message) sans demande explicite.
- Un changement = un commit avec le POURQUOI dans le message. Une ligne dans `CHANGELOG.md`
  par changement système.

---

# Partie 2 — Règles pour Claude Code sur le serveur

*(S'applique quand tu tournes sur la machine NixOS, dans `~/nixos-config`.)*

Ce dépôt (`~/nixos-config`) EST la configuration du serveur. Tout ce qui n'y est pas
écrit sera perdu à la prochaine reconstruction. Lis ce fichier en début de session.

## Système (NixOS, géré par flake)
- Deux machines : `atom` et `NixKS` (`hosts/<machine>/`). Le nom de la machine courante :
  `hostname`. Les alias `rebuild*` visent automatiquement la bonne machine.
- Réglages : `settings-common.nix` (commun) et `hosts/<machine>/settings.nix`.
- Ne jamais installer de logiciel système à la main (pas de `nix-env -i`, pas de
  binaires copiés dans /usr/local). Tout changement système = modification d'un
  fichier `.nix` de ce dépôt.
- Avant de proposer un changement : `rebuild-check` (construit sans appliquer et
  montre le diff des paquets). Corriger les erreurs d'évaluation avant d'aller plus loin.
- Tu n'as pas sudo sans mot de passe. Pour appliquer (`rebuild`), demande à l'humain.
- Un changement = un commit Git avec un message qui dit POURQUOI.
- Ne jamais modifier `system.stateVersion`.
- Ne jamais toucher à `modules/disko.nix` ni aux `disks` de `hosts/*/settings.nix`
  (relancer disko efface les disques).
- Ne jamais lire, afficher, copier ni committer `/var/lib/secrets/*` (clé privée du VPN),
  ni les archives `app-state-*.tar.gz` (clés API, mots de passe des applications),
  ni `/run/secrets/*`, ni `~/.config/sops/age/keys.txt`. Les fichiers `secrets/*.yaml`
  ne se modifient qu'avec `sops`, et seulement à la demande de l'humain.
- Changements réseau / SSH / pare-feu : utiliser `rebuild-test` d'abord (non
  persistant : un redémarrage annule), et garder une session ouverte pour vérifier.

## Projets
- Les side projects vivent dans `~/projects/<nom>`, chacun avec son propre
  `flake.nix` + `.envrc` (`use flake`) pour ses dépendances. Pas de dépendance de
  projet dans la config système.
- Services de test : Docker rootless (`docker compose`), pas de service systemd
  système pour un projet expérimental.

## Journal
- Ajouter une ligne dans `CHANGELOG.md` pour chaque changement système :
  date, ce qui a changé, pourquoi, comment revenir en arrière.
