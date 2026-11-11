# Généré par scripts/install-from-rescue.sh le 2026-11-11 à partir du mode rescue.
{ ... }:
{
  networking.useDHCP = false;
  networking.useNetworkd = true;

  systemd.network.networks."10-wan" = {
    matchConfig.MACAddress = "a4:bf:01:24:f9:dd";
    address = [ "54.36.110.44/24" "2001:41d0:700:132c::1/128" ];
    routes = [
      { Gateway = "54.36.110.254"; GatewayOnLink = true; }
      { Gateway = "2001:41d0:700:13ff:ff:ff:ff:ff"; GatewayOnLink = true; }
    ];
    linkConfig.RequiredForOnline = "routable";
  };

  networking.nameservers = [ "1.1.1.1" "9.9.9.9" ];
}
