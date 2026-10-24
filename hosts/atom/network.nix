# Généré par scripts/install-from-rescue.sh le 2026-10-24 à partir du mode rescue.
{ ... }:
{
  networking.useDHCP = false;
  networking.useNetworkd = true;

  systemd.network.networks."10-wan" = {
    matchConfig.MACAddress = "00:22:4d:ae:18:cd";
    address = [ "37.187.126.47/24" "2001:41d0:a:f72f::1/128" ];
    routes = [
      { Gateway = "37.187.126.254"; GatewayOnLink = true; }
      { Gateway = "2001:41d0:a:f7ff:ff:ff:ff:ff"; GatewayOnLink = true; }
    ];
    linkConfig.RequiredForOnline = "routable";
  };

  networking.nameservers = [ "1.1.1.1" "9.9.9.9" ];
}
