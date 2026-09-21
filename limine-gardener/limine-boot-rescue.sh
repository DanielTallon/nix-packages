#!/usr/bin/env bash
# limine-boot-rescue — diagnostic + rescue tool for a 100%-full /boot on a
# Limine, systemd-boot, or GRUB + NixOS system.
#
# nix-env --delete-generations alone can't free /boot space: the actual
# kernel/initrd/EFI files and the bootloader's own menu entries are only
# rewritten by a *successful* nixos-rebuild switch -- which is exactly
# what's failing when /boot is full. This script does manually what a
# successful rebuild's cleanup step would have done, to free enough space
# for a real rebuild to succeed again.
#
# DEFAULT MODE (no --apply) NEVER WRITES OR DELETES ANYTHING -- report only.
# --apply is required to actually change anything, and even then requires
# typed confirmation before touching disk.
#
# Bootloader (Limine, systemd-boot, or GRUB) is auto-detected from what's
# on /boot; pass --bootloader to override. See boot-backend.sh (sourced
# below, alongside this script) for exactly what differs between them.
set -euo pipefail

MIN_KEPT=2 # never go below this many kept generations (current included)

EVICT_GEN=""
APPLY=0
BOOTLOADER_OVERRIDE=""

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
# shellcheck source=./boot-backend.sh
source "$(dirname "$SELF")/boot-backend.sh"

usage() {
  cat <<'EOF'
limine-boot-rescue — diagnostic + rescue tool for a full /boot partition

Usage:
  limine-boot-rescue                Report orphaned files (referenced by no
                                     current boot-menu entry)
  limine-boot-rescue --evict N      Also preview evicting generation N's
                                     boot-menu entry, and what additional
                                     files that would orphan
  limine-boot-rescue --apply        Actually delete Phase 1 orphaned files
                                     (requires typed confirmation)
  limine-boot-rescue --evict N --apply
                                     Actually evict generation N's boot-menu
                                     entry and delete its now-orphaned files
                                     (requires typed confirmation)
  limine-boot-rescue --bootloader limine|systemd-boot|grub
                                     Skip auto-detection and use this backend
  limine-boot-rescue --help         Show this help

Without --apply, this is diagnostic only -- it never deletes files or edits
the boot menu. --apply always backs up the affected boot-menu config first
(timestamped, next to the original), validates the edit before writing it,
and never touches the currently-booted generation or drops the boot menu
below 2 kept generations, no matter what.

Supports Limine, systemd-boot, and GRUB; the bootloader is auto-detected
from what exists under /boot unless --bootloader is given explicitly.
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

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Error: '$1' is required but not found in PATH." >&2
    exit 1
  }
}

backend_init "$BOOTLOADER_OVERRIDE"
echo "Bootloader: $BOOTLOADER"

echo "== /boot space =="
df -h /boot 2>/dev/null || true
echo

REFERENCED="$(backend_referenced_files)"

echo "== Phase 1: orphaned files in $BOOT_KERNELS_DIR (referenced by nothing) =="

# GRUB with boot.loader.grub.copyKernels = false (the default when /boot
# and /nix/store share a filesystem) never copies anything into
# $GRUB_KERNELS_DIR -- it may not exist at all, and that's a normal state,
# not a broken install, so skip list_root_dir's usual "must exist" check
# rather than have it error. limine/systemd-boot don't get this
# treatment: for them a missing kernels dir really would mean something's
# broken, and should still fail loud.
if [[ "$BOOTLOADER" == "grub" ]] && ! path_exists_root "$GRUB_KERNELS_DIR"; then
  echo "  (doesn't exist -- this system has boot.loader.grub.copyKernels ="
  echo "  false, so GRUB references /nix/store directly instead of"
  echo "  copying kernels into /boot. Nothing is ever orphaned there, and"
  echo "  harvesting a generation only removes its grub.cfg entry -- no"
  echo "  /boot space is reclaimed.)"
  DISK_FILES=""
else
  DISK_FILES="$(list_root_dir "$BOOT_KERNELS_DIR")"
