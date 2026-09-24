#!/usr/bin/env bash
# gardener — browse NixOS generations, and pin one to the Limine
# bootloader via a small generated JSON file, consumed by
# limine-manual-pins.nix (custom.limineManualPins = builtins.fromJSON
# (builtins.readFile ./limine-pins.json);).
#
# This script ONLY ever reads/rewrites its own pins JSON file in full.
# It never touches any other file in your config, never runs git, and
# never triggers a rebuild — review the diff and rebuild the same way
# you always do.
#
# The exceptions are 'p' (prune), 'h' (harvest), and 'g' (garbage-collect)
# at the generation list. 'p' and 'h' are opposite ends of removing a
# generation, gated on whether it's currently in the boot menu: 'p' only
# works on generations NOT in the boot menu (plain
# 'nix-env -p .../system --delete-generations') and 'h' only works on
# generations THAT ARE in the boot menu (shells out to the sibling
# rescue.sh --evict GEN --apply, which owns all the real work
# and guardrails for evicting a generation from the boot menu and
# reclaiming /boot space). 'g' shells out to the same rescue script for its
# zero-risk Phase 1 orphan report/cleanup, then runs plain Nix garbage
# collection for anything left over from nix-shell/nix develop sessions or
# stray build results. None of the three touch the generation list itself
# or any file this tool doesn't already document.
#
# Bootloader (Limine, systemd-boot, or GRUB) is auto-detected from what's
# on /boot; pass --bootloader to override. 'p'/'h'/'g' work the same on
# all three. Pinning ('Enter') is Limine-only for now — it writes Nix-level
# config consumed by limine-manual-pins.nix, which has no systemd-boot or
# GRUB equivalent yet — so on those, Enter explains this and does nothing
# else.
set -euo pipefail

OUTPUT="limine-pins.json"
ACTION="add"
REMOVE_NAME=""
BOOTLOADER_OVERRIDE=""
YIELD_ENABLED=1

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
RESCUE_SCRIPT="$(dirname "$SELF")/rescue.sh"
# shellcheck source=./boot-backend.sh
source "$(dirname "$SELF")/boot-backend.sh"

usage() {
  cat <<'EOF'
boot-gardener — browse NixOS generations, and pin one to Limine

Usage:
  boot-gardener                      Interactively pick a generation --
                                     Enter to pin it (Limine only) or, on a
                                     pin row, to unpin it; 'p' to prune a
                                     non-bootloader generation; 'h' to
                                     harvest a bootloader generation (Tab
                                     to select several first for 'p'/'h');
                                     'g' to garbage-collect (no selection
                                     needed); '?' to toggle this help
  boot-gardener --list               List currently pinned entries
  boot-gardener --remove NAME        Remove a pinned entry by name
  boot-gardener --output FILE        Use a different pins file (default: ./limine-pins.json)
  boot-gardener --bootloader limine|systemd-boot|grub
                                     Skip auto-detection and use this backend
  boot-gardener --no-yield           Don't compute the YIELD column (faster
                                     startup; the column shows '?')
  boot-gardener --help               Show this help

The YIELD column estimates how much Nix store space removing that
generation would free: the combined size of the store paths that only
that generation uses (nothing else on the system -- no other generation,
no pin, no user profile, no result link -- references them). Prune ('p')
or harvest ('h') removes the generation; the space itself only comes back
after the next garbage collection ('g'). It's an upper bound: store
deduplication (auto-optimise-store) can make the real saving smaller. An
identical rebuild of another generation shows 0 B, because the two share
everything.

Bootloader (Limine, systemd-boot, or GRUB) is auto-detected from what's on
/boot. 'p'/'h'/'g' work the same on all three. Pinning ('Enter') is
Limine-only for now -- it writes Nix-level config consumed by
limine-manual-pins.nix, which has no systemd-boot or GRUB equivalent yet --
so on those, Enter explains this and does nothing else.

The pins file is always fully rewritten (never patched in place) and kept
sorted by name, so it stays clean and diffable in git.

Tab-select multiple generations before pressing 'p' or 'h' to act on all of
them in one go, each with its own confirmation. Enter (pin or unpin)
always applies to exactly one row at a time. 'g' ignores selection
entirely -- it's a global cleanup, not a per-generation action.

Pin rows (📌) are listed alongside generation rows, independent of whether
the pin's source generation still exists in the system profile -- a pin
captures store paths directly and is meant to outlive the generation it
was pinned from being pruned/GC'd, so it stays selectable (for unpinning
via Enter) even then.

'p' (prune) and 'h' (harvest) are opposite ends of removing a generation,
and each only works on the kind of generation the other doesn't:

  - 'p' only works on a generation that is NOT currently in the boot
    menu. It just deletes that generation from the NixOS system
    profile (nix-env -p .../system --delete-generations) -- it doesn't
    touch /boot at all, so the space isn't reclaimed until your next
    garbage collection ('g'). Pressing 'p' on a generation that IS in
    the boot menu refuses with a message telling you to harvest it
    instead.

  - 'h' only works on a generation that IS currently in the boot
    menu. It runs 'boot-gardener rescue --evict GEN --apply' on it directly
    -- removes the generation's boot-menu entry *and* deletes the /boot
    files that entry orphans, immediately reclaiming that space
    (rather than waiting on a GC + rebuild). Same guardrails as running
    rescue by hand: refuses the currently-booted generation, refuses to
    drop below 2 kept generations, backs up the affected boot-menu config
    first, and requires typed confirmation. Pressing 'h' on a generation
    that is NOT in the boot menu refuses with a message telling you to
    prune it instead.

