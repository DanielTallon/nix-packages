# Boot Gardener

Pick a NixOS generation, then **pin** it to keep it bootable, **prune** it
if it's not currently in the boot menu, or **harvest** it to evict it from
the boot menu and reclaim its `/boot` space immediately — plus a global
**garbage-collect** action for orphaned `/boot` files and nix-shell/nix
develop leftovers, and an in-place help panel — all from one scrollable
list. Plus a rescue tool for when `/boot` fills up and a normal rebuild
can't even run.

Two scripts under one command:

- **`boot-gardener`** — browse your system generations and pin one to the
  boot menu (bypassing `maxGenerations` garbage collection), prune one that
  isn't in the boot menu, harvest one that is (evict + reclaim its `/boot`
  space on the spot), or garbage-collect boot orphans and nix-shell/nix
  develop leftovers, from a single screen.
- **`boot-gardener rescue`** — diagnose and, if needed, fix a `/boot`
  partition that's full or close to it, by finding and safely removing
  files a normal rebuild can't reach because it doesn't have room to run.

Pinning is a companion to a small NixOS module, `limine-manual-pins.nix`
(not included here — wire it into your own flake), which defines the
`custom.limineManualPins` option that actually builds the Limine menu entry
and copies files into `/boot`.

## Bootloader support

| | Limine | systemd-boot | GRUB |
|---|---|---|---|
| Pick, prune, harvest, garbage-collect | ✅ | ✅ | ✅ |
| Rescue mode (`boot-gardener rescue`) | ✅ | ✅ | ✅ |
| Pin (`Enter`) | ✅ | ❌ (see below) | ❌ (see below) |

The bootloader is auto-detected from what's on `/boot` (presence of
`/boot/limine/limine.conf`, `/boot/loader/loader.conf`, or
`/boot/grub/grub.cfg`); pass `--bootloader limine`, `--bootloader
systemd-boot`, or `--bootloader grub` to either script to skip detection.
If **more than one** of these files exists — common right after switching
bootloaders, since NixOS's installers don't clean up the previous
loader's leftover files — detection picks whichever was modified most
recently (only the bootloader actually in use gets its config rewritten
on every rebuild) and prints a note saying so; `--bootloader` always
overrides the guess.

**Pinning is Limine-only for now.** It works by generating a Nix-level JSON
file that `limine-manual-pins.nix` turns into a real Limine menu entry —
there's no systemd-boot or GRUB equivalent of that module yet, since both
of their NixOS-managed boot configs are fully regenerated from the current
generation list on every rebuild rather than something a small
side-channel module can cleanly inject a standalone entry into. On
systemd-boot or GRUB, pressing `Enter` explains this and does nothing
else; prune/harvest/GC all work exactly the same on all three.

## Design goals

- **Simplicity** — plain bash, `jq` + `fzf`, no compiled binary.
- **Reproducibility** — the picker owns exactly one file, `limine-pins.json`,
  and always rewrites it **in full** (sorted by name) rather than patching
  it. A `git diff` on it is always clean and legible.
- **Never wrecks your git tracking** — neither script edits any other file
  in your config on its own initiative, or runs `git`, or triggers a
  rebuild. The picker changes one JSON file and stops. `rescue`'s default
  mode changes nothing at all — real changes require an explicit `--apply`
  and typed confirmation, described below.

---

## Picking, pinning, harvesting, garbage-collecting

### Usage

```bash
# Interactively pick a generation. Enter pins it, 'p' prunes it (if not on
# the bootloader), 'h' harvests it (if on the bootloader), 'g'
# garbage-collects.
nix run github:DanielTallon/nix-packages#boot-gardener

# Or run it directly:
boot-gardener --output ~/.dotfiles/limine-pins.json

# List what's currently pinned
boot-gardener --list

# Remove a pin by its name (or select its 📌 row in the interactive list
# and press Enter instead)
boot-gardener --remove gen-144

# Skip bootloader auto-detection
boot-gardener --bootloader systemd-boot
```

