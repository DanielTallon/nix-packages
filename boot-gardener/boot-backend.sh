# boot-backend.sh — bootloader abstraction shared by gardener.sh
# and rescue.sh. Meant to be sourced, never executed directly.
#
# Supports three backends: "limine", "systemd-boot", and "grub". Detection
# is automatic (based on which marker file exists under /boot) unless
# overridden with --bootloader limine|systemd-boot|grub, which both
# scripts accept and pass through to backend_init.
#
# Public surface, valid after calling backend_init:
#   $BOOTLOADER          "limine", "systemd-boot", or "grub"
#   $BOOT_KERNELS_DIR     directory holding the copied kernel/initrd/EFI files
#   $BOOT_CONF_DISPLAY    human-readable name for "the boot menu config", for messages
#
#   backend_supports_pin
#       Returns 0 (true) only for limine. The picker uses this to gate
#       'Enter' -- pinning writes Nix-level config consumed by a
#       Limine-specific NixOS module (limine-manual-pins.nix) that has no
#       systemd-boot or GRUB equivalent yet.
#
#   backend_kept_generations_lenient
#       Prints a newline list of generation numbers currently on the boot
#       menu. Never exits on a read failure -- prints a "Note:" to stderr
#       and prints nothing, for callers (the picker's live BOOT column)
#       that can tolerate partial information. Its own return status still
#       tells the caller whether the read worked (0) or failed (1) -- a
#       failed read is NOT the same thing as a confirmed-empty boot menu,
#       and callers must check this rather than treating empty output as
#       "zero generations in the boot menu."
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
#       (for limine and grub: the generation number itself, since both
#       are single shared config files identified by content, not by
#       filename; for systemd-boot: the entry file's basename). Exits if
#       GEN isn't currently on the boot menu. Used both to exclude it in
#       backend_referenced_files and to drive backend_preview_evict /
#       backend_apply_evict.
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

GRUB_CONF="/boot/grub/grub.cfg"
GRUB_KERNELS_DIR="/boot/kernels"

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
  #
  # Deliberately does NOT treat "doesn't exist" as "zero files" here --
  # for limine/systemd-boot a missing kernels dir is a genuinely broken
  # install and should fail loud, matching the strict/lenient split
  # documented at the top of this file. GRUB's copyKernels=false case
  # (where $GRUB_KERNELS_DIR legitimately never exists) is handled by its
  # caller checking path_exists_root first, not by softening this.
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

mtime_root() {
  # Prints a file's mtime as a Unix epoch (root-aware, like the other
  # helpers above), or nothing if it can't be read.
  local path="$1"
  if [[ -r "$path" ]]; then
    stat -c '%Y' "$path" 2>/dev/null
  elif command -v sudo >/dev/null 2>&1; then
    sudo stat -c '%Y' "$path" 2>/dev/null
  fi
}

_BACKEND_NAMES=(limine systemd-boot grub)

_marker_for_backend() {
  case "$1" in
    limine) echo "$LIMINE_CONF" ;;
    systemd-boot) echo "/boot/loader/loader.conf" ;;
    grub) echo "$GRUB_CONF" ;;
  esac
}

detect_bootloader() {
  # Prints "limine", "systemd-boot", or "grub" on stdout, or exits with an
  # error if none of the three markers is present.
  #
  # If MORE THAN ONE marker is present, this is very commonly a stale
  # leftover -- NixOS's bootloader installers don't clean up the
  # *previous* loader's files when you switch, so an abandoned config just
  # sits there untouched forever. Only the bootloader actually in use gets
  # its files rewritten on every rebuild, so whichever marker has the most
  # recent mtime wins; --bootloader is still there to override this guess
  # if it's ever wrong.
  local b marker found=()
  for b in "${_BACKEND_NAMES[@]}"; do
    marker="$(_marker_for_backend "$b")"
    path_exists_root "$marker" && found+=("$b")
  done

  case "${#found[@]}" in
    0)
      echo "Error: found none of $(_marker_for_backend limine)," >&2
      echo "/boot/loader/loader.conf, or $(_marker_for_backend grub) --" >&2
      echo "this tool only supports Limine, systemd-boot, and GRUB on NixOS." >&2
      echo "If one of these really is in use but under a nonstandard path," >&2
      echo "pass --bootloader limine, --bootloader systemd-boot, or" >&2
      echo "--bootloader grub explicitly to skip detection." >&2
      exit 1
      ;;
    1)
      echo "${found[0]}"
      ;;
    *)
      echo "Note: more than one bootloader marker exists (${found[*]}) --" >&2
      echo "one is likely a stale leftover from before you switched" >&2
      echo "bootloaders. Picking whichever was rebuilt more recently." >&2
      local best="" best_mtime=-1 this_mtime all_known=1
      for b in "${found[@]}"; do
        this_mtime="$(mtime_root "$(_marker_for_backend "$b")")"
        if [[ -z "$this_mtime" ]]; then
          all_known=0
          break
        fi
        if [[ "$this_mtime" -gt "$best_mtime" ]]; then
          best_mtime="$this_mtime"
          best="$b"
        fi
      done
      if [[ "$all_known" -eq 1 && -n "$best" ]]; then
        echo "-> $best ($(_marker_for_backend "$best") is newest)" >&2
        echo "$best"
        echo "If this guess is wrong, pass --bootloader limine, --bootloader systemd-boot, or --bootloader grub explicitly." >&2
      else
        echo "Error: more than one bootloader marker exists, and at least" >&2
        echo "one of their mtimes couldn't be read -- can't guess which is" >&2
        echo "actually in use. Pass --bootloader limine, --bootloader" >&2
        echo "systemd-boot, or --bootloader grub explicitly." >&2
        exit 1
      fi
      ;;
  esac
}

