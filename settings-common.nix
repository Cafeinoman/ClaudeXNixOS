# Réglages communs à toutes tes machines. Les réglages propres à chaque serveur sont
# dans hosts/<machine>/settings.nix.
# Le script d'installation refuse de tourner tant qu'un marqueur de valeur à remplir y figure.
{
  # Ton utilisateur (sudo avec mot de passe, pas de root direct).
  userName = "fdelalleau";

  # Ta ou tes clés SSH publiques : contenu de ~/.ssh/id_ed25519.pub
  # (sur téléphone : générée par Termius / Blink / JuiceSSH).
  sshKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN8oba0QsLg5iTo9N9bHsxwsMahqbHb0FiyoLsd0qYsK poste"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO76KEnw/mb326hRzN0jzFwD/W85cVuHSbHXw53lz5XI telephone"
  ];

  timeZone = "Europe/Paris";

  # Valeurs par défaut, remplacées machine par machine.
  swapSize = "8G";
  lowSpecHardware = false;

  # Console série du noyau, lisible par SoL (Serial over LAN) dans le manager OVH, par exemple
  # "ttyS0,115200n8". null = écran (KVM) seulement. L'écran reste la console principale.
  serialConsole = null;

  seedbox = {
    enable = false;
    bazarr = false;
    lidarr = false;
    vpn = false;
    recyclarr = false; # profils de qualité TRaSH pour Sonarr/Radarr (clés API dans secrets/<machine>.yaml)
  };

  # Sauvegardes (README, « Sauvegardes ») : à activer une fois les secrets créés.
  backup = {
    enable = false;
    b2Bucket = "NixOS-save";         # bucket B2 privé ; un dépôt restic par machine (b2:NixOS-save:<machine>)
    protonCopy = false;              # copie chiffrée vers Proton Drive, à la demande
    protonReminderDays = 30;         # rappel ntfy si pas de copie Proton depuis N jours (0 = jamais)
    protonFolder = "/my-files/backups"; # dossier Proton Drive (créé à la main une fois)
    ageRecipient = "age1gqlz67qlc86qw3e50dvkk97th34phaw53txecv6sc9ugt049mexqllmckt"; # ta clé age publique (la privée : keys.txt, gestionnaire de mots de passe)
  };

  # Serveur de veille Locanalyse, dans un conteneur isolé (modules/locanalyse.nix). Seul service exposé à Internet.
  locanalyse = {
    enable = false;
    publicHost = null;    # nom (recommandé) ou IP : inscrit dans les codes de jumelage, le changer = tout rejumeler
    ntfyHost = null;      # null : ntfy sur le port 8443 de publicHost
    acmeEmail = null;
    # Archive dist/Locanalyse-Serveur déposée sur le serveur (hors Git : le code n'est pas public), sous ce nom fixe.
    archive = "/var/lib/locanalyse-src/locanalyse-serveur.tar.gz";
    narHash = null;       # « Empreinte Nix » du LISEZ-MOI de l'archive : fixe la version déployée
    memoryMax = "3G";     # plafond mémoire du conteneur entier
  };

  streaming = {
    jellyfin = false;
    seerr = false;
    navidrome = false;
    audiobookshelf = false;
    smb = false;            # partage SMB en lecture seule de /srv/data/media (VLC, Kodi…), via Tailscale
    publicDomain = null;
  };
}
