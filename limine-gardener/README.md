# Limine Gardener

Pick a NixOS generation, then **pin** it to keep it bootable, **prune** it
from the profile, or **harvest** it to evict it from the boot menu and
reclaim its `/boot` space immediately — all from one scrollable list. Plus
a rescue tool for when `/boot` fills up and a normal rebuild can't even
run.

Two scripts under one command:

- **`limine-gardener`** — browse your system generations and pin one to the
  Limine boot menu (bypassing `maxGenerations` garbage collection), prune
  one from the profile, or harvest one (evict + reclaim its `/boot` space
  on the spot), from a single screen.
- **`limine-gardener rescue`** — diagnose and, if needed, fix a `/boot`
  partition that's full or close to it, by finding and safely removing
  files a normal rebuild can't reach because it doesn't have room to run.

Both are companions to a small NixOS module, `limine-manual-pins.nix` (not
included here — wire it into your own flake), which defines the
`custom.limineManualPins` option that actually builds the Limine menu entry
and copies files into `/boot`.

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

## Picking, pinning, pruning

### Usage

```bash
# Interactively pick a generation. Enter pins it, 'd' prunes it, 'h' harvests it.
nix run github:DanielTallon/nix-packages#limine-gardener

# Or run it directly:
limine-gardener --output ~/.dotfiles/limine-pins.json

# List what's currently pinned
limine-gardener --list

# Remove a pin by its name
limine-gardener --remove gen-144
```

The list shows generation number, date, NixOS/kernel version, and a `BOOT`
column marking which generations are currently referenced in your Limine
menu (reading `/boot/limine/limine.conf`, which needs `sudo` — you'll be
prompted once, up front).

- **Enter** on a generation pins it: resolves its `kernel`/`initrd`/`init`
  store paths and `kernel-params` cmdline automatically, then asks for a
  short name, a menu title, and an optional comment.
- **`d`** on a generation prunes it from the Nix profile
  (`nix-env --delete-generations`) — after typing the generation number back
  to confirm. This **never** touches `/boot` or runs garbage collection; run
  those yourself afterward if you want the space back. It also refuses
  outright to prune the currently-booted generation, no override.
- **`h`** on a generation **harvests** it: hands straight off to
  `limine-gardener rescue --evict GEN --apply` for that generation, which
  removes its entry from the Limine menu *and* deletes the `/boot` files
  that entry alone was using — reclaiming the space immediately rather than
  waiting on a later GC + rebuild. It inherits every guardrail `rescue`
  already has: refuses the currently-booted generation, refuses to drop
  below 2 kept generations, backs up `limine.conf` before touching it, and
  needs typed confirmation. See [Rescue mode](#rescue-mode) below for
  exactly what that confirmation flow looks like.
- **`q`** or **Esc** cancels at any point; so does Ctrl-C.

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

Referencing an existing generation's store paths is inherently impure —
those paths live only on your local machine and aren't declared anywhere in
your flake's inputs, so Nix's pure/flake evaluation mode refuses to touch
them (`error: 'builtins.storePath' is not allowed in pure evaluation mode`,
or `access to absolute path '...' is forbidden in pure evaluation mode`).
There's no way around this with a code change — it's fundamental to what
the feature does, not a bug in the module.

**Every rebuild, for as long as `limine-pins.json` has any entries, needs
`--impure`:**

```bash
nh os switch . -- --impure
# or, with plain nixos-rebuild:
sudo nixos-rebuild switch --flake .#yourhost --impure
```

Once you remove the last pin (`limine-pins.json` back to `[]`), the next
rebuild goes back to normal — no `--impure` needed.

**Known quirk:** pruning a pin and rebuilding with `switch` may not
actually clear the entry from the boot menu. If that happens, try `boot`
instead (`nh os boot . -- --impure`), which was confirmed to work when
`switch` alone didn't. Cause not diagnosed; this is just a documented
workaround.

### ⚠️ The real disk cost of a pin can be much bigger than the kernel

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
limine-gardener rescue

# Also preview evicting a specific kept generation's menu entry
limine-gardener rescue --evict 166

# Actually delete Phase 1 orphaned files (typed confirmation required)
limine-gardener rescue --apply

# Actually evict a generation and delete its now-orphaned files
# (types the generation number back, then 'yes', to confirm)
limine-gardener rescue --evict 166 --apply
```

### How it works

- **Phase 1 (zero risk):** parses every `kernel_path`/`module_path` line in
  `limine.conf` to find files in `/boot/limine/kernels/` that nothing
  currently references, and reports them. These are typically leftovers
  from a rebuild that died partway through. Deleting them never touches the
  boot menu.
- **Phase 2 (`--evict N`):** previews (or, with `--apply`, actually
  performs) cutting generation N's `//Generation N` block out of
  `limine.conf`, then re-checks what additional kernel/initrd files that
  makes orphaned — accounting for content-hash deduplication, since
  consecutive generations often share identical kernel builds and only the
  files that are genuinely no longer used by anything get deleted.

### Guardrails

- Never proposes evicting the currently-booted generation — and refuses
  outright (rather than proceeding) if it can't determine which generation
  that is, since "unknown" must mean "refuse," not "allow."
- Never lets the boot menu drop below 2 kept generations (current + at
  least 1 other), even in `--apply` mode, no override.
- `--apply` backs up `limine.conf` (timestamped, next to the original)
  before writing anything, validates the edit — marker counts, kept-
  generation count, current generation still present, evicted generation
  truly gone — and only writes if every check passes.
- Confirmed on real hardware: after evicting a generation and rebuilding
  normally, NixOS regenerates `limine.conf` from scratch and correctly
  self-heals on top of the manual edit (the evicted generation stays gone;
  the next-oldest kept generation slides in to fill its slot) — the manual
  edit is a temporary bridge, not a lasting state.

---

## Requirements

- NixOS with Limine as the bootloader
- `jq`, `fzf` (provided automatically if run via `nix run`)
- `sudo` access (for reading `/boot/limine/limine.conf`, and for
  `limine-gardener rescue --apply`'s file operations)

## Caveats

- If a generation's store paths have already been garbage-collected
  (`nix-collect-garbage -d`), `limine-gardener` can't pin it — the files
  simply aren't there anymore.
- Pinned entries reference `/nix/store` paths directly (plus, per above,
  their entire transitive closure). If you GC aggressively, consider
  rooting a pinned generation if you want its paths to reliably survive.
