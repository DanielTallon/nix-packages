{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    git
    vim

  ;

  services.flatpak.enable = true;
}
