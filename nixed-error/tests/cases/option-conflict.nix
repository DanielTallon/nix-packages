{ ... }:
{
  imports = [ { networking.hostName = "laptop"; } ];
  networking.hostName = "desktop";
}