'g' garbage-collects leftovers that aren't tied to any one generation: it
reports (then, with confirmation, deletes) orphaned /boot files via
'boot-gardener rescue', and runs plain Nix garbage collection for anything left
over from nix-shell/nix develop sessions or stray build results, plus
anything freed up by a prior 'p'. It never deletes a generation from the
system profile itself and never touches the boot-menu config.

'q' or Esc at the generation list quits the tool entirely, as does Ctrl-C
at any point. 'q' at a follow-up prompt or confirmation (pin, prune,
harvest, gc) only cancels that one action and returns you to the list --
nothing is written or deleted for it, but the tool keeps running so you can
pick something else.

Every pin/prune/harvest/gc outcome -- whether it succeeded, was refused by
a guardrail, or was cancelled -- ends on a "Press Enter to return to the
list..." pause before the list redraws, so a refusal or error message
never gets wiped off the screen before you've read it.
EOF
}

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Error: '$1' is required but not found in PATH." >&2
    exit 1
  }
}

abort() {
  echo
  echo "Aborted. No changes made."
  exit 0
}

trap abort INT

# Called after every pin/unpin/prune/harvest/gc outcome -- success, refusal,
# or cancellation alike -- right before the main loop redraws the
# full-screen generation list. Without this, a message that doesn't already
# end on its own interactive prompt (most refusals: "generation N is on the
# bootloader and cannot be pruned", the 2-kept-generation floor, "not a
# generation -- pins aren't pruned", etc.) gets wiped off the terminal by
# fzf's next redraw before there's any real chance to read it -- fzf takes
# over the whole screen again, and nothing before this pause held it still.
# '|| true' so Ctrl-D (EOF on the read) doesn't trip `set -e`.
pause_after_action() {
  echo
  read -rp "Press Enter to return to the list... " _ || true
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)
      ACTION="list"
      shift
      ;;
    --remove)
      ACTION="remove"
      REMOVE_NAME="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT="${2:-}"
      shift 2
      ;;
    --bootloader)
      BOOTLOADER_OVERRIDE="${2:-}"
      shift 2
      ;;
    --no-yield)
      YIELD_ENABLED=0
      shift
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

require jq

[[ -f "$OUTPUT" ]] || echo "[]" >"$OUTPUT"

if [[ "$ACTION" == "list" ]]; then
  {
    printf 'NAME\tTITLE\tCOMMENT\n'
    jq -r '.[] | "\(.name)\t\(.title)\t\(.comment)"' "$OUTPUT"
  } | column -t -s $'\t'
  exit 0
fi

if [[ "$ACTION" == "remove" ]]; then
  [[ -n "$REMOVE_NAME" ]] || {
    echo "Error: --remove requires a NAME" >&2
    exit 1
  }
  tmp=$(mktemp)
  jq --arg name "$REMOVE_NAME" \
    '[ .[] | select(.name != $name) ] | sort_by(.name)' \
    "$OUTPUT" >"$tmp"
  mv "$tmp" "$OUTPUT"
  echo "Removed '$REMOVE_NAME' from $OUTPUT (if it existed)."
  exit 0
fi

require fzf
backend_init "$BOOTLOADER_OVERRIDE"
# Always pass the resolved bootloader through to the rescue script
# explicitly, rather than letting it auto-detect a second time -- keeps
# the picker and rescue in agreement even if an override was given here.
RESCUE_ARGS=(--bootloader "$BOOTLOADER")

HELP_FILE=$(mktemp)
# Session-only cache for the YIELD column: one file per generation's
# closure, keyed by its toplevel store path (immutable, so a cached closure
# never goes stale). Only new generations cost anything on later redraws.
YIELD_DIR=$(mktemp -d)
trap 'rm -f "$HELP_FILE"; rm -rf "$YIELD_DIR"' EXIT
cat >"$HELP_FILE" <<EOF
Gardener -- key reference (bootloader: $BOOTLOADER)

  Enter    On a generation row: pin it (asks for a short name, a menu
           title, and an optional comment). Limine only -- on
           systemd-boot or GRUB this explains why and does nothing else.
           On a pin row (📌, shown even if its source generation is
           gone from the system profile): unpin it -- removes it from
           the pins file, then optionally rebuilds. One row at a time.

  Tab      Mark the highlighted generation for a multi-select action
           (p or h). Shift-Tab unmarks it.

  p        Prune the marked generation(s) -- ONLY works on generations
           NOT currently in the boot menu. Deletes them from the
           NixOS system profile; doesn't touch /boot, so run 'g'
           afterward to reclaim the space. On a generation that IS in
           the boot menu, refuses and tells you to harvest it instead.
           Typed confirmation required per generation.

  h        Harvest the marked generation(s) -- ONLY works on generations
           currently in the boot menu. Evicts from the boot menu AND
           deletes the /boot files that entry alone was using,
           reclaiming the space immediately. Refuses the
           currently-booted generation and refuses to drop below 2 kept
           generations. On a generation that is NOT in the boot menu,
           refuses and tells you to prune it instead. Typed confirmation
           required per generation.

  g        Garbage-collect. Ignores selection entirely -- global cleanup,
           not tied to any one generation. Reports (then, with
           confirmation, deletes) orphaned /boot files, and runs plain
           Nix garbage collection for nix-shell/nix develop leftovers,
           stray build results, and anything freed up by a prior 'p'.
           Never touches the system profile or the boot menu config.

  ?        Toggle this help.

  YIELD    (column) Roughly how much Nix store space removing that
           generation would free: the paths nothing else on the system
           uses. The space only comes back after 'g'. 0 B means an
           identical or near-identical generation shares everything with
           it, so removing it alone frees almost nothing. Upper bound --
           store deduplication can make the real saving smaller.

  q / Esc  Quit the tool entirely (as does Ctrl-C, any time). 'q' at a
           prompt or confirmation instead cancels just that one action
           and returns you here.

