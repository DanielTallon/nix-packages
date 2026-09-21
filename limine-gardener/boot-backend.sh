# boot-backend.sh — bootloader abstraction shared by limine-pin-picker.sh
# and limine-boot-rescue.sh. Meant to be sourced, never executed directly.
#
# Supports two backends: "limine" and "systemd-boot". Detection is
# automatic (based on which marker file exists under /boot) unless
# overridden with --bootloader limine|systemd-boot, which both scripts
# accept and pass through to backend_init.
#
# Public surface, valid after calling backend_init:
#   $BOOTLOADER          "limine" or "systemd-boot"
#   $BOOT_KERNELS_DIR     directory holding the copied kernel/initrd/EFI files
#   $BOOT_CONF_DISPLAY    human-readable name for "the boot menu config", for messages
#
#   backend_supports_pin
#       Returns 0 (true) only for limine. The picker uses this to gate
#       'Enter' -- pinning writes Nix-level config consumed by a
#       Limine-specific NixOS module (limine-manual-pins.nix) that has no
#       systemd-boot equivalent yet.
#
#   backend_kept_generations_lenient
#       Prints a newline list of generation numbers currently on the boot
#       menu. Never exits on a read failure -- prints a "Note:" to stderr
#       and prints nothing, for callers (the picker's live BOOT column)
#       that can tolerate partial information.
#
#   backend_kept_generations_strict
#       Same, but exits the whole script on a read failure. For callers
#       (rescue) that are about to make destructive decisions and must
#       not silently proceed on incomplete information.
#
#   backend_referenced_files [EXCLUDE_ENTRY]
#       Prints a newline list of filenames under $BOOT_KERNELS_DIR that
#       are still referenced by *some* boot-menu entry. With EXCLUDE_ENTRY
#       set (an opaque entry id from backend_kept_generations' companion
#       backend_entry_id_for_gen), that one entry's own references are
#       left out of the count -- used to preview/compute what a
#       generation's eviction would orphan, without touching anything.
#       Always the strict (exit-on-failure) read behaviour, since it's
#       only ever called from rescue.
#
#   backend_entry_id_for_gen GEN
#       Prints an opaque identifier for generation GEN's boot-menu entry
#       (for limine: the generation number itself; for systemd-boot: the
#       entry file's basename). Exits if GEN isn't currently on the boot
#       menu. Used both to exclude it in backend_referenced_files and to
#       drive backend_preview_evict / backend_apply_evict.
#
#   backend_preview_evict ENTRY_ID
#       Prints, to stdout, the human-readable block/file that would be
#       removed for ENTRY_ID. Read-only.
#
#   backend_apply_evict ENTRY_ID
#       Actually removes ENTRY_ID's boot-menu entry, having already backed
#       it up. Prints the backup path it made. Exits non-zero (via the
#       caller's own `set -e`, since this function itself calls `exit 1`
#       through validation helpers) if anything looks wrong -- callers
#       should treat any failure here as "nothing was written", matching
#       the validate-before-write guarantee both backends provide.
#
# Both backends share the same on-disk root-read helpers, since both may
# need sudo to read under /boot.

LIMINE_CONF="/boot/limine/limine.conf"
LIMINE_KERNELS_DIR="/boot/limine/kernels"

SYSTEMD_BOOT_ENTRIES_DIR="/boot/loader/entries"
SYSTEMD_BOOT_EFI_NIXOS_DIR="/boot/EFI/nixos"

# --- generic root-read helpers ----------------------------------------------

