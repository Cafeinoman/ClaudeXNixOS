# Serveur Kimsufi sous NixOS — plan de travail

Objectif : un serveur reconstruit à l'identique à partir de ce dépôt, utilisable
depuis un téléphone pour Claude Code, des side projects, une seedbox et du streaming.

```
settings-common.nix           ← réglages communs (utilisateur, clés SSH) : à remplir
flake.nix                     ← point d'entrée : deux machines, atom et ks3
hosts/atom/settings.nix       ← Atom N2800 : rodage, dev, seedbox (pas de streaming)
hosts/ks3/settings.nix        ← KS-3 Xeon 1245 v5 : serveur principal, RAID 1
hosts/<machine>/network.nix   ← généré à l'installation (IP fixe lue dans le rescue)
hosts/<machine>/hardware-configuration.nix  ← généré à l'installation
modules/system.nix            ← socle commun (démarrage, imports)
modules/disko.nix             ← partitionnement : 1 disque, ou RAID 1 mdadm sur 2 disques
modules/backup.nix            ← sauvegardes : restic → B2 (nuit), archive chiffrée → Proton Drive (à la demande)
.sops.yaml, secrets/          ← secrets chiffrés (sops-nix) : mots de passe, clés B2, alertes
modules/base.nix              ← utilisateur, SSH, pare-feu, Tailscale, mosh, entretien
modules/dev.nix               ← nix-ld, Docker rootless, direnv, outils de dev
modules/media.nix             ← groupe "media" et arborescence /srv/data
modules/seedbox.nix           ← Servarr : qBittorrent, Prowlarr, Sonarr, Radarr (+ options)
modules/streaming.nix         ← Jellyfin, Seerr, Navidrome, Audiobookshelf, accès public
modules/proton-vpn.nix        ← qBittorrent confiné derrière Proton VPN + redirection de port
scripts/install-from-rescue.sh  ← installation : bash scripts/install-from-rescue.sh <machine>
scripts/migrate-app-state.sh  ← déménage l'état des *arr d'une machine à l'autre
scripts/ks3-stock-check.sh    ← vérifie le stock du KS-3 en France
CLAUDE.md                     ← règles que Claude Code lit sur le serveur
CHANGELOG.md                  ← journal des changements système
```

---

## Phase 0 — Préparation (30 min, rien ne touche au serveur)

1. **Sauvegarde** tout ce qui compte sur le serveur actuel : il sera effacé.
2. **Mets ce dossier dans un dépôt Git** (GitHub/GitLab). Il ne contient aucun secret
   (une clé SSH *publique* et une IP), il peut être public ; s'il est privé, prévois
   un jeton d'accès en lecture pour le cloner depuis le rescue.
3. **Clé SSH du téléphone** : génère une clé ed25519 dans ton client SSH
   (Termius, Blink…), copie la partie publique.
4. **Remplis `settings-common.nix`** (`userName`, `sshKeys`), puis vérifie
   `hosts/<machine>/settings.nix` pour la machine à installer :

   | Serveur | `disks` | `lowSpecHardware` |
   |---|---|---|
   | `atom` : KS-3 ancien modèle (Atom N2800, 4 Go, 1 × 2 To) | `[ "/dev/sda" ]` | `true` |
   | `ks3` : KS-3 Xeon E3-1245 v5 (32 Go, 2 × 2 To) | `[ "/dev/sda" "/dev/sdb" ]` | `false` |

   Avec deux disques, la config crée un **RAID 1 logiciel** (miroir mdadm) : 2 To
   utiles, et le serveur continue de tourner (et redémarre seul) si un disque meurt.

### Pourquoi pas « Bring Your Own Image » / « Bring Your Own Linux » ?

Le manager les propose pour le KS-3 (Atom comme Xeon), mais être proposé ne lève pas les contraintes
de la documentation OVH. Les deux modes écrivent une image qcow2 sur le disque, et
sur l'Atom (4 Go) ils coincent :
- l'image doit faire **moins que la RAM moins 3 Gio**, soit moins de 1 Gio sur l'Atom ;
- BYOLinux impose **une seule partition** et **pas de sous-volumes btrfs**, donc pas de
  swap séparé ni de découpage `/nix`, `/home`, `/srv` ;
- les deux exigent **cloud-init** dans l'image, à configurer côté NixOS ;
- il faudrait construire l'image sur une autre machine équipée de Nix.

