#!/usr/bin/env bash
# limine-boot-rescue — diagnostic + rescue tool for a 100%-full /boot on a
# Limine + NixOS system.
#
# nix-env --delete-generations alone can't free /boot space: the actual
# kernel/initrd files under /boot/limine/kernels/ and the menu entries in
# /boot/limine/limine.conf are only rewritten by a *successful*
# nixos-rebuild switch -- which is exactly what's failing when /boot is
# full. This script does manually what a successful rebuild's cleanup step
# would have done, to free enough space for a real rebuild to succeed again.
#
# DEFAULT MODE (no --apply) NEVER WRITES OR DELETES ANYTHING -- report only.
# --apply is required to actually change anything, and even then requires
# typed confirmation before touching disk.
set -euo pipefail

LIMINE_CONF="/boot/limine/limine.conf"
KERNELS_DIR="/boot/limine/kernels"
MIN_KEPT=2 # never go below this many kept generations (current included)

EVICT_GEN=""
APPLY=0

usage() {
  cat <<'EOF'
limine-boot-rescue — diagnostic + rescue tool for a full /boot partition

Usage:
  limine-boot-rescue                Report orphaned files in /boot/limine/kernels/
                                     (referenced by nothing in limine.conf)
  limine-boot-rescue --evict N      Also preview evicting generation N's menu
                                     entry from limine.conf, and what additional
                                     files that would orphan
  limine-boot-rescue --apply        Actually delete Phase 1 orphaned files
                                     (requires typed confirmation)
  limine-boot-rescue --evict N --apply
                                     Actually evict generation N from
                                     limine.conf and delete its now-orphaned
                                     files (requires typed confirmation)
  limine-boot-rescue --help         Show this help

Without --apply, this is diagnostic only -- it never deletes files or edits
limine.conf. --apply always backs up limine.conf first (timestamped, next
to the original), validates the edit before writing it, and never touches
the currently-booted generation or drops the boot menu below 2 kept
generations, no matter what.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --evict)
      EVICT_GEN="${2:-}"
      shift 2
      ;;
    --apply)
      APPLY=1
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

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Error: '$1' is required but not found in PATH." >&2
    exit 1
  }
}

read_root_file() {
  local path="$1"
  if [[ -r "$path" ]]; then
    cat "$path"
  elif command -v sudo >/dev/null 2>&1; then
    # Parent directories here (e.g. /boot, /boot/limine) are often not
    # traversable by a non-root user, so -r/-e on the file itself can't be
    # trusted -- just attempt sudo directly rather than gating on a test.
    sudo cat "$path"
  else
    echo "Error: cannot read '$path' (not readable, and no sudo available)." >&2
    exit 1
  fi
}

list_root_dir() {
  local path="$1"
  if [[ -r "$path" ]]; then
    find "$path" -maxdepth 1 -type f -printf '%f\t%s\n'
  elif command -v sudo >/dev/null 2>&1; then
    sudo find "$path" -maxdepth 1 -type f -printf '%f\t%s\n'
  else
    echo "Error: cannot list '$path' (not readable, and no sudo available)." >&2
    exit 1
  fi
}

CONF_CONTENT="$(read_root_file "$LIMINE_CONF")"

echo "== /boot space =="
df -h /boot 2>/dev/null || true
echo

# ---------------------------------------------------------------------------
# Referenced-file set: every filename any kernel_path/module_path line in
# limine.conf currently points to, regardless of what generation it's under.
# The "#<hash>" suffix Limine appends is a content-verification hash, not
# part of the on-disk filename, so it's stripped.
# ---------------------------------------------------------------------------
referenced_files() {
  grep -oE '/limine/kernels/[^#[:space:]]+' <<<"$1" | sed 's#^/limine/kernels/##' | sort -u
}

REFERENCED="$(referenced_files "$CONF_CONTENT")"

echo "== Phase 1: orphaned files in $KERNELS_DIR (referenced by nothing) =="
DISK_FILES="$(list_root_dir "$KERNELS_DIR")"

TOTAL_ORPHAN_BYTES=0
ORPHAN_COUNT=0
while IFS=$'\t' read -r fname fsize; do
  [[ -n "$fname" ]] || continue
  if ! grep -qxF "$fname" <<<"$REFERENCED"; then
    printf '  %-70s %10d bytes\n' "$fname" "$fsize"
    TOTAL_ORPHAN_BYTES=$((TOTAL_ORPHAN_BYTES + fsize))
    ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
  fi
done <<<"$DISK_FILES"

abort() {
  echo
  echo "Aborted. No changes made." >&2
  exit 1
}

