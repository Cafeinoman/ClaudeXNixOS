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
- streaming (Jellyfin, Seerr, Navidrome, Audiobookshelf), seulement sur le KS-3 Xeon.

Contraintes : budget serveur ≤ **30 € TTC/mois**, 2 To suffisent, commande du KS-3
**uniquement s'il est en stock en France** (Sydney exclu : 300 Mbit/s, quota 5 To puis
10 Mbit/s, latence).

## Deux machines, un dépôt

| Machine | Matériel | Rôle |
|---|---|---|
| `atom` (déjà louée) | KS-3 ancien : Atom N2800, 4 Go, 1 × 2 To, pas de VT-x, pas de transcodage | rodage de la config, dev, seedbox ; **pas de streaming** |
| `ks3` (pas encore commandée) | KS-3 : Xeon E3-1245 v5, 32 Go, 2 × 2 To en RAID 1 mdadm, iGPU HD P530 (HEVC 8 bits seulement) | serveur principal : dev + seedbox + streaming |

- Pour `ks3` : vérifier avec `lspci` que l'iGPU n'est pas désactivé par OVH avant de
  compter sur le transcodage matériel.
- Une tâche planifiée « Alerte stock KS-3 France » (id `trig_01V4YpaVQet8pWAiu7zGQefZ`)
  surveille le stock via l'API OVH. **À supprimer après la commande du KS-3.**
  Le script équivalent : `scripts/ks3-stock-check.sh` (code retour 0 = disponible).

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

## Ce qui est testé / non testé

- [Certain] Les deux machines s'évaluent sans avertissement, options activées et désactivées ;
  `shellcheck` propre sur tous les scripts et scripts générés ; allers-retours restic et age testés
  en local.
- [Certain] **Jamais testé en réel** : démarrage sur un vrai Kimsufi, envoi réel vers B2 ou
  Proton, tunnel VPN réel, iGPU du KS-3. Le premier boot reste le moment de vérité.
- Le CLI Proton Drive (`proton-drive`, ~v0.8) est un binaire précompilé (build `x64-baseline`
  pour les CPU sans AVX2, ce qui est le cas de l'Atom), lancé via `nix-ld`. Ses options peuvent changer.

## Phase 0 — ce qu'il reste à faire (travail sur l'ordinateur)

Références : `README.md`, section « Phase 0 ». Rien ne touche encore au serveur.

État constaté : le dépôt n'est **pas encore initialisé dans Git**, il n'y a **pas de
`flake.lock`**, et `settings-common.nix` contient toujours `CHANGE_ME` (le script d'installation
refuse de tourner tant qu'il en reste).

À faire, dans l'ordre :
1. [ ] **Sauvegarder** ce qui compte sur l'Atom actuel (il sera effacé).
2. [ ] `git init`, premier commit, dépôt GitHub/GitLab. Public possible (aucun secret dans le
   dépôt : clé SSH *publique* seulement). Privé : prévoir un jeton en lecture pour cloner
   depuis le rescue.
3. [ ] **Clé SSH du téléphone** (ed25519, générée dans Termius/Blink) : demander la partie
   *publique* à l'utilisateur. Ne jamais lui demander ni accepter une clé privée.
4. [ ] Remplir `settings-common.nix` : `userName`, `sshKeys`.
5. [ ] Vérifier `hosts/atom/settings.nix` : `disks = [ "/dev/sda" ]` à confirmer avec `lsblk`
   dans le rescue (le disque sera **effacé**).
6. [ ] **Générer et committer `flake.lock`** (`nix flake lock`), sur une machine avec Nix et accès
   à GitHub. Le travail précédent a été fait derrière un proxy qui bloquait GitHub, donc aucun
   verrou n'existe. Sans verrou, l'installation prendrait les versions du jour.
7. [ ] Évaluer les deux machines avant d'aller plus loin :
   `nix eval .#nixosConfigurations.atom.config.system.build.toplevel.drvPath` (idem `ks3`),
   puis `shellcheck scripts/*.sh`.
8. [ ] Corriger les textes périmés du README (voir plus bas).

Après la phase 0 (hors périmètre de cette session) : phase 1 = installation de l'Atom depuis
le rescue ; phase 7 = sauvegardes, qui exigent compte B2 (plafonds à 0 $), clé age,
sujet ntfy, `secrets/atom.yaml` ; puis seedbox + VPN ; puis commande du KS-3 quand il est
en stock en France, et migration avec `migrate-app-state.sh`. **Lancer `sauvegarde-proton`
avant tout déménagement Atom → KS-3.**

## Incohérences connues à corriger dans le README

- Phase 0, tableau des disques : cite un « Xeon E3-1230 v6 (16 Go) ». Le KS-3 visé est le
  **Xeon E3-1245 v5, 32 Go**.
- Les sections « Budget RAM sur le Xeon (16 Go) » et « Limites du KS-3 » mélangent les noms :
  « KS-3 » y désigne l'**Atom** (machine `atom`), pas le `ks3`. Renommer, et mettre le budget
  RAM du Xeon à 32 Go.
- Suggestion n°2 (fichier Proton VPN dans sops-nix) et Recyclarr / Tdarr : pas encore faits.

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
- Deux machines : `atom` et `ks3` (`hosts/<machine>/`). Le nom de la machine courante :
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