Le mode rescue reste plus simple et garde la config disko telle quelle.

Sur le **Xeon (32 Go)**, la limite de taille ne gêne plus, mais BYOI **ne gère pas
le RAID logiciel** à l'installation (documentation OVH) : il écrit l'image sur un seul
disque. Le mode rescue reste donc la voie à suivre pour avoir le RAID 1.

## Phase 1 — Installation (45 min)

1. Manager Kimsufi → **Netboot → Rescue** (rescue-customer), puis redémarrer.
   Le mot de passe root du rescue arrive par e-mail.
2. Connexion : `ssh root@IP_DU_SERVEUR`
3. Vérifie le nom des disques : `lsblk`. S'ils ne correspondent pas à `disks` dans
   `hosts/<machine>/settings.nix` (ex. `/dev/nvme0n1`), corrige le dépôt, puis re-clone.
4. Lance l'installation :
   ```bash
   apt-get update && apt-get install -y git
   git clone https://github.com/TOI/nixos-config.git
   cd nixos-config
   bash scripts/install-from-rescue.sh atom     # ou ks3
   ```
   Le script vérifie tout et évalue la configuration **avant** d'effacer le disque.
   Il demande de taper `EFFACER`, puis le mot de passe de ton utilisateur (pour sudo).
5. **Récupère les fichiers générés** (`network.nix`, `hardware-configuration.nix`,
   `flake.lock`) : `git commit` + `git push` depuis le rescue, ou copie-les plus tard
   depuis `~/nixos-config` sur le serveur installé.
6. Manager → **Netboot → Disque dur**, puis redémarrer.
7. Depuis le téléphone : `ssh TON_USER@IP_DU_SERVEUR`.
8. **Avec RAID 1** : la synchronisation initiale des deux disques dure plusieurs
   heures (`cat /proc/mdstat`). Le serveur est utilisable pendant ce temps, juste
   plus lent sur les disques.

## Phase 2 — Mise en service (30 min)

1. **Tailscale** : `sudo tailscale up` puis ouvre le lien affiché pour lier le serveur
   à ton compte. Installe Tailscale sur le téléphone. Le serveur devient joignable
   sous son nom (`atom` ou `ks3`), même port 22 fermé.
2. **Session persistante depuis le téléphone** :
   `mosh TON_USER@atom -- tmux new -A -s main` (ou `@ks3`)
   (mosh survit aux changements de réseau ; tmux garde la session si tu fermes l'app.)
3. **Claude Code** : installe-le avec l'installeur natif décrit dans la documentation
   officielle (docs.claude.com). Il fonctionne grâce à `nix-ld`, déjà activé.
   Lance-le une première fois dans `~/nixos-config` : il lira `CLAUDE.md`.
4. **Premier test du cycle de modification** : ajoute un paquet dans
   `modules/base.nix`, puis `rebuild-check`, `rebuild`, `git commit`.

## Phase 3 — Durcissement (optionnel, après 1 semaine sans souci)

- Retire `22` de `allowedTCPPorts` dans `modules/base.nix` : SSH ne sera plus joignable
  que via Tailscale. **Contrepartie** : si Tailscale tombe, seul le mode rescue te
  permet de revenir. Applique avec `rebuild-test` d'abord, vérifie depuis le téléphone
  via Tailscale, puis `rebuild`.

## Phase 4 — Seedbox Servarr (quand le socle est stable)

**Avant d'activer** : OVH transmet les plaintes pour atteinte au droit d'auteur au
titulaire du serveur et peut le suspendre. Sans VPN, les pairs BitTorrent voient l'IP
du serveur. Pour autre chose que du contenu libre, fais d'abord la **phase 4 bis**
(Proton VPN), puis active la seedbox avec `vpn = true` dès le premier `rebuild`.

### Activation

`seedbox.enable = true;` dans `hosts/<machine>/settings.nix` (et `bazarr` / `lidarr` si voulu), puis
`rebuild-check` et `rebuild`. Le premier `rebuild` télécharge environ 1 Go.

### Phase 4 bis — Proton VPN pour qBittorrent

qBittorrent tourne alors dans un espace réseau isolé dont la seule sortie est le
tunnel WireGuard de Proton. Si le VPN tombe, qBittorrent n'a plus de réseau du tout :
aucune fuite possible par l'IP du serveur. Les *arr, eux, restent sur la connexion
normale du serveur.

**Prérequis** : une offre Proton VPN **payante**. L'offre gratuite (incluse dans tout
compte Proton) n'autorise ni le P2P ni la redirection de port.

