# Secrets chiffrés (sops-nix)

Les fichiers `secrets/<machine>.yaml` sont **chiffrés** : ils peuvent aller dans Git.
Seuls ta clé personnelle et la machine concernée peuvent les ouvrir.

## Une seule fois : ta clé personnelle

Sur le serveur (ou ton PC), dans ton dossier personnel :

```bash
nix shell nixpkgs#age -c age-keygen -o ~/.config/sops/age/keys.txt
```

La ligne `# public key: age1...` est ta clé publique : mets-la à la place de
`age1CHANGE_ME_cle_admin` dans `.sops.yaml`. **Copie le fichier `keys.txt` dans ton
gestionnaire de mots de passe** (Proton Pass par exemple) : sans lui, tu ne pourras plus
modifier les secrets si le serveur disparaît.

## Pour chaque machine, après son installation

```bash
# Sur la machine elle-même :
nix shell nixpkgs#ssh-to-age -c sh -c 'ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub'
```

Mets le résultat (`age1...`) à la place de `age1CHANGE_ME_cle_atom` (ou `_ks3`) dans
`.sops.yaml`.

## Créer le fichier de secrets

```bash
cd ~/nixos-config
nix shell nixpkgs#sops -c sops secrets/atom.yaml     # ou ks3.yaml
```

Contenu à saisir (l'éditeur s'ouvre ; à l'enregistrement, sops chiffre) :

```yaml
restic_password: une-longue-phrase-de-passe-aleatoire   # garde-la aussi dans ton gestionnaire !
b2_account_id: 00xxxxxxxxxxxxx0000000001                 # keyID de la clé d'application B2
b2_account_key: K00xxxxxxxxxxxxxxxxxxxxxxxxxx            # applicationKey (affichée une seule fois)
ntfy_topic: un-nom-long-et-impossible-a-deviner-8f3k2   # sujet ntfy pour les alertes
```

Le **mot de passe restic** est indispensable pour restaurer : sans lui, la sauvegarde B2
est illisible, y compris pour toi. Garde-le hors du serveur.

Après avoir modifié `.sops.yaml` (nouvelle machine), mets à jour les fichiers existants :

```bash
nix shell nixpkgs#sops -c sops updatekeys secrets/atom.yaml
```