The list shows generation number, date, NixOS/kernel version, and a `BOOT`
column marking which generations are currently referenced in your boot
menu (reading `/boot/limine/limine.conf` on Limine, `/boot/loader/entries/`
on systemd-boot, or `/boot/grub/grub.cfg` on GRUB — all need `sudo` to
read; you'll be prompted once, up front). A second header line shows
`/boot`'s used/free space and percent-full (`df -h /boot`, no `sudo`
needed), recomputed on every redraw so it reflects `p`/`h`/`g` immediately.

- **Tab** marks a generation for a multi-select action without leaving the
  list; **Shift-Tab** unmarks one. Marking generations only matters for
  `p`/`h` below — pin/unpin always applies to a single row, and `g` ignores
  selection entirely.
- Pin rows (📌) are listed alongside generation rows, and stick around even
  after their source generation is pruned/GC'd from the system profile —
  pinning captures store paths directly for exactly that reason, so
  there's always a row to unpin.
- **Enter** on a generation row pins it (**Limine only** — see
  [Bootloader support](#bootloader-support) above; on systemd-boot or GRUB
  this prints an explanation and does nothing else): resolves its
  `kernel`/`initrd`/`init` store paths and `kernel-params` cmdline
  automatically, then asks for a short name, a menu title, and an optional
  comment. Once written, it asks `Rebuild now with 'nh os boot . --
  --impure'? [yes/N]` — type `yes` to run it on the spot, or anything else
  (including just Enter) to skip and get a printed reminder instead, since
  it's easy to forget `--impure` is now required (see below).
- **Enter** on a pin row (📌) unpins it instead: removes it from
  `limine-pins.json`, then offers to rebuild on the spot (`nh os switch .
  -- --impure` if other pins remain, plain `nh os switch .` if that was the
  last one) — same "type something else to skip" convention as pinning.
- **`p`** and **`h`** are opposite ends of removing a generation, and each
  only works on the kind of generation the other doesn't — the `BOOT`
  column tells you which is which. Both work identically across all three
  backends:
  - **`p`** **prunes** the selected generation(s) — only works on ones
    **not** currently in the boot menu. Deletes them from the NixOS system
    profile (`nix-env -p .../system --delete-generations`); doesn't touch
    `/boot` at all, so the space isn't reclaimed until your next `g`.
    Picking a generation that *is* in the boot menu refuses with a message
    pointing you at `h` instead. Typed `yes` confirmation per generation.
  - **`h`** **harvests** the selected generation(s) — only works on ones
    **that are** currently in the boot menu. For each one, hands off to
    `boot-gardener rescue --evict GEN --apply`, which removes its
    boot-menu entry *and* deletes the `/boot` files that entry alone was
    using — reclaiming the space immediately rather than waiting on a
    later GC + rebuild. It inherits every guardrail `rescue` already has:
    refuses the currently-booted generation, refuses to drop below 2 kept
    generations, backs up the affected boot-menu config before touching
    it, and needs typed confirmation per generation. Picking a generation
    that is *not* in the boot menu refuses with a message pointing you at
    `p` instead. See [Rescue mode](#rescue-mode) below for exactly what
    that confirmation flow looks like.
- **`g`** **garbage-collects** — a global action, independent of whatever's
  highlighted or marked. It reports orphaned `/boot` files the same way
  `boot-gardener rescue` does (Phase 1: files referenced by no current
  boot-menu entry), then reports dead Nix store paths (`nix-store --gc
  --print-dead`) — the usual home of nix-shell/nix develop leftovers, stray
  build results, and anything freed up by a prior `p`. One `[yes/N]`
  confirmation runs both cleanups for real: the `/boot` orphans are deleted
  via `rescue --apply` (its own guardrails and confirmation still apply),
  then `nix-collect-garbage` runs. It never deletes a generation from the
  system profile itself and never touches the boot-menu config directly —
  that's what `h` is for.
- **`?`** toggles an in-place help panel listing all of the above, without
  leaving the list.
- **`q`** or **Esc** at the list quits the tool entirely, as does Ctrl-C at
  any point. `q` at a prompt or confirmation *within* a pin/prune/harvest/gc
  only cancels that one action — you're dropped back into the (refreshed)
  generation list rather than the whole tool exiting, so you can
  immediately pick something else.
- Every pin/prune/harvest/gc outcome — success, refusal (a guardrail
  message like the 2-kept-generation floor), or cancellation — ends on a
  `Press Enter to return to the list...` pause before the screen redraws.
  Without it, a message that doesn't already end on its own confirmation
  prompt would get wiped off the terminal by the next redraw before
  there's any real chance to read it.

### Wiring it into your flake

Point `custom.limineManualPins` at the generated JSON file instead of a
hand-written list:

```nix
custom.limineManualPins = builtins.fromJSON (builtins.readFile ./limine-pins.json);
```

The path is relative to **the file this line lives in**, not your repo
root — if you set it from a file one directory down (e.g. `hosts.nix` in a
`modules/` folder, with `limine-pins.json` at the repo root), use
`../limine-pins.json` instead. Commit `limine-pins.json` alongside the rest
of your dotfiles like any other tracked file.

### ⚠️ Requires `--impure` while any pin exists

*(Limine only — pinning doesn't exist on systemd-boot or GRUB yet, so this
whole section is moot there.)*

Referencing an existing generation's store paths is inherently impure —
those paths live only on your local machine and aren't declared anywhere in
your flake's inputs, so Nix's pure/flake evaluation mode refuses to touch
them (`error: 'builtins.storePath' is not allowed in pure evaluation mode`,
or `access to absolute path '...' is forbidden in pure evaluation mode`).
There's no way around this with a code change — it's fundamental to what
the feature does, not a bug in the module.

The picker offers to handle this for you right after a pin is written (see
above) — but **every rebuild, for as long as `limine-pins.json` has any
entries, needs `--impure`:**

```bash
nh os switch . -- --impure
# or, with plain nixos-rebuild:
sudo nixos-rebuild switch --flake .#yourhost --impure
```

Once you remove the last pin (`limine-pins.json` back to `[]`), the next
rebuild goes back to normal — no `--impure` needed.

**Known quirk:** removing a pin (via `--remove`, back to `limine-pins.json`
being `[]` for that entry) and rebuilding with `switch` may not actually
clear the entry from the boot menu. If that happens, try `boot` instead
(`nh os boot . -- --impure`), which was confirmed to work when `switch`
alone didn't. Cause not diagnosed; this is just a documented workaround.

### ⚠️ The real disk cost of a pin can be much bigger than the kernel

*(Limine only, for the same reason as above.)*

A pin isn't just the ~100-300 MB kernel/initrd pair it captures. `pin.init`
points at that generation's `init` script, which is the entry point for
its *entire* environment — every package that generation had installed.
Nix's closure-reference-scanner finds every store path referenced inside
that script and keeps **all of it** alive for as long as the pin exists, so
your new system's build doesn't fail with missing dependencies if you ever
actually boot into the pinned generation.

In practice: pinning a generation from before a major package upgrade (a
KDE 5→6 migration, a big library bump, etc.) can add **tens of gigabytes**
to your Nix store, not a few hundred megabytes — confirmed in testing
(+33.8 GiB for one generation pinned across a KDE major-version gap).
Pinning a *recent* generation, where little has changed since, costs much
less. Pruning the pin and garbage-collecting reclaims the space.

`/boot` itself also grows with each pin (the copied kernel/initrd/init
files live under `/boot/limine/manual/` permanently) — on a small `/boot`
partition, a long-held pin works against the exact problem the `rescue`
tool exists to solve. Don't pin generations you don't genuinely need to
keep bootable long-term.

---

## Rescue mode

For when `/boot` is full (or close to it) and a normal rebuild can't
succeed because there's no room for it to even run its own cleanup step —
`nix-env --delete-generations` alone can't help here, since the actual
files in `/boot` are only rewritten by a *successful* rebuild.

### Usage

```bash
# Report only -- never changes anything
boot-gardener rescue

# Also preview evicting a specific kept generation's menu entry
boot-gardener rescue --evict 166

# Actually delete Phase 1 orphaned files (typed confirmation required)
boot-gardener rescue --apply

# Actually evict a generation and delete its now-orphaned files
# (types the generation number back, then 'yes', to confirm)
boot-gardener rescue --evict 166 --apply

# Skip bootloader auto-detection
boot-gardener rescue --bootloader grub
```

### How it works

The mechanics differ slightly by bootloader, but the shape is the same:
find files nothing references and remove them zero-risk first, then
optionally remove one boot-menu entry and whatever that newly orphans.

- **Phase 1 (zero risk):** finds files that no current boot-menu entry
  references, and reports them. These are typically leftovers from a
  rebuild that died partway through. Deleting them never touches the boot
  menu.
  - *Limine:* parses every `kernel_path`/`module_path` line in
    `limine.conf` to build the referenced set, and compares it against
    what's actually in `/boot/limine/kernels/`.
  - *systemd-boot:* parses every `linux`/`initrd` line across all entry
    files in `/boot/loader/entries/`, and compares that against what's
    actually in `/boot/EFI/nixos/`.
  - *GRUB:* parses every `linux`/`initrd` line referencing `/kernels/...`
    across all `menuentry`/`submenu` blocks in `/boot/grub/grub.cfg`, and
    compares that against what's actually in `/boot/kernels/`. If your
    system has `boot.loader.grub.copyKernels = false` (the default when
    `/boot` and `/nix/store` share a filesystem), GRUB references
    `/nix/store` directly and nothing is ever copied into `/boot/kernels/`
    — Phase 1 always reports zero orphans there, and harvesting a
    generation only removes its `grub.cfg` entry with no `/boot` space
    reclaimed.
- **Phase 2 (`--evict N`):** previews (or, with `--apply`, actually
  performs) removing generation N's boot-menu entry, then re-checks what
  additional files that makes orphaned — accounting for content-hash
  deduplication, since consecutive generations often share identical
  kernel builds and only the files genuinely no longer used by anything
  get deleted.
  - *Limine:* cuts generation N's `//Generation N` block out of
    `limine.conf`.
  - *systemd-boot:* deletes generation N's own entry file,
    `nixos-generation-N.conf` — each generation already has its own file
    there, so this step has no config-parsing to get wrong.
  - *GRUB:* cuts generation N's `menuentry`/`submenu` block out of
    `grub.cfg`, tracked by brace depth rather than a fixed line pattern —
    a generation with NixOS specialisations wraps in an extra `submenu`
    around several `menuentry`s, a plain one is just one `menuentry`, and
    both are handled the same way.

  `--evict N --apply` also deletes any Phase 1 orphans first, *before*
  touching the boot-menu config — since writing the backup and the edit
  both need a little free space themselves, deleting the zero-risk Phase 1
  files first guarantees that room even when `/boot` is already completely
  full (0 bytes free). This is what makes `h` (harvest) in the picker work
  reliably on a fully-out-of-space `/boot` without a separate manual
  `rescue --apply` afterward.

### Guardrails

Identical across all three backends:

- Never proposes evicting the currently-booted generation — and refuses
  outright (rather than proceeding) if it can't determine which generation
  that is, since "unknown" must mean "refuse," not "allow."
- "Booted" means what the machine actually booted (`/run/booted-system`),
  **not** the system profile's head. They differ in exactly the situation
  this tool is for: a `nixos-rebuild boot`/`switch` that dies with `ENOSPC`
  has already advanced the profile head to a new generation that never
  made it onto the boot menu, while you're still running an older one. The
  picker marks the booted generation `(booted)` and adds a header line
  naming the profile head when the two disagree. Also protected from eviction: the
  running generation if you've `switch`ed since booting, the profile head
  (nix-env can't delete it anyway), and any generation with the exact same
  store path as the booted one (on systemd-boot the `LoaderEntrySelected`
  EFI variable pins down which duplicate you really booted; Limine and GRUB
  have no equivalent, so every duplicate is kept).
- "Booted" and "running" are also different things. **Booted**
  (`/run/booted-system`) is what the machine started from — fixed until
  the next reboot, and it's what decides which kernel/initrd are loaded.
  **Running** (`/run/current-system`) is what's activated right now —
  `nixos-rebuild switch` (or `test`) changes it without a reboot, moving
  services, `/etc` and the system path to the new generation while the
  old kernel stays loaded. They only differ after a `switch` without a
  reboot; the picker then marks both, e.g. `(running)` on the new
  generation and `(booted)` on the one you started from, which also tells
  you at a glance that a reboot is pending. When they're the same
  generation, only `(booted)` is shown. Both are protected: evicting the
  booted one could remove the boot entry you came in on, and evicting the
  running one would delete the system you're actually using.
- Pruning (`p`) the profile head — typically the generation that filled
  `/boot` — offers to point the profile back at the booted generation first
  (`nix-env --switch-generation`, which only moves the profile symlink;
  nothing is activated and `/boot` isn't touched), since nix-env refuses to
  delete a profile's head.
- Never lets the boot menu drop below 2 kept generations (booted + at
  least 1 other), even in `--apply` mode, no override.
- `--apply` backs up the affected boot-menu config first (timestamped,
  next to the original — the whole shared config file on Limine and GRUB,
  or just the one entry file on systemd-boot), validates the predicted
  post-removal state — kept-generation count, booted generation still
  present, evicted generation truly gone — *before* writing anything, and
  only writes if every check passes.
- Confirmed on real hardware (Limine) and, since, real VMs for both other
  backends: after evicting a generation and rebuilding normally, NixOS
  regenerates the boot-menu config from scratch and correctly self-heals
  on top of the manual edit (the evicted generation stays gone; the
  next-oldest kept generation slides in to fill its slot) — the manual
  edit is a temporary bridge, not a lasting state. On a real GRUB VM,
  harvesting two generations down to the 2-kept floor worked cleanly and
  the guardrail correctly refused going any lower — see
  [Caveats](#caveats).

---

## Requirements

- NixOS with Limine, systemd-boot, or GRUB as the bootloader
- `jq`, `fzf` (provided automatically if run via `nix run`)
- `sudo` access (for reading the boot-menu config, and for
  `boot-gardener rescue --apply`'s file operations)

## Caveats

- **systemd-boot and GRUB support are newer and less battle-tested than the
  Limine path**, which is still the only one confirmed across a real
  reboot after eviction (see [Guardrails](#guardrails) above) — both
  backends have been through the same design/guardrail scenarios in a
  simulated `/boot` plus a real VM, but not yet a real reboot afterward.
  The systemd-boot backend was confirmed on a real systemd-boot VM
  (harvest correctly detected real `/boot/loader/entries/` entries and
  evicted cleanly, guardrails held). The GRUB backend was confirmed on a
  real GRUB VM the same way (harvested two generations down to the
  2-kept floor, which then correctly refused a third). Still worth
  running `rescue` (without `--apply`) and `--evict N` (still without
  `--apply`) first on a new machine to sanity-check the report against
  what you actually expect before trusting `--apply`.
- **Pinning doesn't exist on systemd-boot or GRUB yet** — see
  [Bootloader support](#bootloader-support) above. `p`/`h`/`g` are
  unaffected.

- If a generation's store paths have already been garbage-collected
  (`nix-collect-garbage -d`), `boot-gardener` can't pin it — the files
  simply aren't there anymore.
- Pinned entries reference `/nix/store` paths directly (plus, per above,
  their entire transitive closure). If you GC aggressively, consider
  rooting a pinned generation if you want its paths to reliably survive.
- **Observed once, not reproduced or root-caused:** on a fresh GRUB VM
  test session, KDE's admin-mode save prompt (Kate editing
  `/etc/nixos/configuration.nix` via KAuth/`pkexec`) flashed on screen for
  only a second or two and vanished before a password could be entered;
  editing the same file with `sudoedit`/`nano` in a terminal worked fine,
  and Kate's admin save worked normally again after a reboot. Nothing in
  `boot-gardener`/`rescue.sh` touches PolicyKit, KAuth, or Kate's own auth
  path (they only call `sudo` directly for their own reads/writes), so
  this doesn't look like a `boot-gardener` bug — more likely a KDE
  polkit-agent hiccup that happened to show up mid-session. Noted here in
  case it recurs; no fix attempted.
