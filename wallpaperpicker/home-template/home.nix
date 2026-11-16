{ username, nixgl, ... }:
{
  home.username = username;
  home.homeDirectory = "/home/${username}";

  # The Home Manager release this config was first written for. Leave it
  # as is when updating; it's not the version you run.
  home.stateVersion = "26.05";

  # Lets Home Manager update and run itself (`home-manager switch`).
  programs.home-manager.enable = true;

  # Fits Nix into a distro other than NixOS: apps from Nix show up in the
  # app launcher, and so on.
  targets.genericLinux.enable = true;

  # Graphics drivers for programs from Nix. "mesa" covers Intel, AMD and
  # nouveau. On NVIDIA's proprietary driver, use "nvidia" instead and add
  # --impure to every `home-manager switch` (it reads the installed driver's
  # version). After the distro updates that driver, reboot, then switch again.
  targets.genericLinux.nixGL = {
    packages = nixgl.packages;
    defaultWrapper = "mesa";
  };

  programs.wallpaperpicker = {
    enable = true;
    nixGL = true;           # through nixGL (above), or it never appears
    autostart = true;       # started in the background on login
    hotkey = "Meta+Space";  # opens and closes it (Plasma)

    # Every wallpaper it sets recolors the picker itself, and Plasma too: a
    # dark color scheme made from the wallpaper, replacing your Plasma color
    # scheme. "accent" keeps your scheme and only takes the accent color
    # (highlights, selection) from the wallpaper; null leaves Plasma alone.
    matugen.enable = true;
    plasmaColors = "matugen";
  };
}