Every outcome above -- success, refusal, or cancellation -- pauses on
"Press Enter to return to the list..." before this screen redraws, so
nothing gets wiped off the terminal before you've read it.

Pinning captures store paths directly, so a pin outlives its source
generation being pruned/GC'd from the system profile -- that's the point.
Pin rows (📌) are listed independent of whether a matching generation row
exists, so you can always unpin something even long after its generation
is gone.
EOF

# Prompts for one line of input. Prints to stdout via a result var. Returns 1
# (without setting the result var) if the user types 'q'/'Q' -- callers treat
# that as "cancel this action, back to the picker", not "quit the tool".
prompt() {
  local message="$1" default="$2" __resultvar="$3" input
  read -rp "$message" input
  if [[ "$input" == "q" || "$input" == "Q" ]]; then
    return 1
  fi
  printf -v "$__resultvar" '%s' "${input:-$default}"
}

pin_generation() {
  local GEN="$1" LINK="$2" TARGET="$3"
  local KERNEL_PATH INITRD_PATH INIT_PATH CMDLINE GEN_DATE
  local DEFAULT_NAME DEFAULT_TITLE NAME TITLE COMMENT tmp

  if ! backend_supports_pin; then
    echo
    echo "Pinning isn't supported on $BOOTLOADER yet -- it writes Nix-level" >&2
    echo "config consumed by limine-manual-pins.nix, which has no $BOOTLOADER" >&2
    echo "equivalent. 'p'/'h'/'g' all work normally here." >&2
    return 1
  fi

  for f in kernel initrd init; do
    if [[ ! -e "$TARGET/$f" ]]; then
      echo "Error: $TARGET/$f not found. This generation may be incomplete," \
        "or its store paths may have been garbage-collected." >&2
      return 1
    fi
  done

  KERNEL_PATH=$(readlink -f "$TARGET/kernel")
  INITRD_PATH=$(readlink -f "$TARGET/initrd")
  INIT_PATH=$(readlink -f "$TARGET/init")

  CMDLINE=""
  [[ -f "$TARGET/kernel-params" ]] && CMDLINE=$(cat "$TARGET/kernel-params")

  GEN_DATE=$(date -d "@$(stat -c %Y "$LINK")" "+%Y-%m-%d" 2>/dev/null || echo "")

  DEFAULT_NAME="gen-${GEN}"
  DEFAULT_TITLE="NixOS (gen ${GEN} — ${GEN_DATE})"

  prompt "Short id [no spaces] (press enter for: ${DEFAULT_NAME}) [q to cancel, back to menu]: " "$DEFAULT_NAME" NAME ||
    { echo "Cancelled pinning generation $GEN. Back to the picker."; return 1; }
  prompt "Menu title (press enter for: ${DEFAULT_TITLE}) [q to cancel, back to menu]: " "$DEFAULT_TITLE" TITLE ||
    { echo "Cancelled pinning generation $GEN. Back to the picker."; return 1; }
  prompt "Comment (optional) [q to cancel, back to menu]: " "" COMMENT ||
    { echo "Cancelled pinning generation $GEN. Back to the picker."; return 1; }

  if jq -e --arg name "$NAME" '.[] | select(.name == $name)' "$OUTPUT" >/dev/null; then
    echo "Note: an entry named '$NAME' already exists in $OUTPUT and will be replaced."
  fi

  tmp=$(mktemp)
  jq \
    --arg name "$NAME" \
    --arg title "$TITLE" \
    --arg comment "$COMMENT" \
    --arg kernelPath "$KERNEL_PATH" \
    --arg initrdPath "$INITRD_PATH" \
    --arg init "$INIT_PATH" \
    --arg cmdline "$CMDLINE" \
    '(
       [ .[] | select(.name != $name) ]
       + [ { name: $name, title: $title, comment: $comment,
             kernelPath: $kernelPath, initrdPath: $initrdPath,
             init: $init, cmdline: $cmdline } ]
     ) | sort_by(.name)' \
    "$OUTPUT" >"$tmp"
  mv "$tmp" "$OUTPUT"

  echo
  echo "Pinned generation $GEN as '$NAME' in $OUTPUT."
  echo "Review the diff, then rebuild normally."

  local REBUILD_CONFIRM
  read -rp "Rebuild now with 'nh os boot . -- --impure'? [yes/N]: " REBUILD_CONFIRM
  if [[ "$REBUILD_CONFIRM" == "yes" ]]; then
    nh os boot . -- --impure
  else
    echo
    echo "⚠️  This repo now has an active pin — your next rebuild MUST include --impure, e.g.:"
    echo "    nh os switch . -- --impure"
  fi
}

