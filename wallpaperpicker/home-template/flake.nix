# Home Manager for one user on a distro other than NixOS (PikaOS, Fedora,
# Arch, ...), set up with wallpaperpicker as in my own config: started on
# login, Meta+Space opens it, and every wallpaper it sets recolors the
# picker and Plasma. Made with:
#
#   nix flake init -t github:DanielTallon/nix-packages#wallpaperpicker-home
#
# Change `username` below, check home.nix, then see the README's
# "Home Manager on other distros" for the first switch.
{
  description = "Home Manager with wallpaperpicker";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Plasma settings from Home Manager (the shortcut and color scheme).
    plasma-manager = {
      url = "github:nix-community/plasma-manager";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };

    # Lets programs from Nix find the distro's graphics drivers.
    nixgl = {
      url = "github:nix-community/nixGL";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Not following nixpkgs on purpose: the picker is then the exact build
    # from nix-packages, and is downloaded from its Cachix cache rather than
    # rebuilt.
    nix-packages.url = "github:DanielTallon/nix-packages";
  };

  outputs = { nixpkgs, home-manager, plasma-manager, nixgl, nix-packages, ... }:
    let
      system = "x86_64-linux";
      username = "CHANGEME"; # your login name (run `whoami`)
    in
    {
      homeConfigurations.${username} = home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgs.legacyPackages.${system};
        extraSpecialArgs = { inherit username nixgl; };
        modules = [
          plasma-manager.homeModules.plasma-manager
          nix-packages.homeModules.wallpaperpicker
          ./home.nix
        ];
      };
    };
}
