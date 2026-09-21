#!/usr/bin/env bash
# limine-pin-picker — browse NixOS generations, and pin one to the Limine
# bootloader via a small generated JSON file, consumed by
# limine-manual-pins.nix (custom.limineManualPins = builtins.fromJSON
# (builtins.readFile ./limine-pins.json);).
#
# This script ONLY ever reads/rewrites its own pins JSON file in full.
# It never touches any other file in your config, never runs git, and
# never triggers a rebuild — review the diff and rebuild the same way
# you always do.
#
# The exceptions are 'd' (prune), 'h' (harvest), and 'g' (garbage-collect)
# at the generation list. 'd' and 'h' are opposite ends of removing a
# generation, gated on whether it's currently in the boot menu: 'd' only
# works on generations NOT in the boot menu (plain
# 'nix-env -p .../system --delete-generations') and 'h' only works on
# generations THAT ARE in the boot menu (shells out to the sibling
# limine-boot-rescue.sh --evict GEN --apply, which owns all the real work
# and guardrails for evicting a generation from the boot menu and
# reclaiming /boot space). 'g' shells out to the same rescue script for its
# zero-risk Phase 1 orphan report/cleanup, then runs plain Nix garbage
# collection for anything left over from nix-shell/nix develop sessions or
# stray build results. None of the three touch the generation list itself
# or any file this tool doesn't already document.
#
# Bootloader (Limine, systemd-boot, or GRUB) is auto-detected from what's
# on /boot; pass --bootloader to override. 'd'/'h'/'g' work the same on
# all three. Pinning ('Enter') is Limine-only for now — it writes Nix-level
# config consumed by limine-manual-pins.nix, which has no systemd-boot or
# GRUB equivalent yet — so on those, Enter explains this and does nothing
# else.
set -euo pipefail

OUTPUT="limine-pins.json"
ACTION="add"
REMOVE_NAME=""
BOOTLOADER_OVERRIDE=""

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
RESCUE_SCRIPT="$(dirname "$SELF")/limine-boot-rescue.sh"
# shellcheck source=./boot-backend.sh
source "$(dirname "$SELF")/boot-backend.sh"

usage() {
  cat <<'EOF'
limine-pin-picker — browse NixOS generations, and pin one to Limine

Usage:
  limine-pin-picker                 Interactively pick a generation --
                                     Enter to pin it (Limine only) or, on a
                                     pin row, to unpin it; 'd' to prune a
                                     non-bootloader generation; 'h' to
                                     harvest a bootloader generation (Tab
                                     to select several first for 'd'/'h');
                                     'g' to garbage-collect (no selection
                                     needed); '?' to toggle this help
  limine-pin-picker --list          List currently pinned entries
  limine-pin-picker --remove NAME   Remove a pinned entry by name
  limine-pin-picker --output FILE   Use a different pins file (default: ./limine-pins.json)
  limine-pin-picker --bootloader limine|systemd-boot|grub
                                     Skip auto-detection and use this backend
  limine-pin-picker --help          Show this help

Bootloader (Limine, systemd-boot, or GRUB) is auto-detected from what's on
/boot. 'd'/'h'/'g' work the same on all three. Pinning ('Enter') is
Limine-only for now -- it writes Nix-level config consumed by
limine-manual-pins.nix, which has no systemd-boot or GRUB equivalent yet --
so on those, Enter explains this and does nothing else.

The pins file is always fully rewritten (never patched in place) and kept
sorted by name, so it stays clean and diffable in git.

Tab-select multiple generations before pressing 'd' or 'h' to act on all of
them in one go, each with its own confirmation. Enter (pin or unpin)
always applies to exactly one row at a time. 'g' ignores selection
entirely -- it's a global cleanup, not a per-generation action.

Pin rows (📌) are listed alongside generation rows, independent of whether
the pin's source generation still exists in the system profile -- a pin
captures store paths directly and is meant to outlive the generation it
was pinned from being pruned/GC'd, so it stays selectable (for unpinning
via Enter) even then.

'd' (prune) and 'h' (harvest) are opposite ends of removing a generation,
and each only works on the kind of generation the other doesn't:

  - 'd' only works on a generation that is NOT currently in the boot
    menu. It just deletes that generation from the NixOS system
    profile (nix-env -p .../system --delete-generations) -- it doesn't
    touch /boot at all, so the space isn't reclaimed until your next
    garbage collection ('g'). Pressing 'd' on a generation that IS in
    the boot menu refuses with a message telling you to harvest it
    instead.

  - 'h' only works on a generation that IS currently in the boot
    menu. It runs 'limine-boot-rescue --evict GEN --apply' on it directly
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
limine-boot-rescue, and runs plain Nix garbage collection for anything left
over from nix-shell/nix develop sessions or stray build results, plus
anything freed up by a prior 'd'. It never deletes a generation from the
system profile itself and never touches the boot-menu config.