read_root_file() {
  # Strict: exits the script if the file can't be read at all.
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

try_read_root_file() {
  # Lenient: never exits. Echoes the content and returns 0 on success;
  # prints a "Note:" to stderr and returns 1 on failure.
  local path="$1" content
  if [[ -r "$path" ]]; then
    cat "$path"
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    if content=$(sudo cat "$path" 2>&1); then
      printf '%s' "$content"
      return 0
    fi
    echo "Note: couldn't read $path as root:" >&2
    echo "  $content" >&2
    echo "  Bootloader-in-use markers will be unavailable this run." >&2
    return 1
  fi
  echo "Note: $path isn't readable and 'sudo' isn't available -- bootloader-in-use markers will be unavailable this run." >&2
  return 1
}

list_root_dir() {
  # Strict: exits the script if the directory can't be listed at all.
  # $1: directory  $2: find -name glob pattern (default: all files)
  local path="$1" pattern="${2:-*}"
  if [[ -r "$path" ]]; then
    find "$path" -maxdepth 1 -type f -name "$pattern" -printf '%f\t%s\n'
  elif command -v sudo >/dev/null 2>&1; then
    sudo find "$path" -maxdepth 1 -type f -name "$pattern" -printf '%f\t%s\n'
  else
    echo "Error: cannot list '$path' (not readable, and no sudo available)." >&2
    exit 1
  fi
}

try_list_root_dir() {
  # Lenient counterpart to list_root_dir, matching try_read_root_file.
  local path="$1" pattern="${2:-*}" out
  if [[ -r "$path" ]]; then
    find "$path" -maxdepth 1 -type f -name "$pattern" -printf '%f\t%s\n'
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    if out=$(sudo find "$path" -maxdepth 1 -type f -name "$pattern" -printf '%f\t%s\n' 2>&1); then
      printf '%s\n' "$out"
      return 0
    fi
    echo "Note: couldn't list $path as root:" >&2
    echo "  $out" >&2
    echo "  Bootloader-in-use markers will be unavailable this run." >&2
    return 1
  fi
  echo "Note: $path isn't readable and 'sudo' isn't available -- bootloader-in-use markers will be unavailable this run." >&2
  return 1
}

# --- detection / init --------------------------------------------------------

path_exists_root() {
  # Like [[ -e "$path" ]], but falls back to sudo when a plain check can't
  # be trusted -- a parent directory that isn't traversable by the calling
  # user (very common for /boot/limine or /boot itself) makes -e silently
  # report "doesn't exist" even when the file is right there. Mirrors the
  # same reasoning read_root_file/list_root_dir already apply to actually
  # reading things.
  local path="$1"
  if [[ -e "$path" ]]; then
    return 0
  elif command -v sudo >/dev/null 2>&1; then
    sudo test -e "$path" 2>/dev/null
  else
    return 1
  fi
}

detect_bootloader() {
  # Prints "limine" or "systemd-boot" on stdout, or exits with an error if
  # neither marker is present (or both are, since that's ambiguous enough
  # to want an explicit --bootloader rather than a guess).
  local have_limine=0 have_systemd_boot=0
  path_exists_root "$LIMINE_CONF" && have_limine=1
  path_exists_root "/boot/loader/loader.conf" && have_systemd_boot=1

  if [[ "$have_limine" -eq 1 && "$have_systemd_boot" -eq 0 ]]; then
    echo "limine"
  elif [[ "$have_systemd_boot" -eq 1 && "$have_limine" -eq 0 ]]; then
    echo "systemd-boot"
  elif [[ "$have_limine" -eq 1 && "$have_systemd_boot" -eq 1 ]]; then
    echo "Error: both $LIMINE_CONF and /boot/loader/loader.conf exist --" >&2
    echo "can't auto-detect which bootloader is actually in use. Pass" >&2
    echo "--bootloader limine or --bootloader systemd-boot explicitly." >&2
    exit 1
  else
    echo "Error: found neither $LIMINE_CONF nor /boot/loader/loader.conf --" >&2
    echo "this tool only supports Limine and systemd-boot on NixOS. If one" >&2
    echo "of these really is in use but under a nonstandard path, pass" >&2
    echo "--bootloader limine or --bootloader systemd-boot explicitly to skip" >&2
    echo "detection." >&2
    exit 1
  fi
}

backend_init() {
  # $1: explicit override ("limine"/"systemd-boot"), or empty to auto-detect
  local override="${1:-}"
  if [[ -n "$override" ]]; then
    case "$override" in
      limine | systemd-boot) BOOTLOADER="$override" ;;
      *)
        echo "Error: --bootloader must be 'limine' or 'systemd-boot', got '$override'." >&2
        exit 1
        ;;
    esac
  else
    BOOTLOADER="$(detect_bootloader)"
  fi

  case "$BOOTLOADER" in
    limine)
      BOOT_KERNELS_DIR="$LIMINE_KERNELS_DIR"
      BOOT_CONF_DISPLAY="$LIMINE_CONF"
      ;;
    systemd-boot)
      BOOT_KERNELS_DIR="$SYSTEMD_BOOT_EFI_NIXOS_DIR"
      BOOT_CONF_DISPLAY="the systemd-boot entries directory ($SYSTEMD_BOOT_ENTRIES_DIR)"
      ;;
  esac
}

