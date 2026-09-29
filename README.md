# nix-packages

Standalone, independently-installable Nix packages, packaged for personal
use and shared here in case they're useful to anyone else:

- **[`lgl-papercutter`](./lgl-papercutter)** — [LGL Papercutter](https://github.com/linuxgamerlife/lgl-papercutter), a Qt6/ImageMagick wallpaper editor for Linux. Pinned to `v0.3.0`, MIT licensed.
- **[`kenku-fm`](./kenku-fm)** — [Kenku FM](https://www.kenku.fm/), an offline-capable text-to-speech and soundboard app for tabletop audio. Built from upstream's `.deb` release. You can check out their GitHub [here](https://github.com/owlbear-rodeo/kenku-fm). Kenku-FM is proprietary/unfree.
- **[`boot-gardener`](https://github.com/DanielTallon/nix-packages/blob/main/boot-gardener)** — Boot Gardener, a bash (`jq` + `fzf`) tool for NixOS to pick, pin, prune, harvest, or garbage-collect boot-menu generations on Limine, systemd-boot, or GRUB, plus a rescue mode for a full `/boot` partition. Own project, MIT licensed.
- **[`proton-ge-w3rt`](./proton-ge-w3rt)** and **[`vkd3d-proton-w3rt`](./vkd3d-proton-w3rt)** — a ray tracing fix for *The Witcher 3: Wild Hunt — Remastered* (5.0) under Proton on NVIDIA. `proton-ge-w3rt` is a ready-to-use Steam compatibility tool (GE-Proton11-7 with a patched vkd3d-proton); `vkd3d-proton-w3rt` is just the patched DLLs. x86_64-linux only. See [Witcher 3 ray tracing on Proton](#witcher-3-ray-tracing-on-proton) below.

Each package is exposed on its own — installing or building one never pulls in the others
(the one exception: `proton-ge-w3rt` is built on top of `vkd3d-proton-w3rt`).

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

(The Witcher 3 packages aren't programs you run or install this way — see their
section below.)

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
# pkgs.boot-gardener / pkgs.proton-ge-w3rt / pkgs.vkd3d-proton-w3rt
```

## A note on `kenku-fm`

Kenku FM is not my program and is proprietary software.
This flake scopes nixpkgs' `allowUnfreePredicate` to just this one package (see `flake.nix`), so
building or installing it works out of the box — no `NIXPKGS_ALLOW_UNFREE`
or `--impure` needed.

## Witcher 3 ray tracing on Proton

**The problem.** The 5.0 ("Remastered") update of *The Witcher 3* checks whether it's
running under Wine/Proton and, if so, disables DLSS, Frame Generation, Reflex and all
ray tracing options. Patching that check out re-enables them, but with ray tracing on,
stock vkd3d-proton then hangs the GPU within about a minute on NVIDIA drivers 590 and
newer (kernel log: `Xid 109 … CTX SWITCH TIMEOUT`) —
[vkd3d-proton#3226](https://github.com/HansKristian-Work/vkd3d-proton/issues/3226),
not fixed upstream at the time of writing.

**The fix** has two parts, and you need both for ray tracing:

1. **Patch the game executable** with `w3_proton_patch.py` from
   [this gist](https://gist.github.com/gabrielmaialva33/33ebb2542f0513d55100b22aa2149ff5)
   (by gabrielmaialva33). Without `--rt` it re-enables DLSS, Frame Gen and Reflex only;
   `--rt` also unlocks ray tracing and path tracing. Neither package here touches your
   game files — this step is always manual.
2. **Run the game on a Proton with the patched vkd3d-proton** — that's what these two
   packages provide. They're built from the exact vkd3d-proton commit GE-Proton11-7
   ships (`af89350c`), with the gist's RTAS prebuild-size workaround applied.

This is an unofficial workaround — use it at your own risk, and back up your saves
before the first ray-traced load. The hang is NVIDIA-specific, so AMD users (including
the Steam Deck) most likely don't need the vkd3d-proton part.

### Step 1: patch the game

Close the game, download `w3_proton_patch.py` from the gist, and run:

```sh
python3 w3_proton_patch.py --dry-run   # check first: should report 5 sites as "original"
python3 w3_proton_patch.py --rt        # patch
```

By default it patches
`~/.local/share/Steam/steamapps/common/The Witcher 3/bin/x64_dx12/witcher3.exe`; pass a
path if your library lives elsewhere. It only supports exe build **5.0.0.1041720**, and
refuses to touch anything else. It keeps a backup next to the exe — undo with `--restore`,
or with Steam's "Verify integrity of game files". **Every game update overwrites the
patched exe**, so if DLSS or ray tracing grey out again after an update, that's why.

On NixOS without a global Python: `nix shell nixpkgs#python3 -c python3 w3_proton_patch.py --rt`

### Step 2: install the patched Proton

All three routes give you a compatibility tool that shows up in Steam as
**`GE-Proton11-7-rt`**. Its name deliberately differs from stock GE-Proton11-7, so it
never collides with a regular GE-Proton install.

**NixOS** — add it to your Steam compat tools and rebuild:
```nix
inputs.nix-packages.url = "github:DanielTallon/nix-packages";

programs.steam.extraCompatPackages = [
  inputs.nix-packages.packages.x86_64-linux.proton-ge-w3rt
];
```

**Nix on any other distro** (native Steam) — one command:
```sh
nix build github:DanielTallon/nix-packages#proton-ge-w3rt.steamcompattool \
  --out-link ~/.steam/root/compatibilitytools.d/GE-Proton11-7-rt
```
This creates the symlink Steam reads *and* registers it as a garbage-collection root, so
`nix-collect-garbage` won't delete the tool from under you. Rerun the same command to
update; delete the symlink to uninstall. Add `--extra-experimental-features "nix-command flakes"`
if flakes aren't enabled. Don't use `nix profile install` here — the package's default
output is an empty stub; Steam needs the `.steamcompattool` output.

**Flatpak Steam** — the Flatpak sandbox can't see `/nix/store`, so a symlink won't work.
Copy the tool in instead (about 1 GB; to update, delete the folder and copy again):
```sh
cp -rL "$(nix build github:DanielTallon/nix-packages#proton-ge-w3rt.steamcompattool --no-link --print-out-paths)" \
  ~/.var/app/com.valvesoftware.Steam/data/Steam/compatibilitytools.d/GE-Proton11-7-rt
```

**Your own Proton instead** (advanced): `vkd3d-proton-w3rt` gives you just the two DLLs.
Only use it with a Proton that ships vkd3d-proton at the same commit (GE-Proton11-7).
Copy `result/bin/d3d12.dll` and `d3d12core.dll` into a *copy* of that Proton, under
`files/lib/wine/vkd3d-proton/x86_64-windows/`, and give the copy both a unique name in
`compatibilitytool.vdf` and a unique string in its `version` file. Proton only refreshes a
game prefix's DLLs when the `version` changes, so if you skip that, the game keeps running
the stock DLLs. `proton-ge-w3rt` does all of this for you.

### Step 3: play and verify

1. Restart Steam completely (Steam → Exit, not just closing the window), so it rescans
   compat tools.
2. In the game's Properties → Compatibility, select `GE-Proton11-7-rt`.
3. Launch options: `PROTON_ENABLE_NVAPI=1 %command%`
4. Launch the DX12 version. DLSS, Frame Generation and the ray tracing options should now
   be selectable in Options → Graphics.

To confirm the patched vkd3d-proton is really in use, launch once with
`PROTON_LOG=1 VKD3D_DEBUG=info PROTON_ENABLE_NVAPI=1 %command%`, load a save with ray
tracing on, quit, then:
```sh
grep -i 'RTAS prebuild' ~/steam-292030.log   # should print "...multiplied by 8 (local workaround)"
journalctl -k -b | grep -i 'xid.*witcher'    # should print nothing new
```
Remove the two logging variables afterwards — info-level logging is verbose.

If there's no RTAS line and the game froze, the game is still on another Proton's DLLs:
check the Compatibility setting, and that Steam was fully restarted.

**Tested:** RTX 4070 SUPER, NVIDIA 610.57.04, GE-Proton11-7-rt at 3440×1440 — ray tracing
plus DLSS and Frame Generation stable through 10+ minutes of play and a save reload.
With 12 GB of VRAM, path tracing is the setting most likely to push things too far.
Other GPUs and drivers are untested — reports welcome.

These packages become unnecessary once vkd3d-proton#3226 is fixed upstream and the fix
reaches a GE-Proton release. At that point, go back to a normal Proton — you'll still
need the exe patch for as long as the game keeps its Wine check.

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
have it as a flake input, `nix flake update` (or `nix flake lock
--update-input nix-packages`) pulls in whatever's on `main`.

`proton-ge-w3rt` and `vkd3d-proton-w3rt` must always move **together**: the GE-Proton
`version` in `proton-ge-w3rt.nix` and the vkd3d-proton `rev` in `vkd3d-proton-w3rt.nix`
have to be the pair that GE release actually ships. When bumping, update both, rebuild
with the hash steps above (`vkd3d-proton-w3rt` has two hashes — source and patch — and
`proton-ge-w3rt` one), and check the patch still applies. To build both outputs of the
compat tool locally, use `nix build '.#proton-ge-w3rt^*'` (the steamcompattool output
ends up at `result-steamcompattool`).

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
├── vkd3d-proton-w3rt/
│   └── vkd3d-proton-w3rt.nix
└── proton-ge-w3rt/
    └── proton-ge-w3rt.nix
```

## License

This repo's packaging code (the `.nix` files) is provided as-is. Each
packaged application retains its own upstream license — see each
package's `meta.license` and the links above. The vkd3d-proton RTAS
workaround patch and `w3_proton_patch.py` are gabrielmaialva33's work,
fetched from their gist rather than redistributed here.
