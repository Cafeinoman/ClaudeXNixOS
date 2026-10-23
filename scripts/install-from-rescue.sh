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
NIXPKGS="github:NixOS/nixpkgs/nixos-26.05"
DISKO="github:nix-community/disko/latest"

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
FLAKE="$REPO_DIR#$HOST"

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
  say "Swap provisoire sur $TEMP_SWAP"
  mkswap -f "$TEMP_SWAP" && swapon "$TEMP_SWAP"
fi

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
  su - setupuser -c 'curl -fsSL https://nixos.org/nix/install | sh -s -- --no-daemon'
fi
export PATH="$NIX_BIN:$PATH"
export NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
nix --version

# Dans un dépôt Git, un flake ne voit que les fichiers suivis : on ajoute les fichiers générés.
if [[ -d "$REPO_DIR/.git" ]]; then
  git -C "$REPO_DIR" add -A
fi

say "Vérification que la configuration s'évalue AVANT de toucher au disque"
nix eval --raw "$REPO_DIR#nixosConfigurations.$HOST.config.system.build.toplevel.drvPath" >/dev/null \
  || die "la configuration ne s'évalue pas, corrige l'erreur ci-dessus. Le disque est intact."

# ---------------------------------------------------------------- 4. Disque
say "4/7 Partitionnement et formatage de ${DISKS[*]} (disko)"
# Le rescue OVH assemble parfois l'ancien RAID logiciel : on l'arrête avant d'effacer.
if command -v mdadm >/dev/null; then
  mdadm --stop --scan 2>/dev/null || true
fi

if [[ -n "${TEMP_SWAP:-}" ]]; then
  say "Préparation de disko (swap provisoire encore actif)"
  nix build --no-link "$DISKO" \
    && nix build --no-link "$REPO_DIR#nixosConfigurations.$HOST.config.system.build.destroyFormatMount" \
    || { swapoff "$TEMP_SWAP"; die "préparation de disko impossible (mémoire ?). Le disque est intact."; }
  swapoff "$TEMP_SWAP" || die "impossible de retirer le swap provisoire : redémarre le rescue."
fi
nix run "$DISKO" -- --mode destroy,format,mount --flake "$FLAKE"
mountpoint -q /mnt || die "disko n'a pas monté /mnt."
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

# ---------------------------------------------------------------- 5. Matériel
say "5/7 Détection du matériel"
nix shell "$NIXPKGS#nixos-install-tools" -c \
  nixos-generate-config --no-filesystems --root /mnt --show-hardware-config \
  > "$HOST_DIR/hardware-configuration.nix"
[[ -d "$REPO_DIR/.git" ]] && git -C "$REPO_DIR" add -A

# ---------------------------------------------------------------- 6. Installation
say "6/7 Installation de NixOS (téléchargement direct sur le disque, quelques minutes)"
nix shell "$NIXPKGS#nixos-install-tools" -c \
  nixos-install --root /mnt --flake "$FLAKE" --no-root-passwd --option sandbox false

# ---------------------------------------------------------------- 7. Finitions
say "7/7 Copie de la configuration et mot de passe de $USER_NAME"
DEST="/mnt/home/$USER_NAME/nixos-config"
mkdir -p "$(dirname "$DEST")"
cp -a "$REPO_DIR" "$DEST"
NIXOS_ENTER=(nix shell "$NIXPKGS#nixos-install-tools" -c nixos-enter --root /mnt -c)
"${NIXOS_ENTER[@]}" "chown -R $USER_NAME:users /home/$USER_NAME"

echo "Choisis le mot de passe de $USER_NAME (il servira pour sudo, pas pour SSH) :"
until "${NIXOS_ENTER[@]}" "passwd $USER_NAME"; do
  warn "échec, on recommence."
done

say "Terminé."
cat <<EOF

Il reste à faire, dans l'ordre :
  1. Sauvegarder le dépôt mis à jour (hosts/$HOST/network.nix et hardware-configuration.nix
     ont été générés) :
       cd $REPO_DIR && git commit -am "$HOST : réseau et matériel détectés" && git push
     (la copie sur le serveur est dans /home/$USER_NAME/nixos-config)
  2. Dans le manager OVH/Kimsufi : Netboot → "Disque dur", puis redémarrer le serveur.
  3. Depuis ton téléphone : ssh $USER_NAME@${ADDR4%/*}
     (supprime l'ancienne empreinte si SSH râle : ssh-keygen -R ${ADDR4%/*})

Si le serveur ne répond pas après 5 minutes : repasse en rescue, et lis la section
"Dépannage" du README.
EOF