# Prompts the user to type back an exact expected string. 'q' aborts.
confirm_exact() {
  local prompt="$1" expected="$2" input
  read -rp "$prompt" input
  if [[ "$input" == "q" || "$input" == "Q" ]]; then
    abort
  fi
  if [[ "$input" != "$expected" ]]; then
    echo "Confirmation did not match ('$input' != '$expected')." >&2
    abort
  fi
}

delete_files() {
  # $1: newline-separated list of filenames under $KERNELS_DIR to delete
  local list="$1" fname
  while IFS= read -r fname; do
    [[ -n "$fname" ]] || continue
    if [[ -w "$KERNELS_DIR" ]]; then
      rm -f -- "$KERNELS_DIR/$fname"
    else
      sudo rm -f -- "$KERNELS_DIR/$fname"
    fi
    echo "  deleted: $fname"
  done <<<"$list"
}

if [[ "$ORPHAN_COUNT" -eq 0 ]]; then
  echo "  (none found -- everything on disk is currently referenced)"
else
  echo
  echo "  $ORPHAN_COUNT orphaned file(s), $((TOTAL_ORPHAN_BYTES / 1024 / 1024)) MiB reclaimable with zero risk to the boot menu."
fi
echo

if [[ -z "$EVICT_GEN" ]]; then
  if [[ "$APPLY" -eq 0 ]]; then
    echo "(Pass --evict N to also preview evicting a specific kept generation's menu entry.)"
    exit 0
  fi
  # --apply with no --evict: Phase 1 only. No limine.conf edit at all, so
  # this is the lowest-risk apply path -- one typed confirmation.
  if [[ "$ORPHAN_COUNT" -eq 0 ]]; then
    echo "Nothing to apply -- no orphaned files found."
    exit 0
  fi
  echo "APPLY MODE: this will permanently delete the $ORPHAN_COUNT orphaned file(s) listed above"
  echo "($((TOTAL_ORPHAN_BYTES / 1024 / 1024)) MiB). limine.conf is not touched by this."
  confirm_exact "Type 'yes' to proceed, or 'q' to cancel: " "yes"
  echo
  echo "Deleting orphaned files..."
  ORPHAN_LIST=""
  while IFS=$'\t' read -r fname fsize; do
    [[ -n "$fname" ]] || continue
    grep -qxF "$fname" <<<"$REFERENCED" || ORPHAN_LIST+="$fname"$'\n'
  done <<<"$DISK_FILES"
  delete_files "$ORPHAN_LIST"
  echo
  echo "Done. Re-run without --apply to confirm /boot space and remaining files."
  exit 0
fi

# ---------------------------------------------------------------------------
# Phase 2 preview: show the //Generation N block that would be cut, without
# touching the file, and recompute orphans as if it were gone.
# ---------------------------------------------------------------------------
echo "== Phase 2 preview: evicting generation $EVICT_GEN from the boot menu =="

if [[ ! -L /run/current-system ]]; then
  echo "Error: /run/current-system does not exist or is not a symlink." >&2
  echo "This doesn't look like a normal NixOS boot environment." >&2
  echo "Refusing to preview any eviction -- can't guarantee the current generation would be protected." >&2
  exit 1
fi
CURRENT_SYSTEM="$(readlink -f /run/current-system)"

shopt -s nullglob
PROFILE_LINKS=(/nix/var/nix/profiles/system-*-link)
shopt -u nullglob

