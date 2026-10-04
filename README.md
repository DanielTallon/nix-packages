# nix-packages

Standalone, independently-installable Nix packages, packaged for personal
use and shared here in case they're useful to anyone else:

- **[`lgl-papercutter`](./lgl-papercutter)** — [LGL Papercutter](https://github.com/linuxgamerlife/lgl-papercutter), a Qt6/ImageMagick wallpaper editor for Linux. Pinned to `v0.3.0`, MIT licensed.
- **[`kenku-fm`](./kenku-fm)** — [Kenku FM](https://www.kenku.fm/), an offline-capable text-to-speech and soundboard app for tabletop audio. Built from upstream's `.deb` release. You can check out their GitHub [here](https://github.com/owlbear-rodeo/kenku-fm). Kenku-FM is proprietary/unfree.
- **[`boot-gardener`](https://github.com/DanielTallon/nix-packages/blob/main/boot-gardener)** — Boot Gardener, a bash (`jq` + `fzf`) tool for NixOS to pick, pin, prune, harvest, or garbage-collect boot-menu generations on Limine, systemd-boot, or GRUB, plus a rescue mode for a full `/boot` partition. Own project, MIT licensed.
- **[`proton-wineland`](./proton-wineland)** — [Proton Wineland](https://github.com/nanomatters/proton-cachyos), a Wayland-focused Proton fork, packaged as a Steam compatibility tool. Restores DLSS, frame generation and ray/path tracing in *The Witcher 3* 5.x with no exe patching. x86_64-linux only. See [proton-wineland](#proton-wineland) below.

Each package is exposed on its own — installing or building one never pulls in the others.

## Usage

**Run without installing:**
```sh
nix run github:DanielTallon/nix-packages#lgl-papercutter
nix run github:DanielTallon/nix-packages#kenku-fm
nix run github:DanielTallon/nix-packages#boot-gardener
```
**Run without installing, and without flakes enabled:**
```sh
nix run --extra-experimental-features "nix-command flakes" github:DanielTallon/nix-packages#lgl-papercutter
nix run --extra-experimental-features "nix-command flakes" github:DanielTallon/nix-packages#kenku-fm
nix run --extra-experimental-features "nix-command flakes" github:DanielTallon/nix-packages#boot-gardener
```

**Install just one:**
```sh
nix profile install github:DanielTallon/nix-packages#lgl-papercutter
nix profile install github:DanielTallon/nix-packages#kenku-fm
nix profile install github:DanielTallon/nix-packages#boot-gardener
```

(`proton-wineland` is a Steam compatibility tool, not a program you run or install
this way — see its section below.)

**As a flake input, per-package:**
```nix
inputs.nix-packages.url = "github:DanielTallon/nix-packages";

# then reference, e.g. in a NixOS or home-manager module:
inputs.nix-packages.packages.${pkgs.stdenv.hostPlatform.system}.boot-gardener
```

**As an overlay** (pulls all of them into `pkgs.*`; doesn't install anything by itself):
```nix
inputs.nix-packages.url = "github:DanielTallon/nix-packages";

nixpkgs.overlays = [ inputs.nix-packages.overlays.default ];
# now available anywhere in your config as pkgs.lgl-papercutter / pkgs.kenku-fm /
# pkgs.boot-gardener / pkgs.proton-wineland
```

## A note on `kenku-fm`

Kenku FM is not my program and is proprietary software.
This flake scopes nixpkgs' `allowUnfreePredicate` to just this one package (see `flake.nix`), so
building or installing it works out of the box — no `NIXPKGS_ALLOW_UNFREE`
or `--impure` needed.

## Updating a package

`lgl-papercutter` and `kenku-fm` are pinned (source + hash), so they won't
pick up new upstream releases automatically — that's intentional, for
reproducibility. To update one:

1. Update `version` (and `rev`, for `lgl-papercutter`) in the relevant
`lgl-papercutter.nix` or `kenku-fm.nix`.
2. Set `hash`/`sha256` to a dummy value (`lib.fakeHash`, or any obviously
wrong string).
3. Run `nix build .#<name>`. It'll fail with a hash mismatch — copy the
`got:` value from the error into `hash`/`sha256`.
4. Rebuild, confirm it runs, commit.

`boot-gardener` is my own TUI tool with no upstream to track, so this
doesn't apply — just check back here to get the updated `version`. If you
have it as a flake input, `nix flake update nix-packages` pulls in whatever's on `main`.

`proton-wineland` updates itself: a daily GitHub Action bumps
`proton-wineland/sources.json` (see its section below), so there's nothing to do
by hand beyond `nix flake update nix-packages`.

## Structure

```
nix-packages/
├── flake.nix
├── lgl-papercutter/
│   └── lgl-papercutter.nix
├── kenku-fm/
│   └── kenku-fm.nix
├── boot-gardener/
│   └── boot-gardener.nix
└── proton-wineland/
    ├── proton-wineland.nix
    ├── sources.json
    └── update.sh
```

## proton-wineland

[Proton Wineland](https://github.com/nanomatters/proton-cachyos) (a Wayland-focused Proton fork, published from nanomatters/proton-cachyos) packaged as a Steam compatibility tool. This is unofficial packaging of the upstream prebuilt releases.

| Attribute | Build | Needs |
| --- | --- | --- |
| `proton-wineland` | `x86_64_v3` (default) | a CPU with AVX2 |
| `proton-wineland-x86_64` | `x86_64` | any x86_64 CPU |

Not sure about AVX2? `grep -m1 -o avx2 /proc/cpuinfo` prints `avx2` if you have it.

**Stable name in Steam.** Upstream names each release after its version, so Steam forgets a game's tool selection on every update. This package renames it to **Proton-Wineland**, so your per-game choice survives updates.

**Automatic updates.** A daily GitHub Action (`update-proton-wineland`) checks for new `wineland-*` releases, updates `proton-wineland/sources.json`, verifies that both variants build, and commits. To pick up a new version, update this flake input and rebuild.

### NixOS

```nix
# flake.nix
inputs.nix-packages.url = "github:DanielTallon/nix-packages";

# configuration
programs.steam.extraCompatPackages = [
  inputs.nix-packages.packages.x86_64-linux.proton-wineland
];
```

Or with the overlay (`nixpkgs.overlays = [ inputs.nix-packages.overlays.default ];`), use `pkgs.proton-wineland`.

Rebuild, fully restart Steam (Steam → Exit), then pick **Proton-Wineland** under the game's Properties → Compatibility.

Updating:

```sh
nix flake update nix-packages
sudo nixos-rebuild switch --flake .
```

### Other distros with Nix (native Steam)

Steam reads compatibility tools from `~/.local/share/Steam/compatibilitytools.d`. Build the tool and symlink it there:

```sh
mkdir -p ~/.local/share/Steam/compatibilitytools.d
nix build github:DanielTallon/nix-packages#proton-wineland^steamcompattool \
  -o ~/.local/share/Steam/compatibilitytools.d/Proton-Wineland
```

The `-o` link also acts as a GC root, so `nix-collect-garbage` won't remove it. To update, run the same command again.

### Flatpak Steam

The Flatpak sandbox can't follow symlinks into `/nix/store`, so copy the files instead:

```sh
dest=~/.var/app/com.valvesoftware.Steam/data/Steam/compatibilitytools.d/Proton-Wineland
rm -rf "$dest"
cp -rL "$(nix build github:DanielTallon/nix-packages#proton-wineland^steamcompattool --no-link --print-out-paths)" "$dest"
chmod -R u+w "$dest"
```

Repeat these commands to update. (`chmod` makes the copy writable again; Nix store files are read-only, so without it a later `rm` asks about every file.)

### Notes: The Witcher 3 5.x ("Remastered")

Wineland 11.0-20260930 and newer restores DLSS, frame generation, ray tracing and path tracing in The Witcher 3, which the game otherwise disables when it detects Wine. It does this with a per-game Wine setting, so **no exe patching is needed, and game updates don't break it**.

- Use the **stock** `witcher3.exe`. If you previously patched it (for example with a community patch script), run Steam's *Verify integrity of game files* first.
- Tested on NVIDIA (RTX 4070 SUPER, driver 610): RT and path tracing ran stable for 15+ minutes with these launch options:
  `MANGOHUD=1 PROTON_ENABLE_NVAPI=1 %command%`
- Wineland enables Wine's Wayland driver by default. On a multi-monitor setup, the game may open on the wrong display the first time. Moving it to the right screen and setting the resolution once in the game's settings sticks across launches. If windowing misbehaves, `PROTON_ENABLE_WAYLAND=0` falls back to XWayland.


## License

This repo's packaging code (the `.nix` files) is provided as-is. Each
packaged application retains its own upstream license — see each
package's `meta.license` and the links above.