backend_supports_pin() {
  [[ "$BOOTLOADER" == "limine" ]]
}

# --- kept generations ---------------------------------------------------------

_kept_generations_limine() {
  local conf_content="$1"
  grep -oE '^//\+?Generation [0-9]+' <<<"$conf_content" | grep -oE '[0-9]+' || true
}

_kept_generations_systemd_boot() {
  local listing="$1" fname
  while IFS=$'\t' read -r fname _; do
    [[ "$fname" =~ ^nixos-generation-([0-9]+)\.conf$ ]] || continue
    echo "${BASH_REMATCH[1]}"
  done <<<"$listing"
}

backend_kept_generations_lenient() {
  case "$BOOTLOADER" in
    limine)
      local content
      content=$(try_read_root_file "$LIMINE_CONF") || return 0
      _kept_generations_limine "$content"
      ;;
    systemd-boot)
      local listing
      listing=$(try_list_root_dir "$SYSTEMD_BOOT_ENTRIES_DIR" '*.conf') || return 0
      _kept_generations_systemd_boot "$listing"
      ;;
  esac
}

backend_kept_generations_strict() {
  case "$BOOTLOADER" in
    limine)
      _kept_generations_limine "$(read_root_file "$LIMINE_CONF")"
      ;;
    systemd-boot)
      _kept_generations_systemd_boot "$(list_root_dir "$SYSTEMD_BOOT_ENTRIES_DIR" '*.conf')"
      ;;
  esac
}

# --- entry id for a generation (opaque; drives evict preview/apply) ---------

backend_entry_id_for_gen() {
  # $1: generation number. Prints an opaque entry id, or exits 1 if that
  # generation isn't currently on the boot menu.
  local gen="$1"
  if ! grep -qxF "$gen" < <(backend_kept_generations_strict); then
    echo "Generation $gen is not currently in the boot menu -- nothing to evict." >&2
    exit 1
  fi
  case "$BOOTLOADER" in
    limine) echo "$gen" ;;
    systemd-boot) echo "nixos-generation-${gen}.conf" ;;
  esac
}

# --- referenced files (for orphan detection) --------------------------------

_referenced_files_limine() {
  # $1: limine.conf content, $2: entry-id to exclude (a generation number),
  # or "" to exclude nothing.
  local conf_content="$1" exclude_gen="${2:-}" filtered="$1"
  if [[ -n "$exclude_gen" ]]; then
    filtered=$(awk -v gen="$exclude_gen" '
      BEGIN { skip = 0 }
      /^\/\/\+?Generation [0-9]+/ {
        match($0, /[0-9]+/)
        thisgen = substr($0, RSTART, RLENGTH)
        if (thisgen == gen) { skip = 1; next }
        else if (skip) { skip = 0 }
      }
      /^# NixOS boot entries end here/ { skip = 0 }
      !skip { print }
    ' <<<"$conf_content")
  fi
  grep -oE '/limine/kernels/[^#[:space:]]+' <<<"$filtered" | sed 's#^/limine/kernels/##' | sort -u
}

_referenced_files_systemd_boot() {
  # $1: exclude entry id (filename), or "" to exclude nothing.
  local exclude_entry="${1:-}" listing fname all_content=""
  listing=$(list_root_dir "$SYSTEMD_BOOT_ENTRIES_DIR" '*.conf')
  while IFS=$'\t' read -r fname _; do
    [[ -n "$fname" ]] || continue
    [[ "$fname" == "$exclude_entry" ]] && continue
    all_content+="$(read_root_file "$SYSTEMD_BOOT_ENTRIES_DIR/$fname")"$'\n'
  done <<<"$listing"
  grep -oE '/EFI/nixos/[^[:space:]]+\.efi' <<<"$all_content" | sed 's#^/EFI/nixos/##' | sort -u
}

backend_referenced_files() {
  # $1: entry id to exclude, or "" (unset) to exclude nothing.
  local exclude="${1:-}"
  case "$BOOTLOADER" in
    limine)
      _referenced_files_limine "$(read_root_file "$LIMINE_CONF")" "$exclude"
      ;;
    systemd-boot)
      _referenced_files_systemd_boot "$exclude"
      ;;
  esac
}