if [[ ${#PROFILE_LINKS[@]} -eq 0 ]]; then
  echo "Error: no /nix/var/nix/profiles/system-*-link entries exist at all." >&2
  echo "Refusing to preview any eviction -- there's nothing to prune yet." >&2
  exit 1
fi

CURRENT_GEN=""
for link in "${PROFILE_LINKS[@]}"; do
  if [[ "$(readlink -f "$link")" == "$CURRENT_SYSTEM" ]]; then
    CURRENT_GEN=$(basename "$link" | sed -E 's/system-([0-9]+)-link/\1/')
    break
  fi
done

if [[ -z "$CURRENT_GEN" ]]; then
  # A booted system with no matching profile link almost always means it was
  # activated with `nixos-rebuild test` / `switch-to-configuration test`,
  # which deliberately skips creating a profile generation (and skips the
  # boot menu) -- so there's genuinely no generation number to protect.
  echo "Error: could not determine the currently-booted generation number." >&2
  echo "/run/current-system -> $CURRENT_SYSTEM" >&2
  echo "...but no /nix/var/nix/profiles/system-*-link points at that same store path." >&2
  echo >&2
  echo "This usually means the running system was activated with 'nixos-rebuild test'" >&2
  echo "(or 'switch-to-configuration test'), which skips creating a profile generation" >&2
  echo "and skips updating the boot menu -- so there's genuinely nothing to protect it." >&2
  echo >&2
  echo "Fix: run 'nixos-rebuild switch' (or 'nh os switch') to register the current" >&2
  echo "system as a real generation, then re-run limine-boot-rescue." >&2
  echo >&2
  echo "Refusing to preview any eviction -- can't guarantee the current generation" >&2
  echo "would be protected." >&2
  exit 1
fi

if [[ "$EVICT_GEN" == "$CURRENT_GEN" ]]; then
  echo "Refusing to preview evicting generation $EVICT_GEN -- it is the currently booted generation." >&2
  exit 1
fi

KEPT_GENS=$(grep -oE '^//\+?Generation [0-9]+' <<<"$CONF_CONTENT" | grep -oE '[0-9]+' || true)
KEPT_COUNT=$(wc -l <<<"$KEPT_GENS")
if ! grep -qxF "$EVICT_GEN" <<<"$KEPT_GENS"; then
  echo "Generation $EVICT_GEN is not currently in the boot menu -- nothing to evict." >&2
  exit 1
fi
if [[ "$KEPT_COUNT" -le "$MIN_KEPT" ]]; then
  echo "Refusing to preview: only $KEPT_COUNT generation(s) currently kept in the boot menu." >&2
  echo "Evicting one would drop below the minimum of $MIN_KEPT kept generations." >&2
  exit 1
fi

# Extract the block: from "//[+]Generation N" up to (not including) the next
# "//<something>" line at the same nesting level, or the end-of-block marker.
BLOCK=$(awk -v gen="$EVICT_GEN" '
  BEGIN { printing = 0 }
  /^\/\/\+?Generation [0-9]+/ {
    match($0, /[0-9]+/)
    thisgen = substr($0, RSTART, RLENGTH)
    if (thisgen == gen) { printing = 1; print; next }
    else if (printing) { printing = 0 }
  }
  /^# NixOS boot entries end here/ { printing = 0 }
  printing { print }
' <<<"$CONF_CONTENT")

if [[ -z "$BLOCK" ]]; then
  echo "Could not locate a //Generation $EVICT_GEN block in $LIMINE_CONF -- refusing to guess further." >&2
  exit 1
fi

echo "This block would be removed from $LIMINE_CONF:"
echo "----------------------------------------------------------------------"
echo "$BLOCK"
echo "----------------------------------------------------------------------"
echo

NEW_CONF_CONTENT=$(awk -v gen="$EVICT_GEN" '
  BEGIN { skip = 0 }
  /^\/\/\+?Generation [0-9]+/ {
    match($0, /[0-9]+/)
    thisgen = substr($0, RSTART, RLENGTH)
    if (thisgen == gen) { skip = 1; next }
    else if (skip) { skip = 0 }
  }
  /^# NixOS boot entries end here/ { skip = 0 }
  !skip { print }
' <<<"$CONF_CONTENT")

NEW_REFERENCED="$(referenced_files "$NEW_CONF_CONTENT")"

echo "Additional files that would become orphaned once generation $EVICT_GEN is evicted:"
NEWLY_ORPHANED_BYTES=0
NEWLY_ORPHANED_COUNT=0
while IFS=$'\t' read -r fname fsize; do
  [[ -n "$fname" ]] || continue
  # Only interesting if it's currently referenced (i.e. NOT already an
  # orphan from Phase 1) but becomes unreferenced after this eviction.
  if grep -qxF "$fname" <<<"$REFERENCED" && ! grep -qxF "$fname" <<<"$NEW_REFERENCED"; then
    printf '  %-70s %10d bytes\n' "$fname" "$fsize"
    NEWLY_ORPHANED_BYTES=$((NEWLY_ORPHANED_BYTES + fsize))
    NEWLY_ORPHANED_COUNT=$((NEWLY_ORPHANED_COUNT + 1))
  fi
done <<<"$DISK_FILES"

if [[ "$NEWLY_ORPHANED_COUNT" -eq 0 ]]; then
  echo "  (none -- every file this generation used is still shared by another kept generation)"
else
  echo
  echo "  $NEWLY_ORPHANED_COUNT file(s), $((NEWLY_ORPHANED_BYTES / 1024 / 1024)) MiB additional -- would require the limine.conf edit above plus deleting these."
fi
echo

if [[ "$APPLY" -eq 0 ]]; then
  echo "This was a preview only. Nothing on disk or in $LIMINE_CONF has been changed."
  exit 0
fi

# ---------------------------------------------------------------------------
# Phase 2 apply: edit limine.conf for real, with a backup and validation
# gate before the write, then delete the files that edit orphans.
# ---------------------------------------------------------------------------
echo "APPLY MODE: this will:"
echo "  1. Back up $LIMINE_CONF"
echo "  2. Remove the //Generation $EVICT_GEN block shown above from $LIMINE_CONF"
echo "  3. Delete the $NEWLY_ORPHANED_COUNT newly-orphaned file(s) above ($((NEWLY_ORPHANED_BYTES / 1024 / 1024)) MiB)"
echo "  4. Run: nix-env --delete-generations $EVICT_GEN --profile /nix/var/nix/profiles/system"
echo
echo "Generation $EVICT_GEN's boot menu entry cannot be recovered after this except from the backup."
confirm_exact "Type the generation number ($EVICT_GEN) to confirm, or 'q' to cancel: " "$EVICT_GEN"
confirm_exact "Type 'yes' to proceed, or 'q' to cancel: " "yes"
echo

# --- Validate the new content before writing anything -----------------
NEW_KEPT_GENS=$(grep -oE '^//\+?Generation [0-9]+' <<<"$NEW_CONF_CONTENT" | grep -oE '[0-9]+' || true)
NEW_KEPT_COUNT=$(wc -l <<<"$NEW_KEPT_GENS")
START_MARKERS=$(grep -c '^# NixOS boot entries start here' <<<"$NEW_CONF_CONTENT" || true)
END_MARKERS=$(grep -c '^# NixOS boot entries end here' <<<"$NEW_CONF_CONTENT" || true)

VALIDATION_FAILED=0
[[ "$START_MARKERS" -eq 1 ]] || { echo "Validation failed: expected exactly 1 start marker, found $START_MARKERS." >&2; VALIDATION_FAILED=1; }
[[ "$END_MARKERS" -eq 1 ]] || { echo "Validation failed: expected exactly 1 end marker, found $END_MARKERS." >&2; VALIDATION_FAILED=1; }
[[ "$NEW_KEPT_COUNT" -eq $((KEPT_COUNT - 1)) ]] || { echo "Validation failed: expected $((KEPT_COUNT - 1)) kept generations after edit, found $NEW_KEPT_COUNT." >&2; VALIDATION_FAILED=1; }
grep -qxF "$CURRENT_GEN" <<<"$NEW_KEPT_GENS" || { echo "Validation failed: current generation $CURRENT_GEN missing from the edited file." >&2; VALIDATION_FAILED=1; }
grep -qxF "$EVICT_GEN" <<<"$NEW_KEPT_GENS" && { echo "Validation failed: generation $EVICT_GEN still present after removal." >&2; VALIDATION_FAILED=1; }
[[ -n "$NEW_CONF_CONTENT" ]] || { echo "Validation failed: new content is empty." >&2; VALIDATION_FAILED=1; }

if [[ "$VALIDATION_FAILED" -eq 1 ]]; then
  echo "Refusing to write $LIMINE_CONF -- validation failed. Nothing was changed." >&2
  exit 1
fi
echo "Validation passed ($NEW_KEPT_COUNT kept generations remain, current generation $CURRENT_GEN intact)."
echo

BACKUP="${LIMINE_CONF}.bak-$(date +%Y%m%d%H%M%S)"
TMPFILE=$(mktemp)
printf '%s\n' "$NEW_CONF_CONTENT" >"$TMPFILE"

echo "Backing up to $BACKUP..."
sudo cp -p "$LIMINE_CONF" "$BACKUP"

echo "Writing new $LIMINE_CONF..."
sudo cp "$TMPFILE" "${LIMINE_CONF}.new"
sudo mv "${LIMINE_CONF}.new" "$LIMINE_CONF"
rm -f "$TMPFILE"

echo "Deleting newly-orphaned files..."
NEWLY_ORPHANED_LIST=""
while IFS=$'\t' read -r fname fsize; do
  [[ -n "$fname" ]] || continue
  if grep -qxF "$fname" <<<"$REFERENCED" && ! grep -qxF "$fname" <<<"$NEW_REFERENCED"; then
    NEWLY_ORPHANED_LIST+="$fname"$'\n'
  fi
done <<<"$DISK_FILES"
delete_files "$NEWLY_ORPHANED_LIST"

echo
echo "Syncing the Nix profile (nix-env --delete-generations $EVICT_GEN)..."
if sudo nix-env --delete-generations "$EVICT_GEN" --profile /nix/var/nix/profiles/system; then
  echo "Profile updated."
else
  echo "Warning: nix-env --delete-generations failed, but the boot menu edit and file" >&2
  echo "deletion above already succeeded. The profile is now out of sync with the boot" >&2
  echo "menu (generation $EVICT_GEN still exists in the profile but not in limine.conf)" >&2
  echo "-- safe to leave as-is, or retry: sudo nix-env --delete-generations $EVICT_GEN --profile /nix/var/nix/profiles/system" >&2
fi

echo
echo "Done. Backup saved at $BACKUP if you need to restore it."
echo "Try your rebuild now (e.g. nh os switch)."