fi

TOTAL_ORPHAN_BYTES=0
ORPHAN_COUNT=0
ORPHAN_LIST=""
while IFS=$'\t' read -r fname fsize; do
  [[ -n "$fname" ]] || continue
  if ! grep -qxF "$fname" <<<"$REFERENCED"; then
    printf '  %-70s %10d bytes\n' "$fname" "$fsize"
    TOTAL_ORPHAN_BYTES=$((TOTAL_ORPHAN_BYTES + fsize))
    ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
    ORPHAN_LIST+="$fname"$'\n'
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
  # $1: newline-separated list of filenames under $BOOT_KERNELS_DIR to delete
  local list="$1" fname
  while IFS= read -r fname; do
    [[ -n "$fname" ]] || continue
    if [[ -w "$BOOT_KERNELS_DIR" ]]; then
      rm -f -- "$BOOT_KERNELS_DIR/$fname"
    else
      sudo rm -f -- "$BOOT_KERNELS_DIR/$fname"
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
  # --apply with no --evict: Phase 1 only. No boot-menu edit at all, so
  # this is the lowest-risk apply path -- one typed confirmation.
  if [[ "$ORPHAN_COUNT" -eq 0 ]]; then
    echo "Nothing to apply -- no orphaned files found."
    exit 0
  fi
  echo "APPLY MODE: this will permanently delete the $ORPHAN_COUNT orphaned file(s) listed above"
  echo "($((TOTAL_ORPHAN_BYTES / 1024 / 1024)) MiB). $BOOT_CONF_DISPLAY is not touched by this."
  confirm_exact "Type 'yes' to proceed, or 'q' to cancel: " "yes"
  echo
  echo "Deleting orphaned files..."
  delete_files "$ORPHAN_LIST"
  echo
  echo "Done. Re-run without --apply to confirm /boot space and remaining files."
  exit 0
fi

# ---------------------------------------------------------------------------
# Phase 2 preview: show what evicting generation $EVICT_GEN would remove,
# without touching anything, and recompute orphans as if it were gone.
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

KEPT_GENS="$(backend_kept_generations_strict)"
KEPT_COUNT=$(grep -c '.' <<<"$KEPT_GENS" || true)
if ! grep -qxF "$EVICT_GEN" <<<"$KEPT_GENS"; then
  echo "Generation $EVICT_GEN is not currently in the boot menu -- nothing to evict." >&2
  exit 1
fi
if [[ "$KEPT_COUNT" -le "$MIN_KEPT" ]]; then
  echo "Refusing to preview: only $KEPT_COUNT generation(s) currently kept in the boot menu." >&2
  echo "Evicting one would drop below the minimum of $MIN_KEPT kept generations." >&2
  exit 1
fi

ENTRY_ID="$(backend_entry_id_for_gen "$EVICT_GEN")"

BLOCK="$(backend_preview_evict "$ENTRY_ID")"
if [[ -z "$BLOCK" ]]; then
  echo "Could not locate generation $EVICT_GEN's boot-menu entry -- refusing to guess further." >&2
  exit 1
fi

echo "This would be removed from $BOOT_CONF_DISPLAY:"
echo "----------------------------------------------------------------------"
echo "$BLOCK"
echo "----------------------------------------------------------------------"
echo

NEW_REFERENCED="$(backend_referenced_files "$ENTRY_ID")"

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
  echo "  $NEWLY_ORPHANED_COUNT file(s), $((NEWLY_ORPHANED_BYTES / 1024 / 1024)) MiB additional -- would require the boot-menu edit above plus deleting these."
fi
echo

if [[ "$APPLY" -eq 0 ]]; then
  echo "This was a preview only. Nothing on disk or in $BOOT_CONF_DISPLAY has been changed."
  exit 0
fi