'q' or Esc at the generation list quits the tool entirely, as does Ctrl-C
at any point. 'q' at a follow-up prompt or confirmation (pin, prune,
harvest, gc) only cancels that one action and returns you to the list --
nothing is written or deleted for it, but the tool keeps running so you can
pick something else.
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
trap 'rm -f "$HELP_FILE"' EXIT
cat >"$HELP_FILE" <<EOF
Gardener -- key reference (bootloader: $BOOTLOADER)

  Enter    On a generation row: pin it (asks for a short name, a menu
           title, and an optional comment). Limine only -- on
           systemd-boot or GRUB this explains why and does nothing else.
           On a pin row (📌, shown even if its source generation is
           gone from the system profile): unpin it -- removes it from
           the pins file, then optionally rebuilds. One row at a time.

  Tab      Mark the highlighted generation for a multi-select action
           (d or h). Shift-Tab unmarks it.

  d        Prune the marked generation(s) -- ONLY works on generations
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
           stray build results, and anything freed up by a prior 'd'.
           Never touches the system profile or the boot menu config.

  ?        Toggle this help.

  q / Esc  Quit the tool entirely (as does Ctrl-C, any time). 'q' at a
           prompt or confirmation instead cancels just that one action
           and returns you here.

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
    echo "equivalent. 'd'/'h'/'g' all work normally here." >&2
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
  # 1) boot orphans (delegated entirely to limine-boot-rescue's own Phase 1
  #    report/apply, same as running it by hand with no --evict);
  # 2) plain Nix GC for anything left over from nix-shell/nix develop
  #    sessions or stray build results, which never touches a generation
  #    or the boot menu config at all -- just dead store paths.
  echo
  echo "== Boot orphans (files referenced by nothing on the boot menu) =="
  if [[ -x "$RESCUE_SCRIPT" ]]; then
    "$RESCUE_SCRIPT" "${RESCUE_ARGS[@]}" || true
  else
    echo "  (limine-boot-rescue.sh not found alongside this script -- skipping)" >&2
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
    echo "Deleting boot orphans (limine-boot-rescue --apply -- its own confirmation follows)..."
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

  if [[ -n "$CURRENT_GEN" && "$GEN" == "$CURRENT_GEN" ]]; then
    echo
    echo "Generation $GEN is the currently-booted generation and can't be" >&2
    echo "pruned." >&2
    return 1
  fi

  echo
  echo "Pruning generation $GEN: deleting it from the NixOS system profile."
  echo "(This does not touch /boot -- it just makes the"
  echo "generation eligible for garbage collection. Run 'g' afterward to"
  echo "actually reclaim the space.)"
  echo

  read -rp "Delete generation $GEN from the system profile? [yes/N]: " CONFIRM
  if [[ "$CONFIRM" != "yes" ]]; then
    echo "Skipped. Generation $GEN was not deleted."
    return 1
  fi

  require sudo
  sudo nix-env -p /nix/var/nix/profiles/system --delete-generations "$GEN"
  echo
  echo "Generation $GEN removed from the system profile."
}

