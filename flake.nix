{
    description = "Standalone Nix packages: lgl-papercutter, kenku-fm, boot-gardener, proton-wineland, nixed-error, wallpaperpicker, flow-desktop";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils";
    # OpenGL wrapper for running wallpaperpicker outside NixOS
    # (wallpaperpicker-nixgl). Only its expressions are used, built with
    # this flake's nixpkgs, so it brings in no inputs of its own.
    nixgl = {
      url = "github:nix-community/nixGL";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, nixgl }:
    flake-utils.lib.eachDefaultSystem (system:
      let
       pkgs = import nixpkgs {
        inherit system;
        config.allowUnfreePredicate = pkg: builtins.elem (nixpkgs.lib.getName pkg) [ "kenku-fm" ];
      };
       wallpaperpicker = pkgs.callPackage ./wallpaperpicker/wallpaperpicker.nix { };
       # Mesa drivers (Intel, AMD, nouveau). NVIDIA's proprietary driver needs
       # nixGL's impure auto-detection instead; see the README.
       nixGLIntel = (import "${nixgl}/default.nix" {
         inherit pkgs;
         enable32bits = false;
         enableIntelX86Extensions = system == "x86_64-linux";
       }).nixGLIntel;
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
            nixed-error = pkgs.callPackage ./nixed-error/nixed-error.nix { };
            inherit wallpaperpicker;
            # The same picker, run through nixGL, for Nix on other distros.
            wallpaperpicker-nixgl = pkgs.writeShellScriptBin "wallpaperpicker" ''
              exec ${nixGLIntel}/bin/nixGLIntel ${nixpkgs.lib.getExe wallpaperpicker} "$@"
            '';
            flow-desktop = pkgs.callPackage ./flow-desktop/flow-desktop.nix { };
        } // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
            # Steam compat tools (prebuilt upstream releases), x86_64-linux only.
            proton-wineland = pkgs.callPackage ./proton-wineland/proton-wineland.nix { };
            proton-wineland-x86_64 = pkgs.callPackage ./proton-wineland/proton-wineland.nix { variant = "x86_64"; };
        };
      }
    ) // {
      # Overlay-style consumption: add this to your own `pkgs` and all
      # packages become ordinary attributes (pkgs.lgl-papercutter, etc.).
      overlays.default = final: prev: {
        lgl-papercutter = final.callPackage ./lgl-papercutter/lgl-papercutter.nix { };
        kenku-fm = final.callPackage ./kenku-fm/kenku-fm.nix { };
        boot-gardener = final.callPackage ./boot-gardener/boot-gardener.nix { };
        nixed-error = final.callPackage ./nixed-error/nixed-error.nix { };
        wallpaperpicker = final.callPackage ./wallpaperpicker/wallpaperpicker.nix { };
        flow-desktop = final.callPackage ./flow-desktop/flow-desktop.nix { };
        proton-wineland = final.callPackage ./proton-wineland/proton-wineland.nix { };
        proton-wineland-x86_64 = final.callPackage ./proton-wineland/proton-wineland.nix { variant = "x86_64"; };
      };
    };
}
