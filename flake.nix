{
    description = "Standalone Nix packages: lgl-papercutter, kenku-fm, boot-gardener, vkd3d-proton-w3rt, proton-ge-w3rt, proton-wineland";

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
        # `nix run .#boot-gardener` also works directly -- no separate
        # `apps` output needed, since its meta.mainProgram matches its bin.
        # — each package is independent, installing one never pulls in the other.
        packages = {
            lgl-papercutter = pkgs.callPackage ./lgl-papercutter/lgl-papercutter.nix { };
            kenku-fm = pkgs.callPackage ./kenku-fm/kenku-fm.nix { };
            boot-gardener = pkgs.callPackage ./boot-gardener/boot-gardener.nix { };
        } // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") (let
            # Windows DLLs for Proton (Witcher 3 RT workaround), cross-built with mingw.
            vkd3d-proton-w3rt = pkgs.pkgsCross.mingwW64.callPackage ./vkd3d-proton-w3rt/vkd3d-proton-w3rt.nix {
              wine = pkgs.wineWow64Packages.stable; # native wine for widl; must not come via cross splicing
            };
          in {
            inherit vkd3d-proton-w3rt;
            # Ready-to-use Steam compat tool: GE-Proton11-7 with those DLLs swapped in.
            proton-ge-w3rt = pkgs.callPackage ./proton-ge-w3rt/proton-ge-w3rt.nix { inherit vkd3d-proton-w3rt; };
            proton-wineland = pkgs.callPackage ./proton-wineland/proton-wineland.nix { };
            proton-wineland-x86_64 = pkgs.callPackage ./proton-wineland/proton-wineland.nix { variant = "x86_64"; };

          });
      }
    ) // {
      # Overlay-style consumption: add this to your own `pkgs` and all
      # packages become ordinary attributes (pkgs.lgl-papercutter, etc.).
      overlays.default = final: prev: {
        lgl-papercutter = final.callPackage ./lgl-papercutter/lgl-papercutter.nix { };
        kenku-fm = final.callPackage ./kenku-fm/kenku-fm.nix { };
        boot-gardener = final.callPackage ./boot-gardener/boot-gardener.nix { };
        proton-ge-w3rt = final.callPackage ./proton-ge-w3rt/proton-ge-w3rt.nix { };
        proton-wineland = final.callPackage ./proton-wineland/proton-wineland.nix { };
        proton-wineland-x86_64 = final.callPackage ./proton-wineland/proton-wineland.nix { variant = "x86_64"; };
        vkd3d-proton-w3rt = final.pkgsCross.mingwW64.callPackage ./vkd3d-proton-w3rt/vkd3d-proton-w3rt.nix {
          wine = final.wineWow64Packages.stable;
        };
      };
    };
}
