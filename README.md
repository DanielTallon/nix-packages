# nix-packages

Standalone, independently-installable Nix packages, packaged for personal
use and shared here in case they're useful to anyone else:

- **[`lgl-papercutter`](./lgl-papercutter)** — [LGL Papercutter](https://github.com/linuxgamerlife/lgl-papercutter), a Qt6/ImageMagick wallpaper editor for Linux. Pinned to `v0.3.0`, MIT licensed.
- **[`kenku-fm`](./kenku-fm)** — [Kenku FM](https://www.kenku.fm/), an offline-capable text-to-speech and soundboard app for tabletop audio. Built from upstream's `.deb` release. Proprietary/unfree.

Each package is exposed on its own — installing or building one never pulls in the other.

## Usage

**Run without installing:**
```sh
nix run github:DanielTallon/nix-packages#lgl-papercutter
nix run github:DanielTallon/nix-packages#kenku-fm
```

**Install one:**
```sh
nix profile install github:DanielTallon/nix-packages#kenku-fm
```

**As a flake input, per-package:**
```nix
inputs.nix-packages.url = "github:DanielTallon/nix-packages";

# then reference, e.g. in a NixOS or home-manager module:
inputs.nix-packages.packages.${pkgs.stdenv.hostPlatform.system}.kenku-fm
```

**As an overlay** (pulls both into `pkgs.*`; doesn't install anything by itself):
```nix
inputs.nix-packages.url = "github:DanielTallon/nix-packages";

nixpkgs.overlays = [ inputs.nix-packages.overlays.default ];
# now available anywhere in your config as pkgs.lgl-papercutter / pkgs.kenku-fm
```

## A note on `kenku-fm`

Kenku FM is proprietary software. This flake scopes nixpkgs'
`allowUnfreePredicate` to just this one package (see `flake.nix`), so
building or installing it works out of the box — no `NIXPKGS_ALLOW_UNFREE`
or `--impure` needed. `lgl-papercutter` is unaffected and stays under its
normal MIT license.

## Updating a package

Both packages are pinned (source + hash), so they won't pick up new
upstream releases automatically — that's intentional, for reproducibility.
To bump one:

1. Update `version` (and `rev`, for `lgl-papercutter`) in the relevant
   `package.nix`.
2. Set `hash`/`sha256` to a dummy value (`lib.fakeHash`, or any obviously
   wrong string).
3. Run `nix build .#<name>`. It'll fail with a hash mismatch — copy the
   `got:` value from the error into `hash`/`sha256`.
4. Rebuild, confirm it runs, commit.

## Structure

```
nix-packages/
├── flake.nix
├── lgl-papercutter/
│   └── package.nix
└── kenku-fm/
    └── package.nix
```

## License

This repo's packaging code (the `.nix` files) is provided as-is. Each
packaged application retains its own upstream license — see each
package's `meta.license` and the links above.
