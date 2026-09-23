# nix-packages

Standalone, independently-installable Nix packages, packaged for personal
use and shared here in case they're useful to anyone else:

- **[`lgl-papercutter`](./lgl-papercutter)** — [LGL Papercutter](https://github.com/linuxgamerlife/lgl-papercutter), a Qt6/ImageMagick wallpaper editor for Linux. Pinned to `v0.3.0`, MIT licensed.
- **[`kenku-fm`](./kenku-fm)** — [Kenku FM](https://www.kenku.fm/), an offline-capable text-to-speech and soundboard app for tabletop audio. Built from upstream's `.deb` release. You can check out their GitHub [here](https://github.com/owlbear-rodeo/kenku-fm). Kenku-FM is proprietary/unfree.
- **[`boot-gardener`](https://github.com/DanielTallon/nix-packages/blob/main/boot-gardener)** — Boot Gardener, a bash (`jq` + `fzf`) tool for NixOS to pick, pin, prune, harvest, or garbage-collect boot-menu generations on Limine, systemd-boot, or GRUB, plus a rescue mode for a full `/boot` partition. Own project, MIT licensed.

Each package is exposed on its own — installing or building one never pulls in the other.

## Usage

**Run without installing:**
```sh
nix run github:DanielTallon/nix-packages#lgl-papercutter
nix run github:DanielTallon/nix-packages#kenku-fm
nix run github:DanielTallon/nix-packages#boot-gardener
```
**Run without installing, and without flakes enabled:**
```sh
nix run github:DanielTallon/nix-packages#lgl-papercutter
nix run --extra-experimental-features "nix-command flakes" github:DanielTallon/nix-packages#lgl-papercutter
nix run --extra-experimental-features "nix-command flakes" github:DanielTallon/nix-packages#kenku-fm
nix run --extra-experimental-features "nix-command flakes" github:DanielTallon/nix-packages#boot-gardener   
```

**Install one:**
```sh
nix profile install github:DanielTallon/nix-packages#kenku-fm
```

**As a flake input, per-package:**
```nix
inputs.nix-packages.url = "github:DanielTallon/nix-packages";
inputs.nix-packages.packages.${pkgs.stdenv.hostPlatform.system}.boot-gardener


# then reference, e.g. in a NixOS or home-manager module:
inputs.nix-packages.packages.${pkgs.stdenv.hostPlatform.system}.kenku-fm
```

**As an overlay** (pulls both into `pkgs.*`; doesn't install anything by itself):
```nix
inputs.nix-packages.url = "github:DanielTallon/nix-packages";

nixpkgs.overlays = [ inputs.nix-packages.overlays.default ];
# now available anywhere in your config as pkgs.lgl-papercutter / pkgs.kenku-fm / pkgs.boot-gardener
```

## A note on `kenku-fm`

Kenku FM is proprietary software. This flake scopes nixpkgs'
`allowUnfreePredicate` to just this one package (see `flake.nix`), so
building or installing it works out of the box — no `NIXPKGS_ALLOW_UNFREE`
or `--impure` needed. `lgl-papercutter` is unaffected and stays under its
normal MIT license.

## Updating a package

`lgl-papercutter` and `kenku-fm` are pinned (source + hash), so they won't
pick up new upstream releases automatically — that's intentional, for
reproducibility. To bump one:

1. Update `version` (and `rev`, for `lgl-papercutter`) in the relevant
`lgl-papercutter.nix` or `kenku-fm.nix`.
2. Set `hash`/`sha256` to a dummy value (`lib.fakeHash`, or any obviously
wrong string).
3. Run `nix build .#<name>`. It'll fail with a hash mismatch — copy the
`got:` value from the error into `hash`/`sha256`.
4. Rebuild, confirm it runs, commit.

`boot-gardener` is my own script with no upstream to track, so this
doesn't apply — just check back here to get the updated `version`. If you
have it as a flake input, `nix flake update` (or `nix flake lock
--update-input nix-packages`) pulls in whatever's on `main`.

## Structure

```
nix-packages/
├── flake.nix
├── lgl-papercutter/
│   └── lgl-papercutter.nix
├── kenku-fm/
│   └── kenku-fm.nix
└── boot-gardener/
    └── boot-gardener.nix
```

## License

This repo's packaging code (the `.nix` files) is provided as-is. Each
packaged application retains its own upstream license — see each
package's `meta.license` and the links above.