backend_init() {
  # $1: explicit override ("limine"/"systemd-boot"/"grub"), or empty to
  # auto-detect
  local override="${1:-}"
  if [[ -n "$override" ]]; then
    case "$override" in
      limine | systemd-boot | grub) BOOTLOADER="$override" ;;
      *)
        echo "Error: --bootloader must be 'limine', 'systemd-boot', or 'grub', got '$override'." >&2
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
    grub)
      BOOT_KERNELS_DIR="$GRUB_KERNELS_DIR"
      BOOT_CONF_DISPLAY="$GRUB_CONF"
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

_kept_generations_grub() {
  # GRUB's NixOS module names each kept generation's block (a plain
  # `menuentry` if it has no specialisations, or a `submenu` wrapping
  # several `menuentry`s if it does) "NixOS - Configuration N (date -
  # version)", inside the outer "NixOS - All configurations" submenu.
  #
  # The "N (" anchor -- a space then an open paren directly after the
  # number -- matters: a generation WITH specialisations also has inner
  # per-specialisation menuentries titled "NixOS - Configuration N -
  # Default (...)" and "NixOS - Configuration N - <spec name>", which
  # share the "NixOS - Configuration N" prefix but are never followed by
  # " (" there. Without this anchor those inner lines match too, and a
  # single kept generation gets counted (and, worse, evicted-and-
  # revalidated) as several -- confirmed in a sandboxed grub.cfg with one
  # specialised generation, which showed up 3 times instead of once.
  local content="$1"
  grep -oE '^(menuentry|submenu) "NixOS - Configuration [0-9]+ \(' <<<"$content" |
    grep -oE '[0-9]+' || true
}

backend_kept_generations_lenient() {
  # Unlike the helpers it calls, THIS function's own return status is
  # meaningful and must stay that way: 0 means "the read succeeded, the
  # printed list (possibly empty) is trustworthy"; 1 means "couldn't read
  # the boot menu at all" (try_read_root_file/try_list_root_dir already
  # printed a "Note:" to stderr explaining why). Callers MUST treat those
  # two cases differently -- a failed read must never be presented as a
  # confirmed-empty boot menu, since that silently makes every generation
  # look prunable and every harvest look refused. The trailing `return 0`
  # is deliberate: it decouples this function's success/failure signal
  # from whatever exit status the underlying _kept_generations_* parser
  # happens to return (that's about its own internal read-loop mechanics,
  # not about whether the read itself succeeded).
  case "$BOOTLOADER" in
    limine)
      local content
      content=$(try_read_root_file "$LIMINE_CONF") || return 1
      _kept_generations_limine "$content"
      ;;
    systemd-boot)
      local listing
      listing=$(try_list_root_dir "$SYSTEMD_BOOT_ENTRIES_DIR" '*.conf') || return 1
      _kept_generations_systemd_boot "$listing"
      ;;
    grub)
      local content
      content=$(try_read_root_file "$GRUB_CONF") || return 1
      _kept_generations_grub "$content"
      ;;
  esac
  return 0
}

backend_kept_generations_strict() {
  case "$BOOTLOADER" in
    limine)
      _kept_generations_limine "$(read_root_file "$LIMINE_CONF")"
      ;;
    systemd-boot)
      _kept_generations_systemd_boot "$(list_root_dir "$SYSTEMD_BOOT_ENTRIES_DIR" '*.conf')"
      ;;
    grub)
      _kept_generations_grub "$(read_root_file "$GRUB_CONF")"
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
    grub) echo "$gen" ;;
  esac
}

