{
  description = "Standalone Nix packages: lgl-papercutter, kenku-fm, limine-gardener";

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
        # `nix run .#limine-gardener` also works directly -- no separate
        # `apps` output needed, since its meta.mainProgram matches its bin.
        # — each package is independent, installing one never pulls in the other.
        packages = {
            lgl-papercutter = pkgs.callPackage ./lgl-papercutter/lgl-papercutter.nix { };
            kenku-fm = pkgs.callPackage ./kenku-fm/kenku-fm.nix { };
            limine-gardener = pkgs.callPackage ./limine-gardener/limine-gardener.nix { };
        };
      }
    ) // {
      # Overlay-style consumption: add this to your own `pkgs` and all three
      # packages become ordinary attributes (pkgs.lgl-papercutter, etc.).
      overlays.default = final: prev: {
        lgl-papercutter = final.callPackage ./lgl-papercutter/lgl-papercutter.nix { };
        kenku-fm = final.callPackage ./kenku-fm/kenku-fm.nix { };
        limine-gardener = final.callPackage ./limine-gardener/limine-gardener.nix { };
      };
    };
}
