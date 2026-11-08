# Serveur de veille Locanalyse, dans un conteneur isolé (module « container » du flake Locanalyse).
#
# Seul service de ce serveur exposé à Internet (80/443, + 8443 si ntfy n'a pas de nom propre) : il tourne dans un
# conteneur à utilisateurs privés, qui ne peut joindre ni l'hôte, ni Tailscale, ni le namespace VPN.
#
# Le code Locanalyse n'est pas dans ce dépôt public : l'archive de dist/Locanalyse-Serveur (qui est un flake) est
# déposée sur le serveur et chargée par son empreinte (settings.locanalyse.narHash, recopiée du LISEZ-MOI). Pas
# d'entrée dans flake.nix : une machine sans Locanalyse n'a pas besoin de l'archive pour s'évaluer.
{ lib, settings, ... }:
let
  s = settings.locanalyse;
  # L'empreinte (base64) va dans une URL : +, / et = s'échappent.
  narHash = lib.replaceStrings [ "+" "/" "=" ] [ "%2B" "%2F" "%3D" ] s.narHash;
  locanalyse = builtins.getFlake "tarball+file://${s.archive}?narHash=${narHash}";
in
{
  imports = lib.optional s.enable locanalyse.nixosModules.container;

  # optionalAttrs, pas mkIf : désactivé, le module du conteneur n'est pas importé et ses options n'existent pas.
  config = lib.optionalAttrs s.enable {
    assertions = [
      {
        assertion = settings.streaming.publicDomain == null;
        message = "locanalyse et streaming.publicDomain veulent tous deux les ports 80/443 de l'hôte.";
      }
      {
        assertion = s.publicHost != null;
        message = "locanalyse.publicHost : nom de domaine (recommandé) ou IP publique du serveur.";
      }
    ];

    services.locanalyse-container = {
      enable = true;
      inherit (s) memoryMax;
      veille = {
        inherit (s) publicHost acmeEmail;
        ntfy.host = s.ntfyHost;
      };
    };
  };
}