unpin_generation() {
  local NAME="$1" CONFIRM REMAINING REBUILD_CONFIRM tmp

  echo
  echo "Unpinning '$NAME': removing it from $OUTPUT."
  echo "(This only edits the pins file -- nothing in /boot or your boot menu"
  echo "changes until you rebuild.)"
  echo

  read -rp "Remove pin '$NAME' from $OUTPUT? [yes/N]: " CONFIRM
  if [[ "$CONFIRM" != "yes" ]]; then
    echo "Skipped. '$NAME' was not removed."
    return 1
  fi

  tmp=$(mktemp)
  jq --arg name "$NAME" \
    '[ .[] | select(.name != $name) ] | sort_by(.name)' \
    "$OUTPUT" >"$tmp"
  mv "$tmp" "$OUTPUT"

  echo
  echo "Removed '$NAME' from $OUTPUT."
  echo "Review the diff, then rebuild normally."

  REMAINING=$(jq 'length' "$OUTPUT")
  if [[ "$REMAINING" -gt 0 ]]; then
    read -rp "Rebuild now with 'nh os switch . -- --impure'? [yes/N]: " REBUILD_CONFIRM
    if [[ "$REBUILD_CONFIRM" == "yes" ]]; then
      nh os switch . -- --impure
    fi
    echo
    echo "$REMAINING pin(s) still remain in $OUTPUT, so every rebuild still needs --impure."
  else
    read -rp "Rebuild now with 'nh os switch .'? [yes/N]: " REBUILD_CONFIRM
    if [[ "$REBUILD_CONFIRM" == "yes" ]]; then
      nh os switch .
    fi
    echo
    echo "$OUTPUT is back to [] -- your next rebuild no longer needs --impure."
  fi
  echo
  echo "Known quirk: if 'switch' doesn't actually clear this entry from the"
  echo "boot menu, try 'nh os boot' instead (append '-- --impure' too if any"
  echo "pins remain) -- confirmed to work when switch alone didn't."
}

gc_orphans_and_leftovers() {
  local CONFIRM
  # Global action -- not tied to whatever's selected in the list. Two parts:
  # 1) boot orphans (delegated entirely to rescue.sh's own Phase 1
  #    report/apply, same as running it by hand with no --evict);
  # 2) plain Nix GC for anything left over from nix-shell/nix develop
  #    sessions or stray build results, which never touches a generation
  #    or the boot menu config at all -- just dead store paths.
  echo
  echo "== Boot orphans (files referenced by nothing on the boot menu) =="
  if [[ -x "$RESCUE_SCRIPT" ]]; then
    "$RESCUE_SCRIPT" "${RESCUE_ARGS[@]}" || true
  else
    echo "  (rescue.sh not found alongside this script -- skipping)" >&2
  fi

  echo
  echo "== Nix store: dead paths (nix-shell/nix develop leftovers, stray build results, etc.) =="
  require nix-store
  nix-store --gc --print-dead || true
  echo

  read -rp "Proceed with cleanup (delete the boot orphans above, then run nix-collect-garbage)? [yes/N]: " CONFIRM
  if [[ "$CONFIRM" != "yes" ]]; then
    echo "Skipped. Nothing was deleted."
    return 0
  fi

  if [[ -x "$RESCUE_SCRIPT" ]]; then
    echo
    echo "Deleting boot orphans (boot-gardener rescue --apply -- its own confirmation follows)..."
    "$RESCUE_SCRIPT" "${RESCUE_ARGS[@]}" --apply || echo "Note: boot-orphan cleanup was cancelled or found nothing to do -- continuing." >&2
  fi

  echo
  echo "Running nix-collect-garbage..."
  require nix-collect-garbage
  nix-collect-garbage

  echo
  echo "Done. This never touched the system profile or the boot-menu config --"
  echo "generations and pins are exactly as they were."
}

