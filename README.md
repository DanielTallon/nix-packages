# nix-packages

Standalone, independently-installable Nix packages, packaged for personal
use and shared here in case they're useful to anyone else:

- **[`lgl-papercutter`](./lgl-papercutter)** — [LGL Papercutter](https://github.com/linuxgamerlife/lgl-papercutter), a Qt6/ImageMagick wallpaper editor for Linux. Pinned to `v0.3.0`, MIT licensed.
- **[`kenku-fm`](./kenku-fm)** — [Kenku FM](https://www.kenku.fm/), an offline-capable text-to-speech and soundboard app for tabletop audio. Built from upstream's `.deb` release. You can check out their GitHub [here](https://github.com/owlbear-rodeo/kenku-fm). Kenku-FM is proprietary/unfree.
- **[`boot-gardener`](https://github.com/DanielTallon/nix-packages/blob/main/boot-gardener)** — Boot Gardener, a bash (`jq` + `fzf`) tool for NixOS to pick, pin, prune, harvest, or garbage-collect boot-menu generations on Limine, systemd-boot, or GRUB, plus a rescue mode for a full `/boot` partition. Own project, MIT licensed.
- **[`proton-wineland`](./proton-wineland)** — [Proton Wineland](https://github.com/nanomatters/proton-cachyos), a Wayland-focused Proton fork, packaged as a Steam compatibility tool. Restores DLSS, frame generation and ray/path tracing in *The Witcher 3* 5.x with no exe patching. x86_64-linux only. See [proton-wineland](#proton-wineland) below.
- **[`nixed-error`](./nixed-error)** — explains a failed NixOS rebuild in plain words: what went wrong, the file and line, whether it's your config, upstream, or your machine, and how to fix it. Rule-based (no LLM, no network). Own project, still in testing.
- **[`wallpaperpicker`](./wallpaperpicker)** — [kwepaperpicker](https://gitlab.com/theblackdon/qs-kwepaperpicker), packaged here as `wallpaperpicker`, a swatch-deck wallpaper picker for Quickshell. Brings its own icon font, and on KDE Plasma hands the chosen wallpaper to Plasma by default. `wallpaperpicker-nixgl` is the same picker for Nix on other distros. See [wallpaperpicker](#wallpaperpicker) below. GPL-3.0-or-later.
- **[`flow-desktop`](./flow-desktop)** — [Flow Desktop](https://github.com/Flow-Tube/Flow-Desktop), a privacy-respecting YouTube and YouTube Music client (Tauri 2), built from source. Based on [olafkfreund/nixos-FlowTube](https://github.com/olafkfreund/nixos-FlowTube)'s package, tracking upstream main, plus a local patch that adds thumbnail previews to the seekbar. GPL-3.0.
- **[`photo2scan`](./photo2scan)** — turns phone photos of paper pages into a scanned-looking PDF: finds the page, undoes the camera angle, evens out the lighting. Handy for forms someone photographed at an angle and sent you. Also a [web page](https://danieltallon.github.io/nix-packages/photo2scan/) that works on Windows, Linux and phones with nothing to install. See [photo2scan](#photo2scan) below. Own project, MIT licensed.

Each package is exposed on its own — installing or building one never pulls in the others.

## Usage

**Run without installing:**
```sh
nix run github:DanielTallon/nix-packages#lgl-papercutter
nix run github:DanielTallon/nix-packages#kenku-fm
nix run github:DanielTallon/nix-packages#boot-gardener
nix run github:DanielTallon/nix-packages#nixed-error
nix run github:DanielTallon/nix-packages#wallpaperpicker
nix run github:DanielTallon/nix-packages#flow-desktop
nix run github:DanielTallon/nix-packages#photo2scan -- -o form.pdf photo1.jpg photo2.jpg
```
**Run without installing, and without flakes enabled:**
```sh
nix run --extra-experimental-features "nix-command flakes" github:DanielTallon/nix-packages#lgl-papercutter
nix run --extra-experimental-features "nix-command flakes" github:DanielTallon/nix-packages#kenku-fm
nix run --extra-experimental-features "nix-command flakes" github:DanielTallon/nix-packages#boot-gardener
nix run --extra-experimental-features "nix-command flakes" github:DanielTallon/nix-packages#nixed-error
nix run --extra-experimental-features "nix-command flakes" github:DanielTallon/nix-packages#wallpaperpicker
nix run --extra-experimental-features "nix-command flakes" github:DanielTallon/nix-packages#flow-desktop
nix run --extra-experimental-features "nix-command flakes" github:DanielTallon/nix-packages#photo2scan -- -o form.pdf photo1.jpg photo2.jpg
```

`nixed-error` with no arguments re-evaluates your system config and explains what fails.
To explain output you already have, pipe it in:
`sudo nixos-rebuild switch 2>&1 | nix run github:DanielTallon/nix-packages#nixed-error`.

**Install just one:**
```sh
nix profile install github:DanielTallon/nix-packages#lgl-papercutter
nix profile install github:DanielTallon/nix-packages#kenku-fm
nix profile install github:DanielTallon/nix-packages#boot-gardener
nix profile install github:DanielTallon/nix-packages#nixed-error
nix profile install github:DanielTallon/nix-packages#wallpaperpicker
nix profile install github:DanielTallon/nix-packages#flow-desktop
nix profile install github:DanielTallon/nix-packages#photo2scan
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
# pkgs.boot-gardener / pkgs.proton-wineland / pkgs.nixed-error /
# pkgs.wallpaperpicker / pkgs.flow-desktop / pkgs.photo2scan
```

## A note on `kenku-fm`

Kenku FM is not my program and is proprietary software.
This flake scopes nixpkgs' `allowUnfreePredicate` to just this one package (see `flake.nix`), so
building or installing it works out of the box — no `NIXPKGS_ALLOW_UNFREE`
or `--impure` needed.

## wallpaperpicker

Start the picker, then open and close it from a key binding or a second terminal:

```sh
nix run github:DanielTallon/nix-packages#wallpaperpicker
nix run github:DanielTallon/nix-packages#wallpaperpicker -- toggle
```

(Installed, those are `wallpaperpicker` and `wallpaperpicker toggle`. `wallpaperpicker --help` lists the rest.)

- **Desktop:** needs a Wayland desktop Quickshell runs on, such as KDE Plasma, Hyprland, Sway or niri. GNOME doesn't work.
- **Font:** the Material Symbols icon font comes with the package. Nothing to install.
- **Wallpaper:** on KDE Plasma it hands the chosen wallpaper to Plasma (`plasma-apply-wallpaperimage {}`). Elsewhere it draws the wallpaper itself, videos included. Plasma's command only takes images, so to use video wallpapers on Plasma, clear the command in the picker's settings (the gear at the top right).
- **Files:** settings and the matugen colour scheme are kept in `~/.config/wallpaperpicker` (an old `~/.config/kwepaperpicker` is moved there on first run). Wallpapers are read from `~/Pictures/wallpapers` by default.

### Other distros with Nix

Programs from Nix often can't find the graphics drivers on other distros. If the log shows
`qt.qpa.wayland: EGL not available` and the picker never appears, this is why.

`toggle` starts the picker in the background if it isn't running, then opens it, so on
other distros one command does both. Run the same command again to close it, or bind it
to a key (on Plasma: System Settings → Shortcuts → Add Command).

For Mesa drivers (Intel, AMD, nouveau), use the build that runs through [nixGL](https://github.com/nix-community/nixGL):

```sh
nix run github:DanielTallon/nix-packages#wallpaperpicker-nixgl -- toggle
```

For NVIDIA's proprietary driver (any GeForce card on the official driver, including
the RTX 50 series), nixGL has to detect the installed driver, which needs `--impure`:

```sh
nix run --impure github:nix-community/nixGL -- nix run github:DanielTallon/nix-packages#wallpaperpicker -- toggle
```

The first NVIDIA run downloads the driver matching yours from NVIDIA, a few hundred MB.
After the distro updates the driver, reboot before running it again so the versions match.

Without flakes enabled, both `nix run`s need the flag:

```sh
nix run --impure --extra-experimental-features "nix-command flakes" github:nix-community/nixGL -- nix run --extra-experimental-features "nix-command flakes" github:DanielTallon/nix-packages#wallpaperpicker -- toggle
```

Always open it with the nixGL command. A plain `toggle` closes and opens a picker that's
already running, but if the picker isn't running (after a reboot, say), it starts it
without the drivers.

Don't use any of these on NixOS. They replace the system's drivers with nixGL's.

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

`nixed-error/nixed-error.nix` is generated from the nixed-error project
(`export-nix.py` there), so regenerate it rather than editing the embedded
script by hand.

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
├── nixed-error/
│   └── nixed-error.nix
├── wallpaperpicker/
│   └── wallpaperpicker.nix
├── flow-desktop/
│   ├── flow-desktop.nix
│   └── flow-desktop-storyboard-preview.patch
├── photo2scan/
│   ├── photo2scan.nix
│   ├── photo2scan.py
│   └── web/
│       └── index.html
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


## photo2scan

### On the web (any computer, including Windows)

Open **<https://danieltallon.github.io/nix-packages/photo2scan/>**, click
**Choose photos…**, drag any orange corner the page finder got wrong, and click
**Save PDF**. Everything runs in the browser; photos are never uploaded. It is
one self-contained file, [`photo2scan/web/index.html`](./photo2scan/web/index.html),
with no libraries, so it also works opened straight from disk with no internet.
Browsers other than Safari can't open HEIC photos; JPEG and PNG work everywhere.

The `pages` workflow publishes it whenever that file changes on `main`. It needs
**Settings → Pages → Source: GitHub Actions** set once on the repository.

### Command line

Give it the photos in page order and the PDF to write:

```sh
photo2scan -o form.pdf IMG_0001.jpg IMG_0002.jpg
```

For each photo it finds the page (bright, low-color paper against a darker or
more colorful background), stretches its four corners back to a rectangle, and
flattens shadows so the paper comes out white. Pages are fitted to US Letter.

- `-m gray` (default) keeps pencil and gray shading; `-m bw` gives a
  black-and-white photocopy look; `-m color` keeps colors.
- `--debug` also writes `<photo>.detected.jpg` next to each photo with the page
  it found outlined in red. Use it when a page comes out cropped wrong.

It corrects camera angle, not paper that is curled or folded. A white page on a
white table may not be found; then it says so and uses the whole photo.

## License

This repo's packaging code (the `.nix` files) is provided as-is. Each
packaged application retains its own upstream license — see each
package's `meta.license` and the links above.