# --- preview / apply eviction ------------------------------------------------

backend_preview_evict() {
  # $1: entry id (from backend_entry_id_for_gen). Prints the human-readable
  # block/file that would be removed. Read-only.
  local entry_id="$1"
  case "$BOOTLOADER" in
    limine)
      awk -v gen="$entry_id" '
        BEGIN { printing = 0 }
        /^\/\/\+?Generation [0-9]+/ {
          match($0, /[0-9]+/)
          thisgen = substr($0, RSTART, RLENGTH)
          if (thisgen == gen) { printing = 1; print; next }
          else if (printing) { printing = 0 }
        }
        /^# NixOS boot entries end here/ { printing = 0 }
        printing { print }
      ' <<<"$(read_root_file "$LIMINE_CONF")"
      ;;
    systemd-boot)
      echo "$SYSTEMD_BOOT_ENTRIES_DIR/$entry_id:"
      read_root_file "$SYSTEMD_BOOT_ENTRIES_DIR/$entry_id"
      ;;
  esac
}

backend_apply_evict() {
  # $1: entry id. $2: name of a caller variable to set to the backup path
  # made. Backs up, then removes, the boot-menu entry for entry_id. Does
  # NOT touch $BOOT_KERNELS_DIR or run nix-env -- callers own those steps,
  # since they're identical across backends.
  local entry_id="$1" __backup_var="$2" backup

  case "$BOOTLOADER" in
    limine)
      backup="${LIMINE_CONF}.bak-$(date +%Y%m%d%H%M%S)"
      local new_content orig_mode
      new_content=$(_limine_conf_without_gen "$entry_id")
      # Capture the original file's permission bits before touching
      # anything -- the write below goes through a mktemp file (600 by
      # default), and without this, `cp` (no -p) onto ${LIMINE_CONF}.new
      # would silently carry that 600 forward onto the real limine.conf,
      # locking non-root reads (including this tool's own next run) out
      # of a file that was likely more open before.
      orig_mode=$(sudo stat -c '%a' "$LIMINE_CONF" 2>/dev/null || echo "")
      echo "Backing up to $backup..."
      sudo cp -p "$LIMINE_CONF" "$backup"
      local tmpfile
      tmpfile=$(mktemp)
      printf '%s\n' "$new_content" >"$tmpfile"
      echo "Writing new $LIMINE_CONF..."
      sudo cp "$tmpfile" "${LIMINE_CONF}.new"
      sudo mv "${LIMINE_CONF}.new" "$LIMINE_CONF"
      [[ -n "$orig_mode" ]] && sudo chmod "$orig_mode" "$LIMINE_CONF"
      rm -f "$tmpfile"
      ;;
    systemd-boot)
      local entry_path="$SYSTEMD_BOOT_ENTRIES_DIR/$entry_id"
      backup="${entry_path}.bak-$(date +%Y%m%d%H%M%S)"
      echo "Backing up to $backup..."
      sudo cp -p "$entry_path" "$backup"
      echo "Removing $entry_path..."
      sudo rm -f "$entry_path"
      ;;
  esac
  printf -v "$__backup_var" '%s' "$backup"
}

# Internal helper: limine.conf content with the given generation's block
# cut out -- used only by backend_apply_evict's limine branch, kept
# separate from _referenced_files_limine so that function can stay a pure
# "list files" helper.
_limine_conf_without_gen() {
  local exclude_gen="$1"
  awk -v gen="$exclude_gen" '
    BEGIN { skip = 0 }
    /^\/\/\+?Generation [0-9]+/ {
      match($0, /[0-9]+/)
      thisgen = substr($0, RSTART, RLENGTH)
      if (thisgen == gen) { skip = 1; next }
      else if (skip) { skip = 0 }
    }
    /^# NixOS boot entries end here/ { skip = 0 }
    !skip { print }
  ' <<<"$(read_root_file "$LIMINE_CONF")"
}
