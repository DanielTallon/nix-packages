{
  description = "Standalone Nix packages: lgl-papercutter, kenku-fm";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
       pkgs = import nixpkgs {
        inherit system;
        config.allowUnfreePredicate = pkg: builtins.elem (nixpkgs.lib.getName pkg) [ "kenku-fm" ];
      };
      in
      {
        # `nix run .#lgl-papercutter` / `nix profile install .#kenku-fm`
        # — each package is independent, installing one never pulls in the other.
        packages = {
          lgl-papercutter = pkgs.callPackage ./lgl-papercutter/package.nix { };
          kenku-fm = pkgs.callPackage ./kenku-fm/package.nix { };
        };
      }
    ) // {
      # Overlay-style consumption: add this to your own `pkgs` and both
      # packages become ordinary attributes (pkgs.lgl-papercutter, pkgs.kenku-fm).
      overlays.default = final: prev: {
        lgl-papercutter = final.callPackage ./lgl-papercutter/package.nix { };
        kenku-fm = final.callPackage ./kenku-fm/package.nix { };
      };
    };
}