prune_generation() {
  local GEN="$1"
  local CONFIRM

  if [[ -n "${IN_BOOTLOADER[$GEN]:-}" ]]; then
    echo
    echo "Generation $GEN is on the bootloader and cannot be pruned. If you" >&2
    echo "want to remove generation $GEN, harvest it instead ('h')." >&2
    return 1
  fi

  if [[ -z "$BOOTED_GEN" ]]; then
    echo
    echo "Can't tell which generation is currently booted, so refusing to" >&2
    echo "prune anything (see 'boot-gardener rescue --evict N' for details)." >&2
    return 1
  fi

  if [[ "$GEN" == "$BOOTED_GEN" ]]; then
    echo
    echo "Generation $GEN is the currently-booted generation and can't be" >&2
    echo "pruned." >&2
    return 1
  fi

  if [[ -n "$RUNNING_GEN" && "$GEN" == "$RUNNING_GEN" ]]; then
    echo
    echo "Generation $GEN is the currently running (activated) generation and" >&2
    echo "can't be pruned." >&2
    return 1
  fi

  # nix-env refuses to delete the profile's own head. That's the one you
  # typically want gone after a rebuild died on a full /boot: it's the
  # generation that never made it onto the boot menu. Offer to point the
  # profile back at the booted generation first -- that only moves the
  # profile symlink; it doesn't activate anything or touch /boot.
  local ROLLBACK=0
  if [[ -n "$HEAD_GEN" && "$GEN" == "$HEAD_GEN" ]]; then
    echo
    echo "Generation $GEN is the system profile's head (what nixos-rebuild"
    echo "considers current), so nix-env can't delete it as-is. You're booted"
    echo "into generation $BOOTED_GEN."
    echo
    echo "To prune it, the profile first has to point back at generation"
    echo "$BOOTED_GEN (sudo nix-env -p /nix/var/nix/profiles/system"
    echo "--switch-generation $BOOTED_GEN). That only moves the profile symlink --"
    echo "it doesn't activate anything, touch /boot, or change what's running."
    echo
    read -rp "Roll the profile back to generation $BOOTED_GEN and prune generation $GEN? [yes/N]: " CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then
      echo "Skipped. Generation $GEN was not deleted."
      return 1
    fi
    ROLLBACK=1
  fi

  echo
  echo "Pruning generation $GEN: deleting it from the NixOS system profile."
  echo "(This does not touch /boot -- it just makes the"
  echo "generation eligible for garbage collection. Run 'g' afterward to"
  echo "actually reclaim the space.)"
  echo

  if [[ "$ROLLBACK" -eq 0 ]]; then
    read -rp "Delete generation $GEN from the system profile? [yes/N]: " CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then
      echo "Skipped. Generation $GEN was not deleted."
      return 1
    fi
  fi

  require sudo
  if [[ "$ROLLBACK" -eq 1 ]]; then
    if ! sudo nix-env -p /nix/var/nix/profiles/system --switch-generation "$BOOTED_GEN"; then
      echo "Couldn't switch the profile back to generation $BOOTED_GEN -- nothing was deleted." >&2
      return 1
    fi
    echo "Profile now points at generation $BOOTED_GEN."
    HEAD_GEN="$BOOTED_GEN"
  fi
  sudo nix-env -p /nix/var/nix/profiles/system --delete-generations "$GEN"
  echo
  echo "Generation $GEN removed from the system profile."
}

harvest_generation() {
  local GEN="$1"

  echo
  echo "Harvesting generation $GEN: evicting it from the boot menu and"
  echo "reclaiming the /boot space it alone was using."
  echo "(This runs 'boot-gardener rescue --evict $GEN --apply' -- see its own"
  echo "confirmation prompts below for exactly what that does. 'q' there just"
  echo "skips this generation and returns you to the picker.)"
  echo

  if [[ ! -x "$RESCUE_SCRIPT" ]]; then
    echo "Error: expected rescue.sh alongside this script at:" >&2
    echo "  $RESCUE_SCRIPT" >&2
    return 1
  fi

  # Run as a normal child process (not exec) so control returns to the
  # picker's menu loop afterward, whether this succeeds, is refused by
  # rescue's own guardrails, or is cancelled at one of its prompts.
  if "$RESCUE_SCRIPT" "${RESCUE_ARGS[@]}" --evict "$GEN" --apply; then
    return 0
  else
    echo "Harvest of generation $GEN did not complete (cancelled or refused) -- back to the picker." >&2
    return 1
  fi
}

# Human-readable byte count, binary units (matches the README's GiB figures).
fmt_bytes() {
  awk -v b="$1" 'BEGIN {
    if (b < 1) { print "0 B"; exit }
    split("B KiB MiB GiB TiB", u, " "); i = 1
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    printf (i == 1 ? "%d %s\n" : "%.1f %s\n"), b, u[i]
  }'
}