1. **Fichier WireGuard** : sur account.protonvpn.com → Downloads → WireGuard
   configuration :
   - plateforme **GNU/Linux** ;
   - options VPN : coche **NAT-PMP (Port Forwarding)** ;
   - serveur : un serveur **P2P** (icône double flèche), proche de la France ;
   - « Create » puis télécharge le fichier `.conf`.
   Il contient une clé privée : ne le mets **jamais** dans Git.
2. **Dépôt sur le serveur** (par SFTP depuis le téléphone, ou `scp`), puis :
   ```bash
   sudo install -D -m 600 -o root -g root ~/proton.conf /var/lib/secrets/proton.conf
   rm ~/proton.conf
   ```
   Ce fichier n'est pas dans la sauvegarde Git : en cas de réinstallation, il faudra
   le redéposer (ou en générer un nouveau chez Proton).
3. **Activation** : `vpn = true;` dans `hosts/<machine>/settings.nix`, puis `rebuild-check` et `rebuild`.
4. **qBittorrent** (en plus des réglages de l'étape 1 ci-dessous) :
   - Web UI → « Contourner l'authentification pour les clients sur localhost » doit
     être **coché** : c'est ainsi que le service de redirection règle le port.
   - Ne touche pas au port d'écoute : il est fixé automatiquement (voir ci-dessous).
5. **Vérifications** :
   ```bash
   systemctl status proton qbittorrent proton-port-forward
   journalctl -u proton-port-forward -n 20   # « Port attribué par Proton : 5xxxx »
   sudo ip netns exec proton curl -s https://ipinfo.io/ip   # doit afficher une IP Proton
   curl -s https://ipinfo.io/ip                             # IP du serveur (différente)
   ```
   Dans qBittorrent, l'icône de connexion en bas doit passer au vert après quelques minutes.

**Comment marche la redirection de port** : Proton attribue un port public à la
demande (NAT-PMP) pour 60 secondes. Le service `proton-port-forward` renouvelle la
demande toutes les 45 secondes, ouvre ce port dans le pare-feu du tunnel et le
transmet à qBittorrent s'il a changé. Sans ce mécanisme, tu téléchargerais, mais tu
partagerais mal, et le ratio s'effondrerait.

**Différences avec la configuration sans VPN** :
- Sonarr/Radarr joignent qBittorrent à l'adresse **`192.168.15.1`** (et non `localhost`),
  **avec** l'identifiant et le mot de passe de l'interface web.
- L'interface web reste à `http://<machine>:8090` via Tailscale. Un filtre de pare-feu
  empêche toute autre interface de l'atteindre.
- Le port `50000` n'est plus ouvert sur l'IP du serveur.

**En cas de souci** :
- `proton.service` en échec : fichier absent ou mal formé, ou serveur Proton
  injoignable. Regarde `journalctl -u proton`.
- `natpmpc a échoué` en boucle : le serveur choisi n'est pas P2P, ou l'option NAT-PMP
  n'a pas été cochée. Génère un nouveau fichier sur un autre serveur P2P.
- Le tunnel fonctionnait puis s'arrête : la configuration a pu être révoquée côté
  Proton. Génère-en une nouvelle et remplace le fichier, puis
  `sudo systemctl restart proton qbittorrent proton-port-forward`.

`<machine>` = `atom` ou `ks3` selon le serveur (noms Tailscale).

| Service | Rôle | Adresse (via Tailscale) |
|---|---|---|
| qBittorrent | client torrent | http://<machine>:8090 |
| Prowlarr | gère les indexeurs, les pousse aux *arr | http://<machine>:9696 |
| Sonarr | séries | http://<machine>:8989 |
| Radarr | films | http://<machine>:7878 |
| Bazarr (option) | sous-titres | http://<machine>:6767 |
| Jellyfin (option) | lecture, sans transcodage | http://<machine>:8096 |

### Configuration initiale, dans cet ordre (30 min)

1. **qBittorrent** : le mot de passe temporaire de l'interface est dans le journal :
   `journalctl -u qbittorrent | grep -i password`. Puis dans Options :
   - Téléchargements → Chemin par défaut : `/srv/data/torrents`
   - Téléchargements → Mode de gestion des torrents par défaut : **Automatique**
   - Connexion → port : `50000` (déjà ouvert dans le pare-feu). **Avec le VPN** : ne
     rien changer, le port est réglé automatiquement ; décoche UPnP / NAT-PMP.
   - Web UI → change le mot de passe ; coche « Contourner l'authentification
     pour les clients sur localhost » (les *arr tournent sur la même machine)
   - BitTorrent → limites de ratio si tu le souhaites
2. **Sonarr** puis **Radarr** : à la première ouverture, crée l'authentification
   (formulaire). Puis :
   - Settings → Media Management → Root Folder : `/srv/data/media/tv`
     (Radarr : `/srv/data/media/movies`). Laisse « Use Hardlinks » coché.
   - Settings → Download Clients → qBittorrent : hôte `localhost`, port `8090`,
     catégorie `tv` (Radarr : `movies`). **Avec le VPN** : hôte `192.168.15.1`,
     avec l'identifiant et le mot de passe de qBittorrent.
   - Settings → General → copie la **clé API** (pour Prowlarr).
3. **Prowlarr** : Settings → Apps → ajoute Sonarr et Radarr (URL
   `http://localhost:8989` / `http://localhost:7878`, clés API de l'étape 2).
   Ajoute ensuite tes indexeurs dans Prowlarr seulement : il les pousse aux *arr.
4. **Bazarr** (option) : Settings → Sonarr/Radarr avec leurs clés API, puis langues.
5. **Lidarr** (option, http://<machine>:8686) : Root Folder `/srv/data/media/music`, client
   qBittorrent comme Sonarr avec la catégorie `music`, puis ajoute-le dans Prowlarr.

Ces réglages vivent dans `/var/lib/<service>`, pas dans Git : voir « Sauvegardes ».

### Pourquoi cette arborescence

Tout est sous `/srv/data`, sur le même système de fichiers : Sonarr/Radarr rangent
les fichiers par **lien physique**. Un épisode présent à la fois dans `torrents/`
(pour continuer à partager) et dans `media/` (rangé, renommé) n'occupe l'espace
qu'une seule fois. Les services partagent le groupe `media`, et ton utilisateur en
fait partie : tu peux gérer les fichiers en SFTP.

### Réglages des applications : ce qui est dans Git, ce qui ne l'est pas

| Quoi | Où | Comment c'est protégé |
|---|---|---|
| Quels services tournent, ports, chemins, VPN, droits | `*.nix` | **Git** |
| Réglages faits dans les interfaces (indexeurs, profils, clés API, comptes, historique) | bases SQLite dans `/var/lib/<service>` | **Archive** (`migrate-app-state.sh`), plus tard sauvegarde chiffrée |
| Profils de qualité Sonarr/Radarr | (à venir) fichier YAML Recyclarr | **Git**, une fois Recyclarr ajouté |

Pourquoi les bases ne vont pas dans Git : ce sont des fichiers binaires qui changent
à chaque synchronisation (Git stockerait une copie complète à chaque commit, sans
diff lisible), qu'il faut arrêter le service pour copier proprement, et qui
contiennent des secrets en clair (clés API, cookies d'indexeurs).

**Déménagement Atom → KS-3** :
1. Sur `ks3`, active les mêmes services que sur `atom` dans `hosts/ks3/settings.nix`,
   puis `rebuild`.
2. Sur `atom` : `sudo bash scripts/migrate-app-state.sh export`
3. `scp ~/app-state-*.tar.gz ks3:` (via Tailscale)
4. Sur `ks3` : `sudo bash scripts/migrate-app-state.sh import ~/app-state-atom-….tar.gz`
5. Données, si utile : `rsync -aP atom:/srv/data/ /srv/data/` (depuis `ks3`).
6. Supprime l'archive des deux côtés (`shred -u`).

Les chemins sont identiques sur les deux machines (`/srv/data/...`, adresse de
qBittorrent) : rien à reconfigurer après l'import.

## Phase 5 — Entretien

**Chaque mois (10 min)** :
```bash
cd ~/nixos-config
nix flake update        # nouvelles versions des paquets (correctifs de sécurité)
rebuild-check           # construit sans appliquer + liste des changements
rebuild                 # applique
git commit -am "Mise à jour mensuelle" && git push
```

**En décembre 2026** : NixOS 26.05 n'est plus maintenu après le 31/12/2026.
Remplace `nixos-26.05` par `nixos-26.11` dans `flake.nix` (et dans le script),
lis les notes de version, puis le cycle ci-dessus. Ne touche pas à `system.stateVersion`.

**Revenir en arrière** (le serveur répond encore) :
`sudo nixos-rebuild switch --rollback`

**Santé des disques** :
- `sudo smartctl -H /dev/sda` (et `/dev/sdb`) : « PASSED » attendu.
- RAID : `cat /proc/mdstat` doit montrer `[UU]`. `[U_]` = un disque est sorti du RAID ;
  `journalctl -t mdadm-alert` dit lequel. Le serveur continue de tourner : ouvre un
  ticket OVH pour remplacer le disque, puis reconstruis le miroir (`mdadm --add`).

---

## Phase 6 — Streaming

### Ce que le matériel permet

Le point qui décide de tout : le **Xeon E3-1230 v6 n'a pas de puce graphique** (les
modèles « 5 » de la gamme, comme le 1245 v6, en ont une ; le 1230 non). Donc **pas de
transcodage matériel** (Quick Sync). Vérification sur le serveur : `ls /dev/dri`
doit être vide ou absent.

Conséquences :
- **Lecture directe** (le client lit le fichier tel quel) : aucune charge CPU, autant
  de flux que la bande passante le permet. C'est le mode à viser.
- **Transcodage logiciel** (le serveur réencode à la volée) : 4 cœurs / 8 threads
  tiennent environ **1 à 2 flux 1080p H.264**. Un transcodage **4K HEVC est hors de
  portée**.
- **Bande passante sortante** : elle limite le nombre de flux simultanés hors de
  chez toi. Un film 1080p en lecture directe demande 8 à 20 Mbit/s ; vérifie le débit
  de ton offre Kimsufi.
- **Atom** : lecture directe uniquement, aucun transcodage.

**Stratégie pour éviter le transcodage** :
1. Dans Sonarr/Radarr, préfère les sorties **1080p H.264 (x264), audio AAC/AC3**,
   lisibles partout. Recyclarr (voir Suggestions) peut appliquer ces profils.
2. Utilise des clients qui lisent presque tout en direct : **Jellyfin Media Player**
   (PC), **Findroid** ou l'app Jellyfin avec lecteur ExoPlayer/mpv (Android),
   **Swiftfin** ou **Infuse** (iPhone, Apple TV), **Jellyfin pour Android TV**.
   Les navigateurs web sont les pires clients : ils déclenchent souvent un transcodage.
3. Sous-titres : préfère le format **SRT** ; les sous-titres image (PGS) incrustés
   forcent un transcodage.

### Les services

| Service | Rôle | Adresse (via Tailscale) | Réglage |
|---|---|---|---|
| Jellyfin | films, séries | http://<machine>:8096 | `streaming.jellyfin` |
| Seerr | demandes « à la Netflix » | http://<machine>:5055 | `streaming.seerr` |
| Navidrome | musique (Subsonic) | http://<machine>:4533 | `streaming.navidrome` |
| Audiobookshelf | livres audio, podcasts | http://<machine>:13378 | `streaming.audiobookshelf` |

### Configuration initiale

1. **Jellyfin** : assistant au premier lancement (compte admin, langue). Puis :
   - Bibliothèques : Films → `/srv/data/media/movies`, Séries → `/srv/data/media/tv`.
   - Tableau de bord → Lecture → Transcodage : accélération matérielle **Aucune**
     (pas de GPU) ; coche « Limiter le transcodage » (throttling) pour ménager le CPU.
   - Crée un compte par personne, avec un débit maximal distant (ex. 20 Mbit/s).
2. **Seerr** : se connecte à Jellyfin (http://localhost:8096), puis à Sonarr et Radarr
   avec leurs clés API. Les demandes approuvées partent directement en téléchargement.
3. **Navidrome** : crée le compte admin au premier accès. La musique est lue dans
   `/srv/data/media/music` (alimentée par Lidarr ou déposée en SFTP). Apps :
   **Symfonium** (Android), **Substreamer** / **Amperfy** (iPhone), **Feishin** (PC).
4. **Audiobookshelf** : crée le compte admin, puis deux bibliothèques :
   `/srv/data/media/audiobooks` et `/srv/data/media/podcasts`. Les podcasts se
   téléchargent tout seuls. Apps officielles Android et iPhone, avec reprise de lecture.

### Accès sans Tailscale (TV connectée, famille)

Tailscale existe sur Android TV, Apple TV et téléphones, mais pas sur les TV Samsung
(Tizen) ni LG (webOS). Deux possibilités :

- **Recommandé** : un boîtier Android TV ou une Apple TV avec Tailscale branché sur la TV.
- **Exposer Jellyfin sur Internet** : `streaming.publicDomain = "jellyfin.mondomaine.fr";`
  Il faut un nom de domaine dont l'enregistrement DNS pointe vers l'IP du serveur.
  Caddy obtient alors un certificat HTTPS automatiquement (ports 80 et 443 ouverts).
  Dans Jellyfin → Réseau, ajoute `127.0.0.1` aux « proxys connus ».
  **Risque** : Jellyfin devient attaquable depuis Internet. Il a eu des failles
  permettant d'accéder à certaines ressources sans être connecté. Mots de passe forts,
  pas de compte sans mot de passe, et mises à jour mensuelles impératives (phase 5).
  Seul Jellyfin est exposé ; Seerr et les autres restent derrière Tailscale.

---

## Phase 7 — Sauvegardes (B2 gratuit + Proton Drive)

| | B2 (principal) | Proton Drive (secondaire) |
|---|---|---|
| Fréquence | automatique, chaque nuit vers 4 h | **à la demande** : `sauvegarde-proton` |
| Outil | restic : chiffré, ne renvoie que les changements | archive tar chiffrée avec age |
| Historique | 7 jours, 4 semaines, 3 mois | 4 dernières archives |
| Qui peut relire | quiconque a le mot de passe restic | seulement ta clé age privée |
| Contenu | état des applications (`/var/lib/...`), `/var/lib/secrets`, ton dossier personnel (sans `node_modules`, caches, images Docker, fichiers > 200 Mo) | idem |

Les applications sont arrêtées quelques minutes pendant la copie (bases SQLite au repos).

### B2 : configuration stricte pour un coût nul

Tarifs vérifiés le 22/10/2026 : 10 Go de stockage gratuits, transactions de classe A
(envois) gratuites, 2 500 transactions de classe B et 2 500 de classe C gratuites par
jour, téléchargements gratuits dans la limite prévue. **Le garde-fou n'est pas le
calcul, ce sont les plafonds** : à 0 $, B2 **refuse** toute opération au-delà du gratuit
(erreur 403) au lieu de la facturer. La sauvegarde échoue alors, et l'alerte te prévient.

1. Crée un compte sur backblaze.com (B2 Cloud Storage). Choisis la région
   **EU Central** à l'inscription (impossible à changer ensuite). **N'ajoute pas de carte
   bancaire.**
2. **Caps & Alerts** → Edit Caps → pour **chaque** catégorie (Storage, Download
   Bandwidth, Class B, Class C ; la classe A est toujours gratuite) : décoche « No Cap »,
   mets **0**, valide. Vérifie que chaque ligne affiche bien 0,00 $. Tu recevras un
   e-mail à 75 % et 100 % de chaque plafond.
3. **Buckets** → Create a Bucket : nom unique (ex. `ks-sauvegardes-a8f3`), **Private**,
   Object Lock désactivé.
4. Sur ce bucket → **Lifecycle Settings** → « **Keep only the last version of the
   file** ». Indispensable : sinon les données supprimées par restic restent stockées
   en « versions cachées » et grignotent les 10 Go gratuits.
5. **Application Keys** → Add a New Application Key : accès **à ce bucket seulement**,
   Read and Write. Note le `keyID` et l'`applicationKey` (affichée une seule fois).
6. Mets le nom du bucket dans `settings-common.nix` (`backup.b2Bucket`).

Consommation attendue, à surveiller dans « Caps & Alerts » la première semaine :

| Poste | Estimation | Limite gratuite |
|---|---|---|
| Stockage | quelques centaines de Mo à 2 Go (historique compris) | 10 Go |
| Classe C (listes) | quelques dizaines par nuit | 2 500 / jour |
| Classe B (lectures) | quelques dizaines par nuit (le cache local évite de relire) | 2 500 / jour |

Si un jour le stockage approche 7,5 Go (e-mail « 75 % »), réduis l'historique
(`pruneOpts` dans `modules/backup.nix`) ou exclus un dossier.

### Proton Drive : préparation

1. **Ta clé age personnelle** : si tu as suivi `secrets/README.md`, tu en as déjà une
   (`~/.config/sops/age/keys.txt`). Sa clé publique (`age1...`) va dans
   `backup.ageRecipient`. Les archives Proton ne se déchiffrent qu'avec cette clé : si
   ton compte Proton fuitait, elles resteraient illisibles.
2. **Compte** : la session du serveur donne accès à **tout** le Drive du compte, pas
   seulement au dossier de sauvegarde. Le plus prudent est un compte Proton gratuit
   dédié aux sauvegardes (4 archives tiennent largement dans l'espace gratuit) ; ton
   compte principal fonctionne aussi, en acceptant ce risque.
3. Dans l'app Proton Drive, crée le dossier `backups/<machine>` (ex. `backups/atom`)
   à la racine de « Mes fichiers ».

### Activation

1. Crée les secrets : `secrets/README.md` (clés age, `sops secrets/<machine>.yaml`).
2. Installe l'app **ntfy** sur ton téléphone et abonne-toi au sujet choisi pour
   `ntfy_topic` : c'est là qu'arrivent les alertes.
3. `settings-common.nix` : `backup.enable = true;` (et `protonCopy = true;` + `ageRecipient`
   pour Proton), puis `rebuild-check`, `rebuild`, commit.
4. Premier essai B2 : `sudo systemctl start restic-backups-b2`, puis
   `journalctl -u restic-backups-b2 -n 30` et `sudo restic-b2 snapshots`.
5. Proton, une seule fois :
   ```bash
   # Binaire officiel : sur proton.me/download/drive/cli, copie le lien « Linux x64 baseline »
   # (la version standard plante sur l'Atom, qui n'a pas AVX2).
   sauvegarde-proton install 'LIEN_COPIÉ'
   sauvegarde-proton login     # ouvre l'URL affichée sur ton téléphone
   ```

### La copie Proton, à la demande

```bash
sauvegarde-proton           # archive, chiffre et envoie (les applications s'arrêtent quelques minutes)
sauvegarde-proton login     # si la session Proton a expiré
```

Bons moments pour la lancer : avant une grosse modification (mise à jour NixOS, nouveau
service), avant le déménagement vers le KS-3, et au moins une fois par mois. La
commande vérifie d'abord la session Proton : si elle a expiré, elle s'arrête **avant**
d'arrêter les applications et te dit de te reconnecter. Les 4 dernières archives sont
conservées.

### Alertes

- Échec de la sauvegarde B2 → notification ntfy immédiate.
- Chien de garde chaque jour à midi : alerte si la dernière réussite B2 a plus de 36 h
  (timer arrêté, plafond B2 atteint…).
- Rappel (priorité normale, au plus une fois par semaine) si la dernière copie Proton
  date de plus de 30 jours. Réglable avec `backup.protonReminderDays` (0 = jamais).

### Restaurer (à tester une fois, avant d'en avoir besoin)

```bash
# B2 : lister puis restaurer un dossier
sudo restic-b2 snapshots
sudo restic-b2 restore latest --target /tmp/restauration --include /var/lib/sonarr
# Proton : télécharger l'archive depuis l'app, puis
age -d -i ~/.config/sops/age/keys.txt atom-AAAAMMJJ.tar.gz.age | tar -tzf - | head
```

À garder **hors du serveur**, dans ton gestionnaire de mots de passe : le mot de passe
restic, ta clé age (`keys.txt`), l'identifiant B2. Sans eux, les sauvegardes sont
illisibles, y compris pour toi.

## Dépannage : le serveur ne répond plus

Kimsufi n'offre pas d'écran distant : impossible de choisir une génération dans le
menu GRUB. Tout passe par le mode rescue.

```bash
# Dans le rescue, avec UN disque :
ROOT=/dev/disk/by-partlabel/disk-main-root
BOOT=/dev/disk/by-partlabel/disk-main-ESP
# ... ou avec le RAID 1 (deux disques) :
mdadm --assemble --scan
ROOT=/dev/disk/by-id/md-name-any:system-part2
BOOT=/dev/md/boot

mount -o subvol=@root "$ROOT" /mnt
mount -o subvol=@nix  "$ROOT" /mnt/nix
mount "$BOOT" /mnt/boot

# Voir pourquoi le dernier démarrage a échoué :
journalctl -D /mnt/var/log/journal -b -1 -p err

# Revenir à une génération précédente (liste, puis choisir N) :
ls -l /mnt/nix/var/nix/profiles/
# (Nix doit être installé dans le rescue : relancer l'étape 3 du script)
nixos-enter --root /mnt -c "/nix/var/nix/profiles/system-N-link/bin/switch-to-configuration boot"
```

Causes probables, dans l'ordre :
1. **Réseau** : MAC, IP ou passerelle mal détectées → corriger `hosts/<machine>/network.nix`.
2. **Mode de démarrage / RAID** : certains Kimsufi attendent un RAID ou un mode
   particulier. Le schéma hybride BIOS+UEFI couvre la plupart des cas.
3. Un changement récent → revenir à la génération précédente (ci-dessus).

## Budget RAM sur le Xeon (32 Go)

Tout activer (seedbox complète + VPN + quatre services de streaming) consomme
environ 3 à 4 Go, Claude Code et deux ou trois side projects compris. Un transcodage
Jellyfin ajoute 0,5 à 1 Go. Il reste de la marge, y compris pour des machines
virtuelles : contrairement à l'Atom, le Xeon gère VT-x.

## Limites de l'Atom (machine `atom`) à garder en tête

- **Pas de VT-x** : pas de machines virtuelles (KVM). Les conteneurs Docker fonctionnent.
- **CPU lent** : un `rebuild` prend plusieurs minutes, et toute compilation depuis les
  sources est à éviter. Reste sur la branche stable, qui est presque entièrement en
  cache binaire.
- **4 Go de RAM**, estimation (à vérifier avec `btop` une fois en service) :

  | Poste | RAM approx. |
  |---|---|
  | Système, SSH, Tailscale | 0,4 Go |
  | qBittorrent + Prowlarr + Sonarr + Radarr | 0,8 à 1 Go |
  | Claude Code | 0,3 à 0,5 Go |
  | Un side project (Node, Python, petit conteneur) | 0,2 à 0,5 Go |
  | Bazarr / Jellyfin (options) | +0,25 / +0,4 Go |

  Avec le socle Servarr, il reste de la marge. Avec tout activé et un projet lourd,
  le système passera sur le swap zram : plus lent, mais pas de plantage.
- **Disque dur** : premières installations de dépendances (npm, Docker) lentes.

## Suggestions (pas encore dans la config)

Classées par utilité pour toi :

1. (Fait : sauvegardes B2 + Proton Drive, phase 7.)
2. **Fichier Proton VPN dans sops-nix** — sops-nix est maintenant en place pour les
   sauvegardes ; le fichier WireGuard de Proton pourrait y passer aussi, pour ne plus le
   redéposer à la main après une réinstallation.
3. (Fait : VPN Proton pour qBittorrent, phase 4 bis.)
4. **Recyclarr** — applique automatiquement à Sonarr/Radarr les profils de qualité
   recommandés par TRaSH Guides, dont des profils « compatibles lecture directe »
   (H.264, pas de HEVC 4K) : c'est le levier n°1 contre le transcodage sans GPU.
   Le module NixOS existe. À ajouter une fois les clés API connues (après sops-nix).
5. **Prétranscodage nocturne** (Tdarr ou Unmanic, en conteneur) — convertit la nuit
   les fichiers problématiques (HEVC, sous-titres PGS) en formats lisibles partout.
   Coûteux en CPU et en temps, mais le Xeon peut tourner la nuit. Utile seulement si
   les profils de qualité ne suffisent pas.
6. **Jellyfin : plugins** — « Intro Skipper » (saute les génériques), « Playback
   Reporting » (statistiques). À installer depuis le catalogue intégré de Jellyfin.

À éviter : **FlareSolverr** sur l'Atom (Chromium embarqué, trop lourd ; acceptable
sur le Xeon si un indexeur l'exige), **Readarr** (plus maintenu), le transcodage
4K, quel que soit le serveur.

## Ce qui n'a pas été testé

La configuration a été évaluée avec succès (NixOS 26.05 ; profil par défaut, profil
`atom` avec tout activé, profil `ks3` (Xeon) RAID 1 avec tout activé et Jellyfin public ; aucun
avertissement), le script d'installation et le service de redirection de port
passent `shellcheck`. Un
`nix build --dry-run` confirme que tous les logiciels viennent du cache binaire
(seuls les fichiers de configuration sont construits sur place). Elle n'a **pas** été
démarrée sur un vrai Kimsufi : le premier démarrage reste le moment de vérité.
