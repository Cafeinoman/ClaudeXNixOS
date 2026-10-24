#!/usr/bin/env bash
# Installe NixOS sur un Kimsufi depuis le mode rescue OVH (Debian, en RAM).
#
# Usage (en root, dans le rescue) :
#   cd nixos-config && bash scripts/install-from-rescue.sh <machine>
#   <machine> = un dossier de hosts/ : atom ou ks3
#
# Étapes : vérifications → réseau détecté → Nix installé dans le rescue
#          → disques EFFACÉS et partitionnés (disko) → NixOS installé → mot de passe.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${1:-}"

say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERREUR : %s\033[0m\n' "$*" >&2; exit 1; }

if [[ -z "$HOST" || ! -f "$REPO_DIR/hosts/$HOST/settings.nix" ]]; then
  echo "Usage : bash scripts/install-from-rescue.sh <machine>"
  echo "Machines disponibles : $(cd "$REPO_DIR/hosts" && echo */ | tr -d /)"
  exit 1
fi
HOST_DIR="$REPO_DIR/hosts/$HOST"
HOST_SETTINGS="$HOST_DIR/settings.nix"
COMMON="$REPO_DIR/settings-common.nix"

setting() { # lit une valeur texte simple dans settings-common.nix
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$COMMON" | head -n1
}

# ---------------------------------------------------------------- 1. Vérifications
say "1/7 Vérifications — installation de la machine « $HOST »"
[[ $EUID -eq 0 ]] || die "lance ce script en root (tu l'es par défaut dans le rescue)."
[[ -f "$REPO_DIR/flake.nix" ]] || die "flake.nix introuvable dans $REPO_DIR."
if grep -q CHANGE_ME "$COMMON"; then
  die "settings-common.nix contient encore des CHANGE_ME (utilisateur, clé SSH)."
fi

USER_NAME="$(setting userName)"
# Liste des disques : les chaînes "/dev/..." entre "disks = [" et "];"
mapfile -t DISKS < <(sed -n '/^[[:space:]]*disks[[:space:]]*=/,/\]/p' "$HOST_SETTINGS" \
  | sed 's/#.*//' | grep -o '"/dev/[^"]*"' | tr -d '"')
(( ${#DISKS[@]} >= 1 )) || die "aucun disque trouvé dans 'disks' de hosts/$HOST/settings.nix."

for d in "${DISKS[@]}"; do
  [[ -b "$d" ]] || { lsblk -d -o NAME,SIZE,MODEL; die "disque $d introuvable : corrige 'disks' dans hosts/$HOST/settings.nix."; }
  if grep -qs "^$d" /proc/mounts; then
    die "$d est monté. Es-tu bien dans le mode rescue et pas sur le système installé ?"
  fi
done

echo
lsblk -o NAME,SIZE,TYPE,MODEL,MOUNTPOINT
echo
if (( ${#DISKS[@]} >= 2 )); then
  echo "Mode : RAID 1 logiciel (miroir) sur ${DISKS[*]}"
else
  echo "Mode : disque unique ${DISKS[0]}"
fi
warn "Ces disques vont être ENTIÈREMENT EFFACÉS : ${DISKS[*]}"
[[ -d /sys/firmware/efi ]] && echo "Mode de démarrage détecté : UEFI" || echo "Mode de démarrage détecté : BIOS legacy"
echo "(la configuration gère les deux, c'est juste pour information)"
read -r -p "Tape EFFACER pour continuer : " answer
[[ "$answer" == "EFFACER" ]] || die "abandon, rien n'a été modifié."

# Rescue à court de RAM (le store Nix y est en mémoire, pas de zram) : TEMP_SWAP=/dev/sdaN
# donne un swap provisoire sur une PETITE partition du disque à effacer (le noyau réserve
# ~1 octet de RAM par page de 4 Ko de swap : 1,8 To de swap, c'est ~490 Mo perdus). Actif
# dès maintenant pour couvrir l'évaluation, retiré juste avant que disko n'efface le disque.
if [[ -n "${TEMP_SWAP:-}" ]]; then
  [[ -b "$TEMP_SWAP" ]] || die "TEMP_SWAP=$TEMP_SWAP n'est pas un périphérique bloc."
  on_target=0
  for d in "${DISKS[@]}"; do [[ "$TEMP_SWAP" == "$d"* ]] && on_target=1; done
  (( on_target )) || die "TEMP_SWAP doit être une partition d'un disque listé dans 'disks' (il sera effacé)."
  (( $(blockdev --getsize64 "$TEMP_SWAP") <= 16 * 1024 ** 3 )) || die "TEMP_SWAP dépasse 16 Go : le swap consommerait de la RAM. Utilise une partition de ~8 Go."
  if swapon --show=NAME --noheadings | grep -qx "$(readlink -f "$TEMP_SWAP")"; then
    say "Swap provisoire déjà actif sur $TEMP_SWAP"
  else
    say "Swap provisoire sur $TEMP_SWAP"
    mkswap -f "$TEMP_SWAP" >/dev/null || die "mkswap $TEMP_SWAP a échoué."
    swapon "$TEMP_SWAP" || die "swapon $TEMP_SWAP a échoué."
  fi
fi
undo_temp_swap() { if [[ -n "${TEMP_SWAP:-}" ]]; then swapoff "$TEMP_SWAP" 2>/dev/null || true; fi; }

# ---------------------------------------------------------------- 2. Réseau
say "2/7 Détection du réseau (valeurs du rescue = valeurs du serveur)"
IFACE="$(ip -4 route show default | awk '{print $5; exit}')"
GW4="$(ip -4 route show default | awk '{print $3; exit}')"
ADDR4="$(ip -4 -o addr show dev "$IFACE" scope global | awk '{print $4; exit}')"
MAC="$(cat "/sys/class/net/$IFACE/address")"
ADDR6="$(ip -6 -o addr show dev "$IFACE" scope global 2>/dev/null | awk '{print $4; exit}' || true)"
GW6="$(ip -6 route show default 2>/dev/null | awk '{print $3; exit}' || true)"
[[ -n "$IFACE" && -n "$GW4" && -n "$ADDR4" && -n "$MAC" ]] || die "impossible de lire la config réseau (ip a / ip r)."

echo "Interface $IFACE  MAC $MAC"
echo "IPv4 $ADDR4  passerelle $GW4"
[[ -n "$ADDR6" ]] && echo "IPv6 $ADDR6  passerelle ${GW6:-aucune}" || echo "IPv6 : non configurée dans le rescue (à ajouter plus tard si besoin)"

V6_ADDR=""; V6_ROUTE=""
if [[ -n "$ADDR6" && -n "$GW6" ]]; then
  V6_ADDR=" \"$ADDR6\""
  V6_ROUTE="
      { Gateway = \"$GW6\"; GatewayOnLink = true; }"
fi

cat > "$HOST_DIR/network.nix" <<EOF
# Généré par scripts/install-from-rescue.sh le $(date -I) à partir du mode rescue.
{ ... }:
{
  networking.useDHCP = false;
  networking.useNetworkd = true;

  systemd.network.networks."10-wan" = {
    matchConfig.MACAddress = "$MAC";
    address = [ "$ADDR4"$V6_ADDR ];
    routes = [
      { Gateway = "$GW4"; GatewayOnLink = true; }$V6_ROUTE
    ];
    linkConfig.RequiredForOnline = "routable";
  };

  networking.nameservers = [ "1.1.1.1" "9.9.9.9" ];
}
EOF

# ---------------------------------------------------------------- 3. Nix dans le rescue
say "3/7 Installation de Nix dans le rescue (en RAM, disparaît au redémarrage)"
if ! command -v git >/dev/null || ! command -v curl >/dev/null || ! command -v xz >/dev/null; then
  apt-get update -qq && apt-get install -y -qq git curl xz-utils
fi

# Le rescue vit en RAM : sur une machine à 4 Go, l'évaluation de NixOS est juste.
# On ajoute 2 Go de swap compressé en mémoire si le noyau du rescue le permet.
free -m
if ! grep -q zram /proc/swaps && modprobe zram 2>/dev/null; then
  if zdev="$(zramctl --find --size 2G --algorithm lz4 2>/dev/null)"; then
    mkswap "$zdev" >/dev/null && swapon -p 100 "$zdev" && echo "Swap zram activé sur $zdev"
  fi
fi

NIX_BIN="/home/setupuser/.nix-profile/bin"
if [[ ! -x "$NIX_BIN/nix" ]]; then
  id setupuser >/dev/null 2>&1 || useradd -m -s /bin/bash setupuser
  getent group nixbld >/dev/null || groupadd -g 30000 nixbld
  id nixbld >/dev/null 2>&1 || useradd -u 30000 -g nixbld -G nixbld -M -s /usr/sbin/nologin nixbld
  mkdir -p /etc/nix
  # Le bac à sable de Nix ne fonctionne pas sur le tmpfs du rescue.
  cat > /etc/nix/nix.conf <<'EOF'
sandbox = false
experimental-features = nix-command flakes
build-users-group = nixbld
EOF
  mkdir -p /nix && chmod 0755 /nix && chown setupuser /nix
  su - setupuser -c 'curl -fsSL https://nixos.org/nix/install | sh -s -- --no-daemon --no-channel-add'
fi
export PATH="$NIX_BIN:$PATH"
export NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
nix --version

# Dans un dépôt Git, un flake ne voit que les fichiers suivis : on ajoute les fichiers générés.
# flake.lock est créé AVANT le `git add` : non suivi, il serait ignoré et recréé à chaque
# commande, avec le risque de versions différentes d'une étape à l'autre.
nix flake lock "$REPO_DIR" || { undo_temp_swap; die "nix flake lock a échoué. Le disque est intact."; }
if [[ -d "$REPO_DIR/.git" ]]; then
  git -C "$REPO_DIR" add -A
fi

CFG="$REPO_DIR#nixosConfigurations.$HOST"
say "Vérification que la configuration s'évalue AVANT de toucher au disque"
nix eval --raw "$CFG.config.system.build.toplevel.drvPath" >/dev/null \
  || { undo_temp_swap; die "la configuration ne s'évalue pas, corrige l'erreur ci-dessus. Le disque est intact."; }

# ---------------------------------------------------------------- 4. Disque
say "4/7 Préparation, puis partitionnement de ${DISKS[*]} (disko)"
# Pas de `nix run github:nix-community/disko` : ce CLI apporte son propre nixpkgs et des
# outils dont la documentation se construit sur place, ce qui a saturé la RAM du rescue.
# Le script de disko construit depuis notre configuration (même nixpkgs que le système)
# est exactement ce que le CLI exécuterait. Tout est construit AVANT d'effacer quoi que ce soit.
DISKO_OUT="$(nix build --no-link --print-out-paths "$CFG.config.system.build.destroyFormatMount")" \
  || { undo_temp_swap; die "construction du script disko impossible. Le disque est intact."; }
if ! GENCONF_OUT="$(nix build --no-link --print-out-paths "$CFG.config.system.build.nixos-generate-config")" \
  || ! ENTER_OUT="$(nix build --no-link --print-out-paths "$CFG.pkgs.nixos-enter")"; then
  undo_temp_swap; die "construction des outils d'installation impossible. Le disque est intact."
fi
GENERATE_CONFIG="$GENCONF_OUT/bin/nixos-generate-config"
NIXOS_ENTER_BIN="$ENTER_OUT/bin/nixos-enter"
mapfile -t DISKO_BIN < <(compgen -G "$DISKO_OUT/bin/*")
if (( ${#DISKO_BIN[@]} != 1 )) || [[ ! -x "$GENERATE_CONFIG" || ! -x "$NIXOS_ENTER_BIN" ]]; then
  undo_temp_swap; die "outils introuvables après construction. Le disque est intact."
fi

# Le rescue OVH assemble parfois l'ancien RAID logiciel : on l'arrête avant d'effacer.
if command -v mdadm >/dev/null; then
  mdadm --stop --scan 2>/dev/null || true
fi
if [[ -n "${TEMP_SWAP:-}" ]]; then
  swapoff "$TEMP_SWAP" || die "impossible de retirer le swap provisoire : redémarre le rescue. Le disque est intact."
fi
# EFFACER a déjà été confirmé plus haut.
"${DISKO_BIN[0]}" --yes-wipe-all-disks || die "disko a échoué (le disque est peut-être à moitié effacé)."
mountpoint -q /mnt || die "disko n'a pas monté /mnt."
mountpoint -q /mnt/nix || die "disko n'a pas monté /mnt/nix."
# Le swap soulage la RAM pour la suite de l'installation (s'il n'est pas déjà actif).
while read -r sw; do
  swapon "$sw" 2>/dev/null || true
done < <(blkid -t TYPE=swap -o device)
# Certains BIOS anciens refusent de démarrer un disque GPT en mode legacy si le MBR
# protecteur n'a pas le drapeau "boot". Sans effet ailleurs.
for d in "${DISKS[@]}"; do
  parted -s "$d" disk_set pmbr_boot on || warn "impossible de poser pmbr_boot sur $d"
done
if (( ${#DISKS[@]} >= 2 )); then
  echo "État du RAID (la synchronisation initiale continue en arrière-plan, plusieurs heures) :"
  cat /proc/mdstat
fi

# Le rescue tourne sur un rootfs (ramfs) : le store Nix y occupe la RAM sans pouvoir être
# swappé, et le bac à sable de Nix ne peut pas y faire pivot_root. Or nixos-install
# construit avec --store /mnt (store « détourné »), ce qui impose ce bac à sable : les
# constructions locales échoueraient. On déplace donc le store sur le disque cible et on
# construit le système directement dedans, puis on installe le chargeur comme nixos-install.
say "Store Nix déplacé sur le disque cible (/mnt/nix)"
cp -a /nix/. /mnt/nix/
chown -R root:root /mnt/nix
chown root:nixbld /mnt/nix/store && chmod 1775 /mnt/nix/store
mount --bind /mnt/nix /nix
# La copie en RAM est masquée par le bind : on la supprime via une vue non récursive de
# la racine du rescue, seulement si cette vue est bien sur un autre périphérique que /nix.
if mkdir -p /tmp/rescue-root && mount --bind / /tmp/rescue-root; then
  if [[ "$(stat -c %d /tmp/rescue-root/nix)" != "$(stat -c %d /nix)" ]]; then
    rm -rf /tmp/rescue-root/nix/store /tmp/rescue-root/nix/var
  fi
  umount /tmp/rescue-root || true
else
  warn "copie du store en RAM non libérée (sans gravité, le swap disque est actif)."
fi
free -m

# ---------------------------------------------------------------- 5. Matériel
say "5/7 Détection du matériel"
"$GENERATE_CONFIG" --no-filesystems --root /mnt --show-hardware-config \
  > "$HOST_DIR/hardware-configuration.nix"
[[ -d "$REPO_DIR/.git" ]] && git -C "$REPO_DIR" add -A

# ---------------------------------------------------------------- 6. Installation
say "6/7 Construction de NixOS (téléchargement direct sur le disque, plusieurs minutes)"
nix build --profile /nix/var/nix/profiles/system "$CFG.config.system.build.toplevel" \
  || die "construction du système impossible. Le disque est partitionné et /nix pointe dessus :
  ne relance pas le script tel quel, note l'erreur ; relancer seulement cette commande :
  nix build --profile /nix/var/nix/profiles/system '$CFG.config.system.build.toplevel'"
mkdir -p /mnt/etc && chmod 0755 /mnt/etc && touch /mnt/etc/NIXOS
say "Installation du chargeur de démarrage (GRUB)"
NIXOS_INSTALL_BOOTLOADER=1 "$NIXOS_ENTER_BIN" --root /mnt -- \
  /run/current-system/bin/switch-to-configuration boot \
  || die "installation du chargeur impossible."

# ---------------------------------------------------------------- 7. Finitions
say "7/7 Copie de la configuration et mot de passe de $USER_NAME"
DEST="/mnt/home/$USER_NAME/nixos-config"
mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
cp -a "$REPO_DIR" "$DEST"
# Le PATH du rescue n'existe pas dans le système installé : on donne le sien.
IN_TARGET="export PATH=/run/current-system/sw/bin;"
NIXOS_ENTER=("$NIXOS_ENTER_BIN" --root /mnt -c)
"${NIXOS_ENTER[@]}" "$IN_TARGET chown -R $USER_NAME:users /home/$USER_NAME"

echo "Choisis le mot de passe de $USER_NAME (il servira pour sudo, pas pour SSH) :"
until "${NIXOS_ENTER[@]}" "$IN_TARGET passwd $USER_NAME"; do
  warn "échec, on recommence."
done
sync

say "Terminé."
cat <<EOF

Il reste à faire, dans l'ordre :
  1. Dans le manager OVH/Kimsufi : Netboot → "Disque dur".
  2. Ici : reboot   (redémarrage propre, plutôt que le bouton du manager)
  3. Depuis ton poste : ssh $USER_NAME@${ADDR4%/*}
     (supprime l'ancienne empreinte si SSH râle : ssh-keygen -R ${ADDR4%/*})
  4. Rapatrier les fichiers générés dans le dépôt (flake.lock, hosts/$HOST/network.nix,
     hosts/$HOST/hardware-configuration.nix) : la copie est dans ~/nixos-config sur le serveur.

Si le serveur ne répond pas après 5 minutes : repasse en rescue, et lis la section
"Dépannage" du README.
EOF