# ---------------------------------------------------------------------------
# Phase 2 apply: edit the boot menu for real, with a backup and validation
# gate before the write, then delete the files that edit orphans.
# ---------------------------------------------------------------------------
echo "APPLY MODE: this will:"
STEP=1
if [[ "$ORPHAN_COUNT" -gt 0 ]]; then
  echo "  $STEP. Delete the $ORPHAN_COUNT Phase 1 orphaned file(s) reported above ($((TOTAL_ORPHAN_BYTES / 1024 / 1024)) MiB) -- done"
  echo "     first, before touching $BOOT_CONF_DISPLAY, so there's room to write it even if"
  echo "     /boot is currently completely full"
  STEP=$((STEP + 1))
fi
echo "  $STEP. Back up $BOOT_CONF_DISPLAY"
STEP=$((STEP + 1))
echo "  $STEP. Remove generation $EVICT_GEN's entry shown above from $BOOT_CONF_DISPLAY"
STEP=$((STEP + 1))
echo "  $STEP. Delete the $NEWLY_ORPHANED_COUNT newly-orphaned file(s) above ($((NEWLY_ORPHANED_BYTES / 1024 / 1024)) MiB)"
STEP=$((STEP + 1))
echo "  $STEP. Run: nix-env --delete-generations $EVICT_GEN --profile /nix/var/nix/profiles/system"
echo
echo "Generation $EVICT_GEN's boot menu entry cannot be recovered after this except from the backup."
confirm_exact "Type the generation number ($EVICT_GEN) to confirm, or 'q' to cancel: " "$EVICT_GEN"
confirm_exact "Type 'yes' to proceed, or 'q' to cancel: " "yes"
echo

# --- Validate the predicted post-removal state before writing anything ----
# Evicting one entry always removes exactly the one generation number from
# the kept-generations set -- true for both backends -- so this check
# doesn't need backend-specific "simulate the edit" logic.
NEW_KEPT_GENS=$(grep -vxF "$EVICT_GEN" <<<"$KEPT_GENS" || true)
NEW_KEPT_COUNT=$(grep -c '.' <<<"$NEW_KEPT_GENS" || true)

VALIDATION_FAILED=0
[[ "$NEW_KEPT_COUNT" -eq $((KEPT_COUNT - 1)) ]] || { echo "Validation failed: expected $((KEPT_COUNT - 1)) kept generations after edit, found $NEW_KEPT_COUNT." >&2; VALIDATION_FAILED=1; }
grep -qxF "$CURRENT_GEN" <<<"$NEW_KEPT_GENS" || { echo "Validation failed: current generation $CURRENT_GEN missing from the edited file." >&2; VALIDATION_FAILED=1; }
grep -qxF "$EVICT_GEN" <<<"$NEW_KEPT_GENS" && { echo "Validation failed: generation $EVICT_GEN still present after removal." >&2; VALIDATION_FAILED=1; }

if [[ "$VALIDATION_FAILED" -eq 1 ]]; then
  echo "Refusing to write $BOOT_CONF_DISPLAY -- validation failed. Nothing was changed." >&2
  exit 1
fi
echo "Validation passed ($NEW_KEPT_COUNT kept generations remain, current generation $CURRENT_GEN intact)."
echo

if [[ "$ORPHAN_COUNT" -gt 0 ]]; then
  echo "Deleting Phase 1 orphaned files first (to guarantee room for the $BOOT_CONF_DISPLAY write, even on a completely full /boot)..."
  delete_files "$ORPHAN_LIST"
  echo
fi

BACKUP=""
backend_apply_evict "$ENTRY_ID" BACKUP

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
  echo "menu (generation $EVICT_GEN still exists in the profile but is no longer on the" >&2
  echo "boot menu) -- safe to leave as-is, or retry: sudo nix-env --delete-generations $EVICT_GEN --profile /nix/var/nix/profiles/system" >&2
fi

echo
echo "Done. Backup saved at $BACKUP if you need to restore it."
if [[ "$BOOTLOADER" == "systemd-boot" ]]; then
  echo "Note: if /boot/loader/loader.conf's 'default' line pointed at the entry just"
  echo "removed, it'll look stale until your next successful rebuild rewrites it --"
  echo "same self-healing behaviour as everything else here."
fi
echo "Try your rebuild now (e.g. nh os switch)."
