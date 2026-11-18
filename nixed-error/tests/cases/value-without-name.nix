{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    # --- Gaming ---
    protonplus
    steamtinkerlaunch
    xdotool
  ];

    wine
  services.flatpak.enable = true;
  services.packagekit.enable = false;
}
