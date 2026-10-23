# Réglages communs à toutes tes machines. Les réglages propres à chaque serveur sont
# dans hosts/<machine>/settings.nix.
# Le script d'installation refuse de tourner tant qu'il reste un "CHANGE_ME".
{
  # Ton utilisateur (sudo avec mot de passe, pas de root direct).
  userName = "CHANGE_ME";

  # Ta ou tes clés SSH publiques : contenu de ~/.ssh/id_ed25519.pub
  # (sur téléphone : générée par Termius / Blink / JuiceSSH).
  sshKeys = [
    "ssh-ed25519 AAAA_CHANGE_ME ton-telephone"
  ];

  timeZone = "Europe/Paris";

  # Valeurs par défaut, remplacées machine par machine.
  swapSize = "8G";
  lowSpecHardware = false;

  seedbox = {
    enable = false;
    bazarr = false;
    lidarr = false;
    vpn = false;
  };

  # Sauvegardes (README, « Sauvegardes ») : à activer une fois les secrets créés.
  backup = {
    enable = false;
    b2Bucket = "";                   # nom de ton bucket B2 (privé)
    protonCopy = false;              # copie chiffrée vers Proton Drive, à la demande
    protonReminderDays = 30;         # rappel ntfy si pas de copie Proton depuis N jours (0 = jamais)
    protonFolder = "/my-files/backups"; # dossier Proton Drive (créé à la main une fois)
    ageRecipient = "";               # ta clé publique age (age1...), la privée reste chez toi
  };

  streaming = {
    jellyfin = false;
    seerr = false;
    navidrome = false;
    audiobookshelf = false;
    publicDomain = null;
  };
}
