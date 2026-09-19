#!/usr/bin/env bash
# limine-pin-picker — browse NixOS generations and pin one to the Limine
# bootloader via a small generated JSON file, consumed by
# limine-manual-pins.nix (custom.limineManualPins = builtins.fromJSON
# (builtins.readFile ./limine-pins.json);).
#
# This script ONLY ever reads/rewrites its own pins JSON file in full.
# It never touches any other file in your config, never runs git, and
# never triggers a rebuild — review the diff and rebuild the same way
# you always do.
#
# The one exception is 'h' (harvest) at the generation list, which shells
# out to the sibling limine-boot-rescue.sh --evict GEN --apply -- that
# script owns all the real work (and all the guardrails/confirmation) for
# actually evicting a generation from the boot menu and reclaiming /boot
# space. Nothing here duplicates that logic.
set -euo pipefail

OUTPUT="limine-pins.json"
ACTION="add"
REMOVE_NAME=""

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
RESCUE_SCRIPT="$(dirname "$SELF")/limine-boot-rescue.sh"

usage() {
  cat <<'EOF'
limine-pin-picker — browse NixOS generations and pin one to Limine

Usage:
  limine-pin-picker                 Interactively pick generation(s) --
                                     Enter to pin one, 'd' to prune, 'h' to
                                     harvest (Tab to select several first)
  limine-pin-picker --list          List currently pinned entries
  limine-pin-picker --remove NAME   Remove a pinned entry by name
  limine-pin-picker --output FILE   Use a different pins file (default: ./limine-pins.json)
  limine-pin-picker --help          Show this help

The pins file is always fully rewritten (never patched in place) and kept
sorted by name, so it stays clean and diffable in git.

Tab-select multiple generations before pressing 'd' or 'h' to prune or
harvest all of them in one go, each with its own confirmation. Pinning
('Enter') always applies to exactly one generation at a time, since each
pin needs its own name/title/comment.

Pruning only removes the generation from the system profile
(nix-env --delete-generations) -- it does NOT touch /boot or run garbage
collection. Run your usual GC + rebuild afterward to actually reclaim space.
The currently-booted generation can never be pruned this way.

Harvesting a generation runs 'limine-boot-rescue --evict GEN --apply' on it
directly -- it removes the generation's menu entry from limine.conf *and*
deletes the /boot files that entry orphans, immediately reclaiming that
space (rather than waiting on a GC + rebuild). Same guardrails as running
rescue by hand: refuses the currently-booted generation, refuses to drop
below 2 kept generations, backs up limine.conf first, and requires typed
confirmation.

'q' or Esc at the generation list quits the tool entirely, as does Ctrl-C
at any point. 'q' at a follow-up prompt or confirmation (pin, prune,
harvest) only cancels that one generation and returns you to the list --
nothing is written or pruned for it, but the tool keeps running so you can
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
LIMINE_CONF="/boot/limine/limine.conf"

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
}

prune_generation() {
  local GEN="$1"
  local LINK="/nix/var/nix/profiles/system-${GEN}-link"
  local TARGET CONFIRM
  TARGET=$(readlink -f "$LINK")

  if [[ -n "$CURRENT_SYSTEM" && "$TARGET" == "$CURRENT_SYSTEM" ]]; then
    echo "Refusing to prune the currently booted generation ($GEN)." >&2
    return 1
  fi

  echo
  echo "This prunes generation $GEN from the system profile only"
  echo "(nix-env --delete-generations). It does NOT touch /boot directly --"
  echo "the space is only reclaimed after you run garbage collection and"
  echo "rebuild (e.g. nix-collect-garbage && nh os switch)."
  echo

  read -rp "Type the generation number (${GEN}) to confirm, or 'q' to skip this one: " CONFIRM
  if [[ "$CONFIRM" == "q" || "$CONFIRM" == "Q" ]]; then
    echo "Skipped pruning generation $GEN. Back to the picker."
    return 0
  fi
  if [[ "$CONFIRM" != "$GEN" ]]; then
    echo "Confirmation did not match ('$CONFIRM' != '$GEN'). Skipped pruning generation $GEN." >&2
    return 1
  fi

  echo "Pruning generation $GEN from the system profile..."
  sudo nix-env --delete-generations "$GEN" --profile /nix/var/nix/profiles/system

  echo
  echo "Generation $GEN removed from the system profile."
  echo "Run garbage collection and rebuild to actually reclaim the space in /boot."
}