# --- GRUB block extraction (shared by referenced-files/preview/apply) ------
#
# grub.cfg is one shared file, like limine.conf, but a generation's block
# isn't a fixed shape: no specialisations means one plain `menuentry { ...
# }`, but any specialisations wrap that same entry (plus one more per
# specialisation) inside a `submenu { ... }`. Rather than assume which
# shape it is, track brace depth from the opening `menuentry`/`submenu`
# line to its balanced closing "}" -- this handles both uniformly, and
# doesn't depend on a sentinel comment the way the Limine parser does.

_grub_block_for_gen() {
  # $1: grub.cfg content, $2: generation number. Prints just that
  # generation's block (read-only extraction).
  local content="$1" gen="$2"
  awk -v gen="$gen" '
    BEGIN { depth = 0; capturing = 0 }
    !capturing && $0 ~ ("^(menuentry|submenu) \"NixOS - Configuration " gen " \\(") {
      capturing = 1
      o = gsub(/\{/, "{"); c = gsub(/\}/, "}")
      depth = o - c
      print
      next
    }
    capturing {
      o = gsub(/\{/, "{"); c = gsub(/\}/, "}")
      depth += o - c
      print
      if (depth <= 0) capturing = 0
    }
  ' <<<"$content"
}

_grub_conf_without_gen() {
  # $1: grub.cfg content, $2: generation number. Prints content with that
  # generation's whole block cut out (the inverse of _grub_block_for_gen).
  local content="$1" gen="$2"
  awk -v gen="$gen" '
    BEGIN { depth = 0; skipping = 0 }
    !skipping && $0 ~ ("^(menuentry|submenu) \"NixOS - Configuration " gen " \\(") {
      skipping = 1
      o = gsub(/\{/, "{"); c = gsub(/\}/, "}")
      depth = o - c
      next
    }
    skipping {
      o = gsub(/\{/, "{"); c = gsub(/\}/, "}")
      depth += o - c
      if (depth <= 0) skipping = 0
      next
    }
    { print }
  ' <<<"$content"
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

_referenced_files_grub() {
  # $1: grub.cfg content, $2: exclude entry id (a generation number), or
  # "" to exclude nothing.
  local conf_content="$1" exclude_gen="${2:-}" filtered="$1"
  if [[ -n "$exclude_gen" ]]; then
    filtered=$(_grub_conf_without_gen "$conf_content" "$exclude_gen")
  fi
  # Matched as "...kernels/NAME" rather than anchored to a fixed prefix,
  # since the path GRUB writes ("/kernels/NAME" vs "/boot/kernels/NAME")
  # depends on whether $bootPath is its own filesystem -- either way the
  # files actually live in $GRUB_KERNELS_DIR, which is what matters here.
  grep -oE '/kernels/[^[:space:]]+' <<<"$filtered" | sed 's#.*/kernels/##' | sort -u
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
    grub)
      _referenced_files_grub "$(read_root_file "$GRUB_CONF")" "$exclude"
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
    grub)
      _grub_block_for_gen "$(read_root_file "$GRUB_CONF")" "$entry_id"
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
    grub)
      backup="${GRUB_CONF}.bak-$(date +%Y%m%d%H%M%S)"
      local new_content orig_mode
      new_content=$(_grub_conf_without_gen "$(read_root_file "$GRUB_CONF")" "$entry_id")
      # Same reasoning as the limine branch above: capture the original
      # file's permission bits before writing through a mktemp file (600
      # by default), so a plain `cp` (no -p) onto grub.cfg.new doesn't
      # silently lock non-root reads out of a file that was likely more
      # open before.
      orig_mode=$(sudo stat -c '%a' "$GRUB_CONF" 2>/dev/null || echo "")
      echo "Backing up to $backup..."
      sudo cp -p "$GRUB_CONF" "$backup"
      local tmpfile
      tmpfile=$(mktemp)
      printf '%s\n' "$new_content" >"$tmpfile"
      echo "Writing new $GRUB_CONF..."
      sudo cp "$tmpfile" "${GRUB_CONF}.new"
      sudo mv "${GRUB_CONF}.new" "$GRUB_CONF"
      [[ -n "$orig_mode" ]] && sudo chmod "$orig_mode" "$GRUB_CONF"
      rm -f "$tmpfile"
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
