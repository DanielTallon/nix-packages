# nix-packages

Standalone, independently-installable Nix packages:

- `lgl-papercutter` — Qt6/ImageMagick wallpaper editor
- `kenku-fm` — Kenku FM

Each package is exposed on its own — installing one never pulls in the other.

## Usage

**Run without installing:**
```
nix run github:DanielTallon/nix-packages#lgl-papercutter
nix run github:DanielTallon/nix-packages#kenku-fm
```

**Install just one:**
```
nix profile install github:DanielTallon/nix-packages#kenku-fm
```

**As a flake input, per-package (what the dotfiles will do):**
```nix
inputs.nix-packages.url = "github:DanielTallon/nix-packages";

# then reference:
inputs.nix-packages.packages.${system}.kenku-fm
```

**As an overlay (pulls both into `pkgs.*`, doesn't install anything by itself):**
```nix
inputs.nix-packages.url = "github:DanielTallon/nix-packages";

nixpkgs.overlays = [ inputs.nix-packages.overlays.default ];
# now available as pkgs.lgl-papercutter / pkgs.kenku-fm anywhere in your config
```

## Status / TODO

Both `package.nix` files are placeholders — port the real derivation logic in:

- [ ] `lgl-papercutter/package.nix` ← from `~/Develop/lgl-papercutter/package.nix`
- [ ] `kenku-fm/package.nix` ← from dotfiles `modules/kenku-fm/_default.nix`

For each: swap any local/path source references for a pinned `fetchFromGitHub`
/ `fetchurl`, fill in real `version`, `hash`, `homepage`, and `license`.

Once both build cleanly (`nix build .#lgl-papercutter`, `nix build .#kenku-fm`),
update the private dotfiles to consume this repo instead of the local `path:`
input / in-tree derivation.