harvest_generation() {
  local GEN="$1"

  echo
  echo "Harvesting generation $GEN: evicting it from the Limine boot menu and"
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
  if "$RESCUE_SCRIPT" --evict "$GEN" --apply; then
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

  declare -A IN_BOOTLOADER=()
  BOOT_COUNT=0

  LIMINE_CONF_CONTENT=""
  if [[ -r "$LIMINE_CONF" ]]; then
    LIMINE_CONF_CONTENT=$(cat "$LIMINE_CONF")
  elif command -v sudo >/dev/null 2>&1; then
    # -r (and -e) can silently report "false" here even when the file exists,
    # if a parent directory (e.g. /boot or /boot/limine) isn't traversable by
    # a non-root user -- so we always attempt sudo rather than gating on -e.
    # Capture stderr too so a failed/expired sudo prompt is visible instead of
    # silently looking like "0 generations in bootloader".
    if ! LIMINE_CONF_CONTENT=$(sudo cat "$LIMINE_CONF" 2>&1); then
      echo "Note: couldn't read $LIMINE_CONF as root:" >&2
      echo "  $LIMINE_CONF_CONTENT" >&2
      echo "  Bootloader-in-use markers will be unavailable this run." >&2
      LIMINE_CONF_CONTENT=""
    fi
  else
    echo "Note: $LIMINE_CONF isn't readable and 'sudo' isn't available -- bootloader-in-use markers will be unavailable this run." >&2
  fi

  if [[ -n "$LIMINE_CONF_CONTENT" ]]; then
    while read -r bgen; do
      if [[ -n "$bgen" ]]; then
        IN_BOOTLOADER["$bgen"]=1
        BOOT_COUNT=$((BOOT_COUNT + 1))
      fi
    done < <(grep -oE '^//\+?Generation [0-9]+' <<<"$LIMINE_CONF_CONTENT" | grep -oE '[0-9]+' || true)
  fi

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
    [[ -n "$CURRENT_SYSTEM" && "$target" == "$CURRENT_SYSTEM" ]] && marker=" (current)"

    boot_marker="-"
    [[ -n "${IN_BOOTLOADER[$gen]:-}" ]] && boot_marker="✓"

    ROWS+=("${gen}"$'\t'"${boot_marker}"$'\t'"${gen_date}"$'\t'"${nixos_ver}"$'\t'"${kernel_ver}${marker}")
  done

  BODY=$(printf '%s\n' "${ROWS[@]}" | sort -t $'\t' -k1,1nr)

  HEADER_TEXT="NixOS Generations (${#ROWS[@]} total, ${BOOT_COUNT} in bootloader)"
  FOOTER_TEXT="  q/Esc:quit   Enter:pin   Tab:multi-select   d:prune   h:harvest   ↑↓:move   Type to filter  "

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
        --border-label ' limine-pin-picker ' \
        --footer "$FOOTER_TEXT" \
        --multi \
        --bind 'q:abort' \
        --expect=d,h
  ) || true

  KEY=$(head -n1 <<<"$RAW")
  SELECTED=$(tail -n +2 <<<"$RAW")

  [[ -n "$SELECTED" ]] || {
    echo "No generation selected."
    exit 0
  }

  mapfile -t SELECTED_GENS < <(awk '{print $1}' <<<"$SELECTED")

  if [[ "$KEY" != "d" && "$KEY" != "h" ]]; then
    # Enter -> pin. Pinning asks for a name/title/comment per generation, so
    # it only makes sense one at a time -- multi-select is for 'd'/'h'.
    if [[ ${#SELECTED_GENS[@]} -gt 1 ]]; then
      echo
      echo "Pinning only supports one generation at a time -- you selected ${#SELECTED_GENS[@]}." >&2
      echo "Tab-select multiple generations for prune ('d') or harvest ('h') instead." >&2
      echo
      continue
    fi
    GEN="${SELECTED_GENS[0]}"
    LINK="/nix/var/nix/profiles/system-${GEN}-link"
    TARGET=$(readlink -f "$LINK")
    echo "Selected generation $GEN -> $TARGET"
    # '|| true': pin_generation returns 1 on 'q' at any prompt (cancel, back
    # to the picker). Called bare like this under `set -e`, a non-zero
    # return would otherwise kill the whole script instead of just this
    # attempt -- see the same note above harvest_generation's call below.
    pin_generation "$GEN" "$LINK" "$TARGET" || true
    continue
  fi

  if [[ "$KEY" == "d" ]]; then
    for GEN in "${SELECTED_GENS[@]}"; do
      # '|| true': prune_generation returns 1 on 'q', a mismatched typed
      # confirmation, or refusing the current generation -- all meant as
      # "skip this one, keep going," not "quit." Called bare under
      # `set -e`, a non-zero return here would otherwise exit the whole
      # script on the spot, before the loop (or the outer picker) ever
      # gets a chance to continue.
      prune_generation "$GEN" || true
    done
    continue
  fi

  if [[ "$KEY" == "h" ]]; then
    for GEN in "${SELECTED_GENS[@]}"; do
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
done