harvest_generation() {
  local GEN="$1"

  echo
  echo "Harvesting generation $GEN: evicting it from the boot menu and"
  echo "reclaiming the /boot space it alone was using."
  echo "(This runs 'limine-boot-rescue --evict $GEN --apply' -- see its own"
  echo "confirmation prompts below for exactly what that does. 'q' there just"
  echo "skips this generation and returns you to the picker.)"
  echo

  if [[ ! -x "$RESCUE_SCRIPT" ]]; then
    echo "Error: expected limine-boot-rescue.sh alongside this script at:" >&2
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

require fzf

# Main loop: redisplay the generation picker after every completed or
# cancelled action, so only 'q'/Esc *at the list itself* (or Ctrl-C, any
# time) actually exits the tool.
while true; do
  CURRENT_SYSTEM=""
  [[ -e /run/current-system ]] && CURRENT_SYSTEM="$(readlink -f /run/current-system)"
  CURRENT_GEN=""

  declare -A IN_BOOTLOADER=()
  BOOT_COUNT=0

  while read -r bgen; do
    if [[ -n "$bgen" ]]; then
      IN_BOOTLOADER["$bgen"]=1
      BOOT_COUNT=$((BOOT_COUNT + 1))
    fi
  done < <(backend_kept_generations_lenient)

  shopt -s nullglob
  LINKS=(/nix/var/nix/profiles/system-*-link)
  shopt -u nullglob

  if [[ ${#LINKS[@]} -eq 0 ]]; then
    echo "No generations found under /nix/var/nix/profiles/. Are you on NixOS?" >&2
    exit 1
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
    [[ -n "$CURRENT_SYSTEM" && "$target" == "$CURRENT_SYSTEM" ]] && { marker=" (current)"; CURRENT_GEN="$gen"; }

    boot_marker="-"
    [[ -n "${IN_BOOTLOADER[$gen]:-}" ]] && boot_marker="✓"

    ROWS+=("${gen}"$'\t'"${boot_marker}"$'\t'"${gen_date}"$'\t'"${nixos_ver}"$'\t'"${kernel_ver}${marker}")
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
      PIN_ROWS+=("pin:${pname}"$'\t''📌'$'\t'"${pdate}"$'\t''-'$'\t'"pinned: ${pname}")
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

  HEADER_TEXT="NixOS Generations (${#ROWS[@]} total, ${BOOT_COUNT} in bootloader, ${#PIN_ROWS[@]} pinned -- $BOOTLOADER)"
  ENTER_LABEL="Enter:pin/unpin"
  backend_supports_pin || ENTER_LABEL="Enter:pin(Limine only)"
  FOOTER_TEXT="  q/Esc:quit   ${ENTER_LABEL}   Tab:multi-select   d:prune   h:harvest   g:gc   ?:help   ↑↓:move   Type to filter  "

  RAW=$(
    {
      printf 'GEN\tBOOT\tDATE\tNIXOS\tKERNEL\n'
      printf '%s\n' "$BODY"
    } | column -t -s $'\t' |
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
        --expect=d,g,h
  ) || true

  KEY=$(head -n1 <<<"$RAW")
  SELECTED=$(tail -n +2 <<<"$RAW")

  if [[ "$KEY" == "g" ]]; then
    # Global action -- deliberately doesn't require (or care about) a
    # selection, since it isn't tied to any one generation.
    gc_orphans_and_leftovers || true
    continue
  fi

  [[ -n "$SELECTED" ]] || {
    echo "No generation selected."
    exit 0
  }

  mapfile -t SELECTED_GENS < <(awk '{print $1}' <<<"$SELECTED")

  if [[ "$KEY" == "d" ]]; then
    for GEN in "${SELECTED_GENS[@]}"; do
      if [[ "$GEN" == pin:* ]]; then
        echo
        echo "'${GEN#pin:}' is a pin, not a generation -- pins aren't pruned." >&2
        echo "Select it alone and press Enter to unpin it instead." >&2
        continue
      fi
      # '|| true': prune_generation returns 1 whenever it refuses (in the
      # boot menu, is the currently-booted generation) or is cancelled at
      # its own confirmation. That's meant to skip just this generation and
      # return to the picker, but a bare non-zero return here would trip
      # `set -e` and kill the whole tool instead.
      prune_generation "$GEN" || true
    done
    continue
  fi

  if [[ "$KEY" == "h" ]]; then
    for GEN in "${SELECTED_GENS[@]}"; do
      if [[ "$GEN" == pin:* ]]; then
        echo
        echo "'${GEN#pin:}' is a pin, not a generation -- pins aren't harvested." >&2
        echo "Select it alone and press Enter to unpin it instead." >&2
        continue
      fi
      if [[ -z "${IN_BOOTLOADER[$GEN]:-}" ]]; then
        echo
        echo "Generation $GEN is not on the bootloader, so there's nothing to" >&2
        echo "harvest. If you want to remove it, prune it instead ('d')." >&2
        continue
      fi
      # '|| true': harvest_generation returns 1 whenever the rescue script
      # it shells out to exits non-zero -- 'q' at any of rescue's own
      # confirmations, or one of rescue's own guardrail refusals. That's
      # meant to abort just this harvest and return to the picker, but a
      # bare non-zero return here would trip `set -e` and kill the whole
      # tool instead.
      harvest_generation "$GEN" || true
    done
    continue
  fi

  # Enter -> pin (a generation row) or unpin (a pin row). Either way it
  # only makes sense one at a time -- multi-select is for 'd'/'h'.
  if [[ ${#SELECTED_GENS[@]} -gt 1 ]]; then
    echo
    echo "Pin/unpin only supports one row at a time -- you selected ${#SELECTED_GENS[@]}." >&2
    echo "Tab-select multiple generations for prune ('d') or harvest ('h') instead." >&2
    echo
    continue
  fi
  GEN="${SELECTED_GENS[0]}"

  if [[ "$GEN" == pin:* ]]; then
    unpin_generation "${GEN#pin:}" || true
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
done