# Fills YIELD[gen] with the bytes of store paths ONLY that generation
# references -- i.e. what pruning/harvesting it, then running 'g', would
# free. Every other generation counts as a separate owner, and so does
# everything else that keeps store paths alive (user/home-manager profiles,
# result links, /run/current-system, /run/booted-system, running processes)
# lumped together as one '@other' owner. Pins need no special handling:
# the current system's closure already contains each pin's init script,
# and that closure is owned by several generations plus /run/current-system.
#
# Read-only throughout. Returns 1 (leaving YIELD empty) if anything needed
# is missing or the numbers can't be trusted, and the column shows '?'.
declare -A YIELD=()
compute_yields() {
  YIELD=()
  command -v nix-store >/dev/null 2>&1 || return 1

  local link gen top base
  local owners="$YIELD_DIR/owners" unique="$YIELD_DIR/unique"
  local sizes="$YIELD_DIR/sizes" roots="$YIELD_DIR/roots"
  local -a missing=() gen_list=() top_list=()

  for link in "${LINKS[@]}"; do
    gen=$(basename "$link" | sed -E 's/system-([0-9]+)-link/\1/')
    top=$(readlink -f "$link" 2>/dev/null) || continue
    [[ -e "$top" ]] || continue
    gen_list+=("$gen")
    top_list+=("$top")
    base=$(basename "$top")
    [[ -s "$YIELD_DIR/c-$base" ]] || missing+=("$top")
  done
  [[ ${#gen_list[@]} -gt 0 ]] || return 1

  # 1) Closures not cached yet this session, in parallel. Generations
  #    sharing one toplevel are only queried once.
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Measuring YIELD for ${#missing[@]} generation(s) (only new ones are measured on later redraws)..." >&2
    printf '%s\n' "${missing[@]}" | sort -u |
      xargs -r -P "$(nproc 2>/dev/null || echo 4)" -I{} sh -c \
        'b=$(basename "$1"); nix-store -qR "$1" >"$2/c-$b.tmp" 2>/dev/null && mv "$2/c-$b.tmp" "$2/c-$b"' \
        _ {} "$YIELD_DIR" || true
  fi

  : >"$owners"
  local i
  for i in "${!gen_list[@]}"; do
    base=$(basename "${top_list[$i]}")
    # A generation whose closure couldn't be read would make everything it
    # shares with others look unique to them -- refuse rather than guess.
    [[ -s "$YIELD_DIR/c-$base" ]] || return 1
    awk -v g="${gen_list[$i]}" '{ print g " " $0 }' "$YIELD_DIR/c-$base" >>"$owners"
  done

  # 2) Everything else keeping store paths alive. Every system-profile link
  #    is already counted above, per generation. Non-root users see some
  #    roots as '{censored}', but the store path they point to is still
  #    shown, which is all that's needed here. Newer Nix versions print the
  #    link path in double quotes ("/nix/var/.../system-155-link" -> ...),
  #    older ones don't -- strip them either way before matching, or every
  #    generation gets counted a second time as '@other' and all yields
  #    come out 0 B.
  nix-store --gc --print-roots 2>/dev/null |
    awk -F' -> ' '{ l = $1; gsub(/^"|"$/, "", l); t = $2; gsub(/^"|"$/, "", t) }
                  l !~ /^\/nix\/var\/nix\/profiles\/system(-[0-9]+-link)?$/ { print t }' |
    sed -nE 's|^(/nix/store/[^/]+).*|\1|p' | sort -u >"$roots" || true
  if [[ -s "$roots" ]]; then
    while read -r p; do [[ -e "$p" ]] && printf '%s\n' "$p"; done <"$roots" |
      xargs -r nix-store -qR 2>/dev/null | sort -u |
      awk '{ print "@other " $0 }' >>"$owners" || true
  fi

  # 3) Paths exactly one owner references, when that owner is a generation.
  #    Each generation's closure lists a path at most once, so a line count
  #    per path is an owner count.
  awk '{ c[$2]++; o[$2] = $1 }
       END { for (p in c) if (c[p] == 1 && o[p] != "@other") print o[p], p }' \
    "$owners" >"$unique"

  # 4) Sizes (NAR size, same measure 'nh os info' uses for closure size).
  #    nix-store prints one size per path, in order, so the two columns line
  #    up -- verified by line count before trusting the pairing.
  if [[ -s "$unique" ]]; then
    cut -d' ' -f2 "$unique" | xargs -r nix-store -q --size >"$sizes" 2>/dev/null || return 1
    [[ $(wc -l <"$sizes") -eq $(wc -l <"$unique") ]] || return 1
  else
    : >"$sizes"
  fi

  for gen in "${gen_list[@]}"; do YIELD["$gen"]=0; done
  local g s
  while read -r g s; do
    [[ -n "$g" ]] && YIELD["$g"]="$s"
  done < <(paste -d' ' <(cut -d' ' -f1 "$unique") "$sizes" |
    awk '{ t[$1] += $2 } END { for (g in t) printf "%s %.0f\n", g, t[g] }')
  return 0
}

require fzf

# Main loop: redisplay the generation picker after every completed or
# cancelled action, so only 'q'/Esc *at the list itself* (or Ctrl-C, any
# time) actually exits the tool.
while true; do
  # Booted vs. running vs. profile-head generation -- see
  # resolve_running_generations in boot-backend.sh. They're normally the
  # same number, but after a rebuild dies with ENOSPC on a full /boot, the
  # profile head points at a generation that never reached the boot menu
  # while the machine is still running the older one it booted. Marking the
  # head "(current)" there was wrong, and made rescue/harvest refuse to run.
  resolve_running_generations

  declare -A IN_BOOTLOADER=()
  BOOT_COUNT=0

  # Captured into a variable (rather than the previous
  # `< <(backend_kept_generations_lenient)`) specifically so its exit
  # status is checkable -- process substitution silently discards a
  # command's exit status, which previously meant a failed boot-menu read
  # was indistinguishable from a genuinely empty one: every generation
  # would look not-in-bootloader with no indication anything went wrong.
  BOOT_READ_OK=1
  BOOT_LIST=""
  BOOT_LIST=$(backend_kept_generations_lenient) || BOOT_READ_OK=0

  while read -r bgen; do
    if [[ -n "$bgen" ]]; then
      IN_BOOTLOADER["$bgen"]=1
      BOOT_COUNT=$((BOOT_COUNT + 1))
    fi
  done <<<"$BOOT_LIST"

  # Surface a failed read loudly, and PAUSE for it -- same reasoning as
  # pause_after_action (see its comment above): a message printed right
  # before fzf redraws the full-screen list gets wiped before there's any
  # real chance to read it. Without this pause, a failed read here just
  # silently presents as "0 in bootloader", which looks identical to a
  # genuinely empty boot menu but makes every generation look safe to
  # prune ('p') and makes harvest ('h') refuse everything.
  if [[ "$BOOT_READ_OK" -eq 0 ]]; then
    echo
    echo "⚠️  Could not read the boot menu -- see the 'Note:' above for why" >&2
    echo "   (usually a permissions problem reading under /boot, or a sudo" >&2
    echo "   prompt that didn't go through). The '0 in bootloader' you're" >&2
    echo "   about to see is NOT a confirmed-empty boot menu -- it's an" >&2
    echo "   UNREADABLE one. Until this is fixed:" >&2
    echo "     - every generation will look prunable ('p'), even ones that" >&2
    echo "       are really still on the boot menu" >&2
    echo "     - 'h' (harvest) will refuse every generation" >&2
    pause_after_action
  fi

  shopt -s nullglob
  LINKS=(/nix/var/nix/profiles/system-*-link)
  shopt -u nullglob

  if [[ ${#LINKS[@]} -eq 0 ]]; then
    echo "No generations found under /nix/var/nix/profiles/. Are you on NixOS?" >&2
    exit 1
  fi

  YIELD_OK=0
  if [[ "$YIELD_ENABLED" -eq 1 ]]; then
    compute_yields && YIELD_OK=1
  fi

  ROWS=()
  for link in "${LINKS[@]}"; do
    gen=$(basename "$link" | sed -E 's/system-([0-9]+)-link/\1/')
    target=$(readlink -f "$link" 2>/dev/null || true)
    [[ -n "$target" && -e "$target" ]] || continue

    gen_date=$(date -d "@$(stat -c %Y "$link")" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "unknown")

    nixos_ver="?"
    [[ -f "$target/nixos-version" ]] && nixos_ver=$(cat "$target/nixos-version")

    kernel_ver="?"
    if [[ -e "$target/kernel" ]]; then
      resolved_kernel=$(readlink -f "$target/kernel" 2>/dev/null || true)
      kernel_dir=$(basename "$(dirname "$resolved_kernel")" 2>/dev/null || true)
      # kernel_dir looks like "<hash>-linux-6.6.30" or "<hash>-linux-zen-7.1.9"
      # depending on kernelProvider -- strip the store hash + "linux-" prefix.
      [[ -n "$kernel_dir" ]] && kernel_ver="${kernel_dir#*-linux-}"
    fi

    marker=""
    if [[ -n "$BOOTED_GEN" && "$gen" == "$BOOTED_GEN" ]]; then
      marker=" (booted)"
    elif [[ -n "$RUNNING_GEN" && "$gen" == "$RUNNING_GEN" ]]; then
      marker=" (running)"
    fi

    boot_marker="-"
    [[ -n "${IN_BOOTLOADER[$gen]:-}" ]] && boot_marker="✓"

    yield_str="?"
    [[ "$YIELD_OK" -eq 1 && -n "${YIELD[$gen]:-}" ]] && yield_str=$(fmt_bytes "${YIELD[$gen]}")

    ROWS+=("${gen}"$'\t'"${boot_marker}"$'\t'"${yield_str}"$'\t'"${gen_date}"$'\t'"${nixos_ver}"$'\t'"${kernel_ver}${marker}")
  done

  # Pins are captured store paths, decoupled from the system profile on
  # purpose (that's the whole point -- they survive the source generation
  # being pruned/GC'd from the profile). So a pin whose source generation
  # is long gone from $LINKS above would otherwise never get a row here,
  # and there'd be no way to unpin it short of the standalone --remove
  # flag. List every current pin as its own row instead, independent of
  # whether $LINKS still has a matching entry -- marked 📌, with a
  # "pin:$name" id (instead of a bare generation number) so Enter below
  # can tell a pin row from a generation row and unpin instead of pin.
  PIN_ROWS=()
  if backend_supports_pin && [[ -f "$OUTPUT" ]]; then
    while IFS=$'\t' read -r pname ptitle; do
      [[ -n "$pname" ]] || continue
      pdate=$(grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' <<<"$ptitle" | head -n1)
      [[ -n "$pdate" ]] || pdate="-"
      PIN_ROWS+=("pin:${pname}"$'\t''📌'$'\t''-'$'\t'"${pdate}"$'\t''-'$'\t'"pinned: ${pname}")
    done < <(jq -r '.[] | "\(.name)\t\(.title)"' "$OUTPUT")
  fi

  BODY=$(
    {
      printf '%s\n' "${ROWS[@]}"
      if [[ ${#PIN_ROWS[@]} -gt 0 ]]; then
        printf '%s\n' "${PIN_ROWS[@]}"
      fi
    } | sort -t $'\t' -k1,1nr
  )

  # /boot fullness, recomputed every redraw since prune/harvest/gc change it
  # live. Plain `df` on the mountpoint doesn't need the sudo that reading
  # *into* /boot's contents elsewhere in this script does -- it only stats
  # the mountpoint itself.
  BOOT_USAGE=""
  if boot_df_line=$(df -h --output=used,avail,pcent /boot 2>/dev/null | tail -n1); then
    read -r boot_used boot_avail boot_pcent <<<"$boot_df_line"
    [[ -n "$boot_used" ]] && BOOT_USAGE="/boot: ${boot_used} used, ${boot_avail} free (${boot_pcent} full)"
  fi

  HEADER_TEXT="NixOS Generations (${#ROWS[@]} total, ${BOOT_COUNT} in bootloader, ${#PIN_ROWS[@]} pinned -- $BOOTLOADER)"
  [[ -n "$BOOT_USAGE" ]] && HEADER_TEXT="${HEADER_TEXT}"$'\n'"${BOOT_USAGE}"
  if [[ "$YIELD_ENABLED" -eq 1 && "$YIELD_OK" -eq 0 ]]; then
    HEADER_TEXT="${HEADER_TEXT}"$'\n'"YIELD unavailable (couldn't read store closures) -- column shows '?'"
  fi
  if [[ -n "$HEAD_GEN" && -n "$BOOTED_GEN" && "$HEAD_GEN" != "$BOOTED_GEN" ]]; then
    if [[ -z "${IN_BOOTLOADER[$HEAD_GEN]:-}" && "$BOOT_READ_OK" -eq 1 ]]; then
      HEADER_TEXT="${HEADER_TEXT}"$'\n'"Profile head is gen ${HEAD_GEN}, but it never made it onto the boot menu -- you booted gen ${BOOTED_GEN}"
    else
      HEADER_TEXT="${HEADER_TEXT}"$'\n'"Profile head is gen ${HEAD_GEN} (next boot's default) -- you booted gen ${BOOTED_GEN}"
    fi
  fi
  ENTER_LABEL="Enter:pin/unpin"
  backend_supports_pin || ENTER_LABEL="Enter:pin(Limine only)"
  FOOTER_TEXT="  q/Esc:quit   ${ENTER_LABEL}   Tab:multi-select   p:prune   h:harvest   g:gc   ?:help   ↑↓:move   Type to filter  "

  RAW=$(
    {
      printf 'GEN\tBOOT\tYIELD\tBUILT\tNIXOS VERSION\tKERNEL\n'
      printf '%s\n' "$BODY"
    } | column -t -s $'\t' -R 3 |
      fzf --style full \
        --layout reverse \
        --header-first \
        --header-lines=1 \
        --header "$HEADER_TEXT" \
        --border-label ' Gardener ' \
        --footer "$FOOTER_TEXT" \
        --multi \
        --bind 'q:abort' \
        --bind '?:toggle-preview' \
        --preview "cat '$HELP_FILE'" \
        --preview-window '~3,down,70%:hidden:wrap' \
        --expect=p,g,h
  ) || true

  KEY=$(head -n1 <<<"$RAW")
  SELECTED=$(tail -n +2 <<<"$RAW")

  if [[ "$KEY" == "g" ]]; then
    # Global action -- deliberately doesn't require (or care about) a
    # selection, since it isn't tied to any one generation.
    gc_orphans_and_leftovers || true
    pause_after_action
    continue
  fi

  [[ -n "$SELECTED" ]] || {
    echo "No generation selected."
    exit 0
  }

  mapfile -t SELECTED_GENS < <(awk '{print $1}' <<<"$SELECTED")

  if [[ "$KEY" == "p" ]]; then
    for GEN in "${SELECTED_GENS[@]}"; do
      if [[ "$GEN" == pin:* ]]; then
        echo
        echo "'${GEN#pin:}' is a pin, not a generation -- pins aren't pruned." >&2
        echo "Select it alone and press Enter to unpin it instead." >&2
        pause_after_action
        continue
      fi
      # '|| true': prune_generation returns 1 whenever it refuses (in the
      # boot menu, is the currently-booted generation) or is cancelled at
      # its own confirmation. That's meant to skip just this generation and
      # return to the picker, but a bare non-zero return here would trip
      # `set -e` and kill the whole tool instead.
      prune_generation "$GEN" || true
      pause_after_action
    done
    continue
  fi

  if [[ "$KEY" == "h" ]]; then
    for GEN in "${SELECTED_GENS[@]}"; do
      if [[ "$GEN" == pin:* ]]; then
        echo
        echo "'${GEN#pin:}' is a pin, not a generation -- pins aren't harvested." >&2
        echo "Select it alone and press Enter to unpin it instead." >&2
        pause_after_action
        continue
      fi
      if [[ -z "${IN_BOOTLOADER[$GEN]:-}" ]]; then
        echo
        echo "Generation $GEN is not on the bootloader, so there's nothing to" >&2
        echo "harvest. If you want to remove it, prune it instead ('p')." >&2
        pause_after_action
        continue
      fi
      # '|| true': harvest_generation returns 1 whenever the rescue script
      # it shells out to exits non-zero -- 'q' at any of rescue's own
      # confirmations, or one of rescue's own guardrail refusals (including
      # the 2-kept-generation floor). That's meant to abort just this
      # harvest and return to the picker, but a bare non-zero return here
      # would trip `set -e` and kill the whole tool instead.
      harvest_generation "$GEN" || true
      pause_after_action
    done
    continue
  fi

  # Enter -> pin (a generation row) or unpin (a pin row). Either way it
  # only makes sense one at a time -- multi-select is for 'p'/'h'.
  if [[ ${#SELECTED_GENS[@]} -gt 1 ]]; then
    echo
    echo "Pin/unpin only supports one row at a time -- you selected ${#SELECTED_GENS[@]}." >&2
    echo "Tab-select multiple generations for prune ('p') or harvest ('h') instead." >&2
    echo
    pause_after_action
    continue
  fi
  GEN="${SELECTED_GENS[0]}"

  if [[ "$GEN" == pin:* ]]; then
    unpin_generation "${GEN#pin:}" || true
    pause_after_action
    continue
  fi

  LINK="/nix/var/nix/profiles/system-${GEN}-link"
  TARGET=$(readlink -f "$LINK")
  echo "Selected generation $GEN -> $TARGET"
  # '|| true': pin_generation returns 1 on 'q' at any prompt (cancel, back
  # to the picker). Called bare like this under `set -e`, a non-zero
  # return would otherwise kill the whole script instead of just this
  # attempt -- see the same note above harvest_generation's call.
  pin_generation "$GEN" "$LINK" "$TARGET" || true
  pause_after_action
done
