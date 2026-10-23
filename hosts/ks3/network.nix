# EXEMPLE — ce fichier est réécrit par scripts/install-from-rescue.sh
# avec les vraies valeurs lues dans le mode rescue (IP, passerelle, adresse MAC).
# Config statique : on ne dépend pas du DHCP d'OVH.
{ ... }:
{
  networking.useDHCP = false;
  networking.useNetworkd = true;

  systemd.network.networks."10-wan" = {
    # On identifie la carte par son adresse MAC : insensible au nommage eth0/enp*.
    matchConfig.MACAddress = "00:00:00:00:00:00";
    address = [ "192.0.2.10/24" ];
    routes = [
      { Gateway = "192.0.2.254"; GatewayOnLink = true; }
    ];
    linkConfig.RequiredForOnline = "routable";
  };

  networking.nameservers = [ "1.1.1.1" "9.9.9.9" ];
}
