{ pkgs, ... }:
{
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "no";

  environment.systemPackages = [ pkgs.git ];
}
