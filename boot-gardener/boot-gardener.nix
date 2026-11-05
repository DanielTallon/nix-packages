# boot-gardener — single-file package.
#
# Everything that used to live in separate files (the boot-gardener
# dispatcher, gardener.sh, rescue.sh, boot-backend.sh) is embedded below as
# Nix indented strings and written out to the exact same install layout as
# before:
#
#   $out/bin/boot-gardener                      (wrapped with runtime PATH)
#   $out/libexec/boot-gardener/gardener.sh
#   $out/libexec/boot-gardener/rescue.sh
#   $out/libexec/boot-gardener/boot-backend.sh
#
# so the scripts still find each other at runtime exactly as they did.
#
# EDITING NOTE — Nix indented-string escaping inside the script bodies:
#   bash  ${VAR}  is written  ''${VAR}   (otherwise Nix interpolates it)
#   bash  ''       is written  '''       (two single quotes in a row)
#   bash  '${X}    is written  ''\'''${X}  (a ' directly before ${ -- rare,
#                                          only the two "pin, not a
#                                          generation" messages use it)
# Everything else (including a bare $VAR) is literal.

{ lib, stdenvNoCC, makeWrapper, writeText, jq, fzf, coreutils, gnused, gawk, util-linux, findutils, diffutils, less
}:

let
  # --- bin/boot-gardener: thin dispatcher -----------------------------------
  dispatcher = writeText "boot-gardener" ''
    #!/usr/bin/env bash
    # boot-gardener — pick, pin, prune, harvest, or garbage-collect NixOS
    # generations in your Limine, systemd-boot, or GRUB boot menu. Harvest can even
    # work on a /boot partition that's full.
    #
    # A thin dispatcher forwards to gardener.sh by default, or to rescue.sh when
    # the first argument is 'rescue'. Resolves its own installed location at
    # runtime (rather than having Nix bake an absolute path into generated
    # text at build time), so there's nothing here for Nix's
    # string-interpolation rules to trip over.
    set -euo pipefail

    [[ -t 1 ]] && printf '\033]0;Gardener\007'

    SELF="$(readlink -f "''${BASH_SOURCE[0]}")"
    LIBEXEC="$(cd "$(dirname "$SELF")/../libexec/boot-gardener" && pwd)"

    if [[ "''${1:-}" == "rescue" ]]; then
      shift
      exec "$LIBEXEC/rescue.sh" "$@"
    else
      exec "$LIBEXEC/gardener.sh" "$@"
    fi
  '';

  # --- libexec/boot-gardener/gardener.sh: the interactive picker ------------
  gardenerSh = writeText "gardener.sh" ''
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
    # 'r' (pick) rolls the system back (or forward) to the highlighted
    # generation: nix-env --switch-generation, then that generation's own
    # switch-to-configuration switch|boot -- what 'nixos-rebuild switch
    # --rollback' does, for any generation.
    #
    # Nothing asks for a sudo password until an action that needs root runs
    # (see ensure_root); browsing the list only uses sudo if it works without
    # one.
    #
    # 'c' (config) only reads: each generation's recorded commit and the copy
    # of its config under <toplevel>/etc/nixos-config-source. Its one write is
    # copying files out to a folder the user types in, never over an existing
    # file.
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
    CONFIG_SOURCE="nixos-config-source"
    CONFIG_DIR=""
    PAUSE_AFTER_CONFIG=1

    SELF="$(readlink -f "''${BASH_SOURCE[0]}")"
    RESCUE_SCRIPT="$(dirname "$SELF")/rescue.sh"
    # shellcheck source=./boot-backend.sh
    source "$(dirname "$SELF")/boot-backend.sh"
    # Browsing never asks for a sudo password. Only actions that change the
    # system do, when you pick them (see ensure_root below).
    _BG_SUDO_NONINTERACTIVE=1

    usage() {
      cat <<'EOF'
    boot-gardener — browse NixOS generations, and pin one to Limine

    Usage:
      boot-gardener                      Interactively pick a generation --
                                         Enter to pin it (Limine only) or, on a
                                         pin row, to unpin it; 'r' to pick it
                                         (roll back to it, now or at next
                                         boot); 'p' to prune a
                                         non-bootloader generation; 'h' to
                                         harvest a bootloader generation (Tab
                                         to select several first for 'p'/'h');
                                         'c' to browse, diff, or copy the
                                         config a generation was built from
                                         (two rows: diff them);
                                         'g' to garbage-collect (no selection
                                         needed); 'b' to read the boot menu
                                         with sudo; '?' to toggle this help
      boot-gardener --list               List currently pinned entries
      boot-gardener --remove NAME        Remove a pinned entry by name
      boot-gardener --output FILE        Use a different pins file (default: ./limine-pins.json)
      boot-gardener --bootloader limine|systemd-boot|grub
                                         Skip auto-detection and use this backend
      boot-gardener --no-yield           Don't compute the YIELD column (faster
                                         startup; the column shows '?')
      boot-gardener --config-source NAME The /etc name each generation's config
                                         copy is under (default:
                                         nixos-config-source)
      boot-gardener --config-dir DIR     Working config folder for 'c' diffs
                                         (default: the folder in NH_OS_FLAKE or
                                         NH_FLAKE)
      boot-gardener --help               Show this help

    Environment:
      BOOT_GARDENER_COLORS               Replace the built-in green/blue theme
                                         with any fzf --color spec
      NO_COLOR                           Turn off custom colors

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

    Browsing never asks for a sudo password. The boot menu lives on a
    root-only /boot, so the BOOT column shows '?' until sudo has been given
    ('b' reads it). Actions that change the system ('r', 'p', 'h', 'g') ask
    for the password when you use them, then re-read the boot menu before
    doing anything.

    'r' (pick) makes the highlighted generation your system again, like
    'nixos-rebuild switch --rollback' but for any generation: it points the
    system profile at it, then runs its switch-to-configuration -- 'switch'
    to start using it now, or 'boot' to boot into it next time. Both rewrite
    the boot menu with it as the default. Newer generations aren't deleted.
    On Limine, the boot menu always defaults to the newest generation, so
    pick only offers 'switch' there: a reboot goes back to the newest one
    unless you choose the picked one in the boot menu. Before the final
    confirmation, pick shows how the boot menu will change under the picked
    generation's settings and about how much new /boot space that needs.

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

    # --- Look and feel ----------------------------------------------------------
    # Greens and blues: green for the things that grow (borders, prompt,
    # pointer, the highlighted row), blue for the things you read (headers,
    # filter matches, multi-select marks). Truecolor hex, so it looks the same
    # whatever the terminal's own palette is. BOOT_GARDENER_COLORS replaces it
    # wholesale with any fzf --color spec (e.g. "dark", "16", or your own hex
    # list); NO_COLOR drops the custom colors here and on the splash.
    GARDEN_FZF_COLORS="fg:#b4cfb0,fg+:#eaf6e2:bold,bg+:#1c3a2f,selected-bg:#183245"
    GARDEN_FZF_COLORS+=",hl:#6cb6ff,hl+:#9fd3ff:bold,query:#eaf6e2,prompt:#8fd694"
    GARDEN_FZF_COLORS+=",pointer:#9be564,marker:#6cb6ff,spinner:#7fc8f8,info:#8fb8a3"
    GARDEN_FZF_COLORS+=",gutter:#1c3a2f,scrollbar:#3f7f5a,separator:#2f5a45"
    GARDEN_FZF_COLORS+=",border:#3f7f5a,label:#8fd694,list-border:#3f7f5a,list-label:#8fd694"
    GARDEN_FZF_COLORS+=",input-border:#3a6f8f,input-label:#7fc8f8"
    GARDEN_FZF_COLORS+=",header:#7fc8e0,header-border:#3a6f8f,header-label:#7fc8f8"
    GARDEN_FZF_COLORS+=",footer:#8fbf9f,footer-border:#3f7f5a,footer-label:#8fd694"
    GARDEN_FZF_COLORS+=",preview-fg:#c8dccc,preview-border:#3a6f8f,preview-label:#7fc8f8"

    FZF_THEME_ARGS=()
    if [[ -z "''${NO_COLOR:-}" ]]; then
      FZF_THEME_ARGS=(--color "''${BOOT_GARDENER_COLORS:-$GARDEN_FZF_COLORS}")
    fi

    # Splash shown once, while the first load runs (boot-menu read, if sudo
    # works without a password, and the YIELD closure measurement). Anything
    # those print, like "Measuring YIELD...", lands underneath it.
    #
    # The art and its color mask are two same-shaped blocks: each character in
    # the mask picks the color of the character in the same spot in the art.
    #   b l s c a w  blossoms (blue, periwinkle, sky, cyan, aqua, pale)
    #   y            flower centres     g  stems and leaves
    #   d            grass              e  soil
    # Edit both together and keep them lined up.
    show_garden_splash() {
      [[ -t 1 ]] || return 0
      local -a art mask
      mapfile -t art <<'ART'
                           .-.                     .--.
        _/\_       \|/    ( o )      _/\_         ( {} )
       (    )     --*--    `|'      (    )   .-.   '--'
        \__/   o   /|\      |   o    \__/   ( o )   ||
         ||    |    |       |/  |     ||     `|'    ||
       \ || /  |    |/     \|   |     ||      |    \||
        \||/   |   \|       |   |    \||/    \|     ||/
     ,;.,||,;,.|,;,.|,;,.;,.|,;,|,;,.,;||,;,.;|,;,.,||,;,.
     ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ART
      mapfile -t mask <<'MASK'
                           www                     llll
        bbbb       ccc    w y w      llll         l yy l
       b    b     ccycc    wgw      l    l   aaa   llll
        bbbb   s   ccc      g   s    llll   a y a   gg
         gg    g    g       gg  g     gg     aga    gg
       g gg g  g    gg     gg   g     gg      g    ggg
        gggg   g   gg       g   g    gggg    gg     ggg
     ddddggddddgddddgdddddddgdddgddddddggdddddgdddddggdddd
     eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
    MASK

      local -A ink=()
      local reset=""
      if [[ -z "''${NO_COLOR:-}" ]]; then
        ink=(
          [b]=$'\033[38;2;79;163;224m'
          [l]=$'\033[38;2;140;158;255m'
          [s]=$'\033[38;2;108;182;255m'
          [c]=$'\033[38;2;95;215;215m'
          [a]=$'\033[38;2;127;219;202m'
          [w]=$'\033[38;2;207;232;255m'
          [y]=$'\033[38;2;242;229;166m'
          [g]=$'\033[38;2;106;191;105m'
          [d]=$'\033[38;2;63;154;90m'
          [e]=$'\033[38;2;74;102;112m'
        )
        reset=$'\033[0m'
      fi

      local i j ch m mrow prev line
      printf '\033[H\033[2J\n'
      for i in "''${!art[@]}"; do
        mrow="''${mask[i]:-}"
        line="  "
        prev=""
        for ((j = 0; j < ''${#art[i]}; j++)); do
          ch="''${art[i]:j:1}"
          m="''${mrow:j:1}"
          [[ -n "$m" ]] || m=" "
          if [[ "$m" != "$prev" ]]; then
            line+="''${reset}''${ink[$m]:-}"
            prev="$m"
          fi
          line+="$ch"
        done
        printf '%s%s\n' "$line" "$reset"
      done
      printf '\n  %sTending the garden -- reading your generations...%s\n\n' "''${ink[d]:-}" "$reset"
    }

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --list)
          ACTION="list"
          shift
          ;;
        --remove)
          ACTION="remove"
          REMOVE_NAME="''${2:-}"
          shift 2
          ;;
        --output)
          OUTPUT="''${2:-}"
          shift 2
          ;;
        --bootloader)
          BOOTLOADER_OVERRIDE="''${2:-}"
          shift 2
          ;;
        --no-yield)
          YIELD_ENABLED=0
          shift
          ;;
        --config-source)
          CONFIG_SOURCE="''${2:-}"
          shift 2
          ;;
        --config-dir)
          CONFIG_DIR="''${2:-}"
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
    show_garden_splash
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

      r        Pick: go back to the highlighted generation, like
               'nixos-rebuild switch --rollback' but for any generation.
               Choose 'switch' (start using it now) or 'boot' (boot into it
               next time); either way it becomes the boot menu's default.
               On Limine it's 'switch' only: the boot menu always defaults
               to the newest generation, so choose the picked one there to
               boot back into it. Shows the boot-menu changes and new /boot
               space needed before you confirm.
               Newer generations aren't deleted, and your next rebuild lands
               on top as usual. Typed confirmation required.

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

      c        Config. On one row (generation or 📌 pin): browse the copy of
               the config that built it -- Enter views a file, Ctrl-D diffs
               it against the running generation's copy, Ctrl-W against your
               working config folder, Ctrl-S copies it out to a folder you
               name (never replacing a file already there). The
               "[all files]" row does any of those for the whole copy. On
               two Tab-marked rows: diff their configs. Read-only apart
               from copying out. Needs the two lines in the README (only
               generations built after adding them have a copy).

      b        Read the boot menu with sudo, to fill in the BOOT column.
               Browsing never asks for a password on its own: the boot menu
               is root-only, so BOOT shows '?' until you press b or use an
               action that needs root (r, p, h, g), which asks then.

      ?        Toggle this help.

      REV      (column) Commit the generation was built from; '*' means it
               had uncommitted changes, '-' means it didn't record one.

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
      printf -v "$__resultvar" '%s' "''${input:-$default}"
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

      DEFAULT_NAME="gen-''${GEN}"
      DEFAULT_TITLE="NixOS (gen ''${GEN} — ''${GEN_DATE})"

      prompt "Short id [no spaces] (press enter for: ''${DEFAULT_NAME}) [q to cancel, back to menu]: " "$DEFAULT_NAME" NAME ||
        { echo "Cancelled pinning generation $GEN. Back to the list."; return 1; }
      prompt "Menu title (press enter for: ''${DEFAULT_TITLE}) [q to cancel, back to menu]: " "$DEFAULT_TITLE" TITLE ||
        { echo "Cancelled pinning generation $GEN. Back to the list."; return 1; }
      prompt "Comment (optional) [q to cancel, back to menu]: " "" COMMENT ||
        { echo "Cancelled pinning generation $GEN. Back to the list."; return 1; }

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
      ensure_root "Garbage-collecting" || return 1
      # Global action -- not tied to whatever's selected in the list. Two parts:
      # 1) boot orphans (delegated entirely to rescue.sh's own Phase 1
      #    report/apply, same as running it by hand with no --evict);
      # 2) plain Nix GC for anything left over from nix-shell/nix develop
      #    sessions or stray build results, which never touches a generation
      #    or the boot menu config at all -- just dead store paths.
      echo
      echo "== Boot orphans (files referenced by nothing on the boot menu) =="
      if [[ -x "$RESCUE_SCRIPT" ]]; then
        "$RESCUE_SCRIPT" "''${RESCUE_ARGS[@]}" || true
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
        "$RESCUE_SCRIPT" "''${RESCUE_ARGS[@]}" --apply || echo "Note: boot-orphan cleanup was cancelled or found nothing to do -- continuing." >&2
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

      if [[ "$BOOT_STATE" != ok ]]; then
        echo
        echo "Can't read the boot menu, so there's no telling whether generation" >&2
        echo "$GEN is on it -- refusing to prune it." >&2
        return 1
      fi

      if [[ -n "''${IN_BOOTLOADER[$GEN]:-}" ]]; then
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
      echo "skips this generation and returns you to the list.)"
      echo

      if [[ ! -x "$RESCUE_SCRIPT" ]]; then
        echo "Error: expected rescue.sh alongside this script at:" >&2
        echo "  $RESCUE_SCRIPT" >&2
        return 1
      fi

      # Run as a normal child process (not exec) so control returns to the
      # picker's menu loop afterward, whether this succeeds, is refused by
      # rescue's own guardrails, or is cancelled at one of its prompts.
      if "$RESCUE_SCRIPT" "''${RESCUE_ARGS[@]}" --evict "$GEN" --apply; then
        return 0
      else
        echo "Harvest of generation $GEN did not complete (cancelled or refused) -- back to the list." >&2
        return 1
      fi
    }

    # --- Root, only when it's needed ---------------------------------------------
    # Browsing the list never asks for a password. The boot menu lives under a
    # root-only /boot, so until sudo has been given the BOOT column shows '?'
    # ('locked'). Every action that needs root calls ensure_root first, which
    # asks for the password right then and re-reads the boot menu, so the
    # action's own checks always see the real, current menu.
    #
    # BOOT_STATE is one of:
    #   ok      read just now
    #   locked  not read: it needs a sudo password nobody has typed yet
    #   stale   sudo has timed out since the last good read, so the BOOT
    #           column shows that read (BOOT_LAST_READ_AT) rather than going
    #           blank. ensure_root always re-reads before an action uses it.
    #   failed  a real read error (see the 'Note:' it printed)
    BOOT_STATE=locked
    BOOT_LAST_LIST=""
    BOOT_LAST_READ_AT=""
    BOOT_COUNT=0
    declare -A IN_BOOTLOADER=()

    read_boot_menu() {
      local list="" bgen
      IN_BOOTLOADER=()
      BOOT_COUNT=0
      if ! backend_boot_menu_readable; then
        if [[ -n "$BOOT_LAST_READ_AT" ]]; then
          BOOT_STATE=stale
          list="$BOOT_LAST_LIST"
        else
          BOOT_STATE=locked
          return 0
        fi
      # Captured into a variable rather than read through `< <(...)`, so the
      # exit status is checkable: process substitution throws it away, and a
      # failed read would look exactly like an empty boot menu.
      elif list=$(backend_kept_generations_lenient); then
        BOOT_STATE=ok
        BOOT_LAST_LIST="$list"
        BOOT_LAST_READ_AT=$(date +%H:%M)
      else
        BOOT_STATE=failed
        return 0
      fi
      while read -r bgen; do
        if [[ -n "$bgen" ]]; then
          IN_BOOTLOADER["$bgen"]=1
          BOOT_COUNT=$((BOOT_COUNT + 1))
        fi
      done <<<"$list"
    }

    # $1: what's about to happen, for the message ("Pruning", ...). Returns 1
    # (and the caller changes nothing) if sudo can't be had.
    ensure_root() {
      local what="$1"
      if ! _bg_sudo_ready; then
        if ! command -v sudo >/dev/null 2>&1; then
          echo
          echo "$what needs root, and 'sudo' isn't available -- nothing changed." >&2
          return 1
        fi
        echo
        echo "$what needs administrator rights -- sudo will ask for your password."
        if ! sudo -v; then
          echo "Couldn't get sudo -- nothing changed." >&2
          return 1
        fi
      fi
      read_boot_menu
      return 0
    }

    # --- Pick ('r'): go back to a generation --------------------------------------
    # What 'nixos-rebuild switch --rollback' does for the previous generation,
    # for any generation: point the system profile at it (nix-env
    # --switch-generation), then run that generation's own
    # switch-to-configuration. 'switch' activates it now; 'boot' only makes it
    # the boot menu's default for next time. Both rewrite the boot menu. Newer
    # generations stay in the profile -- nothing is deleted. Limine is the
    # exception: its installer always defaults to the newest generation, so
    # 'boot' would do nothing useful there and pick only switches.

    # Runs it the way nixos-rebuild does: as a transient systemd unit, so a
    # switch that restarts your desktop or terminal can't kill it halfway
    # through. The unit name is the one nixos-rebuild uses, so systemd refuses
    # to start this while a rebuild's switch is already running, and the
    # other way around.
    run_switch_to_configuration() {
      local top="$1" mode="$2"
      if command -v systemd-run >/dev/null 2>&1; then
        sudo systemd-run --collect --no-ask-password --pipe --quiet \
          --service-type=exec --unit=nixos-rebuild-switch-to-configuration \
          --wait "$top/bin/switch-to-configuration" "$mode"
      else
        sudo "$top/bin/switch-to-configuration" "$mode"
      fi
    }

    # Kernel and initrd store paths a toplevel's boot entries need, including
    # its specialisations -- what an installer copies into /boot for it.
    _boot_files_of() {
      local top="$1" s f
      for s in "$top" "$top"/specialisation/*; do
        for f in kernel initrd; do
          [[ -e "$s/$f" ]] && readlink -f "$s/$f"
        done
      done
      return 0
    }

    # Before a pick: what the boot menu would hold once GEN's own installer
    # rewrites it, and about how much new /boot space that takes. A pick runs
    # GEN's installer with GEN's settings, which can keep more generations
    # than your current config does. Limine (and the others) copy new
    # kernels and initrds before removing unused ones, so it all has to fit
    # in the free space at once. Read-only. Sets PICK_SPACE_SHORT=1 when the
    # estimate is more than /boot has free, and PICK_IN_MENU=0 when GEN
    # itself won't be on the rewritten menu (1 when it will, or when that
    # can't be told).
    preview_pick_boot_menu() {
      local GEN="$1" top="$2" info limit copies cur_info cur_limit="" g start
      local need=0 free=0 nfiles=0 f sz
      local -a all=() predicted=() added=() dropped=()
      local -A have=() counted=()
      PICK_SPACE_SHORT=0
      PICK_IN_MENU=1

      if ! info=$(backend_menu_limit_for "$top"); then
        echo "Couldn't tell how many generations generation $GEN's boot menu keeps,"
        echo "so there's no estimate of the /boot space this needs."
        return 0
      fi
      read -r limit copies <<<"$info"
      if cur_info=$(backend_menu_limit_for "$(readlink -f /run/current-system)"); then
        read -r cur_limit _ <<<"$cur_info"
      fi

      mapfile -t all < <(for f in /nix/var/nix/profiles/system-*-link; do _gen_of_link "$f"; done | sort -n)
      predicted=("''${all[@]}")
      if [[ "$limit" -gt 0 && ''${#all[@]} -gt "$limit" ]]; then
        start=$(( ''${#all[@]} - limit ))
        predicted=("''${all[@]:start}")
      fi

      if [[ "$limit" -eq 0 ]]; then
        echo "Generation $GEN's boot menu keeps every generation in the list."
      else
        echo "Generation $GEN's boot menu keeps the newest $limit generations."
      fi
      if [[ -n "$cur_limit" && "$cur_limit" != "$limit" ]]; then
        echo "Your running config keeps ''${cur_limit/#0/every one}, so the boot menu will change size."
      fi
      # GRUB always adds the installed generation as its own default entry;
      # Limine and systemd-boot only list the newest N, so an older pick can
      # fall off the menu entirely.
      if [[ " ''${predicted[*]} " == *" $GEN "* || "$BOOTLOADER" == grub ]]; then
        PICK_IN_MENU=1
      else
        PICK_IN_MENU=0
        echo
        echo "⚠️  Generation $GEN is older than those $limit, so it won't be on the boot"
        echo "   menu at all. You can use it until you reboot, but not boot into it."
      fi

      if [[ "$BOOT_STATE" != ok ]]; then
        echo "(Can't read the current boot menu, so no comparison or space estimate.)"
        return 0
      fi

      for g in "''${predicted[@]}"; do
        [[ -n "''${IN_BOOTLOADER[$g]:-}" ]] || added+=("$g")
      done
      for g in "''${!IN_BOOTLOADER[@]}"; do
        [[ " ''${predicted[*]} " == *" $g "* ]] || dropped+=("$g")
      done
      if [[ ''${#dropped[@]} -gt 0 ]]; then
        mapfile -t dropped < <(printf '%s\n' "''${dropped[@]}" | sort -nr)
      fi
      echo "  Added to the boot menu:     ''${added[*]:-(none)}"
      echo "  Dropped from the boot menu: ''${dropped[*]:-(none)}"

      if [[ "$copies" -eq 0 ]]; then
        echo "  It doesn't copy kernels into /boot (GRUB copyKernels = false), so no"
        echo "  new /boot space is needed."
        return 0
      fi

      for g in "''${!IN_BOOTLOADER[@]}"; do
        while read -r f; do [[ -n "$f" ]] && have[$f]=1; done \
          < <(_boot_files_of "$(readlink -f "/nix/var/nix/profiles/system-''${g}-link" 2>/dev/null)")
      done
      for g in "''${added[@]}"; do
        while read -r f; do
          [[ -n "$f" && -z "''${have[$f]:-}" && -z "''${counted[$f]:-}" ]] || continue
          counted[$f]=1
          sz=$(stat -L -c %s "$f" 2>/dev/null || echo 0)
          need=$((need + sz))
          nfiles=$((nfiles + 1))
        done < <(_boot_files_of "$(readlink -f "/nix/var/nix/profiles/system-''${g}-link" 2>/dev/null)")
      done

      free=$(df -B1 --output=avail /boot 2>/dev/null | tail -n1 | tr -d ' ') || free=""
      if [[ "$nfiles" -eq 0 ]]; then
        echo "  New files for /boot: none -- everything it needs is already there."
        return 0
      fi
      echo "  New files for /boot: about $(fmt_bytes "$need") ($nfiles kernel/initrd files)."
      if [[ "$free" =~ ^[0-9]+$ ]]; then
        echo "  /boot has $(fmt_bytes "$free") free."
        if [[ "$need" -gt "$free" ]]; then
          PICK_SPACE_SHORT=1
          echo
          echo "⚠️  That's more than /boot has free. The bootloader install would very"
          echo "   likely run out of space partway through. You could free /boot space"
          echo "   first ('g' clears orphaned files), or pick a generation built with"
          echo "   your current boot-menu settings."
        fi
      fi
      return 0
    }

    # The highest generation number in the profile. Limine's boot menu always
    # defaults to this one, whatever the profile head points at.
    newest_gen() {
      local l
      for l in /nix/var/nix/profiles/system-*-link; do _gen_of_link "$l"; done | sort -n | tail -n1
    }

    pick_generation() {
      local GEN="$1" TARGET MODE CONFIRM OLD_HEAD npins=0 NEWEST
      TARGET=$(readlink -f "/nix/var/nix/profiles/system-''${GEN}-link" 2>/dev/null || true)
      if [[ -z "$TARGET" || ! -x "$TARGET/bin/switch-to-configuration" ]]; then
        echo
        echo "Generation $GEN's system build is missing or incomplete (no" >&2
        echo "bin/switch-to-configuration), so it can't be switched to." >&2
        return 1
      fi
      if [[ "$GEN" == "$HEAD_GEN" && "$GEN" == "$RUNNING_GEN" ]]; then
        echo
        echo "Generation $GEN is already the current generation -- nothing to pick."
        return 1
      fi

      NEWEST=$(newest_gen)

      echo
      echo "Picking generation $GEN: making it your system again, the way"
      echo "'nixos-rebuild switch --rollback' does for the previous generation."
      echo
      if [[ "$BOOTLOADER" == limine ]]; then
        # Limine's installer ignores the profile head: it lists the newest N
        # generations by number and always defaults to the highest one. So
        # 'boot' can't make an older generation the next boot, and a
        # 'switch' only lasts until the next reboot.
        MODE=switch
        echo "This starts using generation $GEN now."
        if [[ "$GEN" != "$NEWEST" ]]; then
          echo
          echo "On Limine, the boot menu always defaults to the newest generation"
          echo "(generation $NEWEST here), whatever the system profile points at. So"
          echo "after a reboot you're back on generation $NEWEST, unless you choose"
          echo "generation $GEN in the boot menu. (With 'remember_last_entry: yes' in"
          echo "your Limine config, choosing it once keeps it chosen.) That's also"
          echo "how 'nixos-rebuild switch --rollback' behaves on Limine, and why"
          echo "pick has no 'boot' option here."
        fi
        echo
        echo "The boot menu is rewritten using generation $GEN's own bootloader"
        echo "settings."
      else
        echo "  switch  Start using generation $GEN now, and make it the boot menu's"
        echo "          default. A different kernel only loads after a reboot."
        echo "  boot    Leave what's running alone; boot into generation $GEN next time."
        echo
        echo "Either way, the boot menu is rewritten using generation $GEN's own"
        echo "bootloader settings."
      fi
      echo "Newer generations stay in the list (nothing is deleted), and your next"
      echo "rebuild still lands on top as a new generation."
      if backend_supports_pin && [[ -f "$OUTPUT" ]]; then
        npins=$(jq 'length' "$OUTPUT" 2>/dev/null || echo 0)
      fi
      if [[ "$npins" -gt 0 ]]; then
        echo
        echo "Pins: the boot menu gets whatever pins generation $GEN was built with."
        echo "Pins added since then stay in $OUTPUT and come back on your next rebuild."
      fi
      echo

      if [[ "$BOOTLOADER" != limine ]]; then
        prompt "Switch now or at next boot? [switch/boot, q to cancel]: " "" MODE ||
          { echo "Cancelled. Nothing changed."; return 1; }
        case "$MODE" in
          switch | boot) ;;
          *)
            echo "Expected 'switch' or 'boot' -- nothing changed." >&2
            return 1
            ;;
        esac
      fi
      # Root comes before the last confirmation, not after: comparing against
      # the current boot menu means reading it, and the space warning has to
      # be on screen before you answer.
      ensure_root "Picking a generation" || return 1
      echo
      preview_pick_boot_menu "$GEN" "$TARGET"
      echo

      if [[ "$MODE" == boot && "$PICK_IN_MENU" -eq 0 ]]; then
        echo "'boot' can't work here: generation $GEN won't be on the boot menu." >&2
        echo "Nothing changed. Pick it with 'switch' to use it until you reboot." >&2
        return 1
      fi

      local ask="Make generation $GEN your system ($MODE)? [yes/N]: "
      [[ "$PICK_SPACE_SHORT" -eq 1 ]] && ask="Make generation $GEN your system ($MODE) anyway? [yes/N]: "
      read -rp "$ask" CONFIRM
      if [[ "$CONFIRM" != "yes" ]]; then
        echo "Skipped. Nothing changed."
        return 1
      fi

      OLD_HEAD="$HEAD_GEN"
      if ! sudo nix-env -p /nix/var/nix/profiles/system --switch-generation "$GEN"; then
        echo "Couldn't point the system profile at generation $GEN -- nothing changed." >&2
        return 1
      fi
      HEAD_GEN="$GEN"
      echo "Profile now points at generation $GEN. Running its switch-to-configuration $MODE..."
      echo

      if run_switch_to_configuration "$TARGET" "$MODE"; then
        echo
        if [[ "$MODE" == switch && "$PICK_IN_MENU" -eq 0 ]]; then
          echo "Done. You're on generation $GEN now. It isn't on the boot menu, so a"
          echo "reboot takes you to generation $NEWEST."
        elif [[ "$MODE" == switch && "$BOOTLOADER" == limine && "$GEN" != "$NEWEST" ]]; then
          echo "Done. You're on generation $GEN now. The boot menu still defaults to"
          echo "generation $NEWEST; choose $GEN there if you want to boot back into it."
        elif [[ "$MODE" == switch ]]; then
          echo "Done. You're on generation $GEN now, and it's the boot menu's default."
        else
          echo "Done. Generation $GEN is the boot menu's default -- reboot to use it."
        fi
        return 0
      fi

      echo
      echo "switch-to-configuration $MODE failed (see above). The system profile" >&2
      echo "already points at generation $GEN, so the next rebuild or boot-menu" >&2
      echo "rewrite treats it as current." >&2
      if [[ -n "$OLD_HEAD" && "$OLD_HEAD" != "$GEN" ]]; then
        read -rp "Point the profile back at generation $OLD_HEAD? [yes/N]: " CONFIRM
        if [[ "$CONFIRM" == "yes" ]]; then
          if sudo nix-env -p /nix/var/nix/profiles/system --switch-generation "$OLD_HEAD"; then
            HEAD_GEN="$OLD_HEAD"
            echo "Profile is back on generation $OLD_HEAD."
            [[ "$MODE" == switch ]] &&
              echo "If the switch got partway, pick generation $OLD_HEAD with 'switch' to finish undoing it."
          fi
        fi
      fi
      return 1
    }

    # --- Config snapshots ('c') --------------------------------------------------
    # A generation can carry two opt-in records of the config that built it,
    # both set in the user's own NixOS config (see the README):
    #   - system.configurationRevision: the commit, read back with that
    #     generation's own 'nixos-version --configuration-revision';
    #   - environment.etc."$CONFIG_SOURCE".source = self: a read-only copy of
    #     the flake's git-tracked files, at <toplevel>/etc/$CONFIG_SOURCE.
    # Everything here only reads them. The one write is 'copy', which copies
    # into a folder the user types in and never replaces a file that's
    # already there.
    ALL_FILES="[all files]"
    declare -A REV_CACHE=()

    # Short commit a toplevel was built from ("5d44a72", or "5d44a72*" if the
    # tree had uncommitted changes), or "-" if it didn't record one. Cached by
    # toplevel, which is immutable -- call cache_revision outside a $(...) so
    # the cache survives; gen_revision is the print-it form for one-offs.
    cache_revision() {
      local top="$1" rev="" dirty=""
      if [[ -z "''${REV_CACHE[$top]:-}" ]]; then
        if [[ -x "$top/sw/bin/nixos-version" ]]; then
          rev=$("$top/sw/bin/nixos-version" --configuration-revision 2>/dev/null) || rev=""
        fi
        if [[ "$rev" == *-dirty ]]; then
          rev="''${rev%-dirty}"
          dirty="*"
        fi
        if [[ -z "$rev" ]]; then
          REV_CACHE[$top]="-"
        else
          REV_CACHE[$top]="''${rev:0:7}$dirty"
        fi
      fi
    }

    gen_revision() {
      cache_revision "$1"
      printf '%s' "''${REV_CACHE[$1]}"
    }

    # Full commit, or nothing for dirty/missing ones -- used for the git hint.
    gen_full_revision() {
      local rev=""
      [[ -x "$1/sw/bin/nixos-version" ]] &&
        rev=$("$1/sw/bin/nixos-version" --configuration-revision 2>/dev/null) || true
      [[ -n "$rev" && "$rev" != *-dirty && "$rev" != unknown ]] && printf '%s' "$rev"
      return 0
    }

    # Toplevel store path behind a list row: a generation number, or a
    # "pin:NAME" row. A pin's init script is a file inside its generation's
    # toplevel, so the pin keeps that toplevel -- and its snapshot -- alive
    # even after the generation itself is pruned.
    row_toplevel() {
      local id="$1" init top
      if [[ "$id" == pin:* ]]; then
        init=$(jq -r --arg name "''${id#pin:}" '.[] | select(.name == $name) | .init' "$OUTPUT" 2>/dev/null) || return 1
        [[ -n "$init" ]] || return 1
        top=$(dirname "$init")
      else
        top=$(readlink -f "/nix/var/nix/profiles/system-''${id}-link" 2>/dev/null) || return 1
      fi
      [[ -e "$top/nixos-version" ]] || return 1
      printf '%s' "$top"
    }

    row_label() {
      if [[ "$1" == pin:* ]]; then
        printf 'pin %s' "''${1#pin:}"
      else
        printf 'generation %s' "$1"
      fi
    }

    no_snapshot_msg() {
      echo
      echo "$1 has no config snapshot (nothing at <its system>/etc/$CONFIG_SOURCE)." >&2
      echo "Only generations built after adding these two lines to your NixOS" >&2
      echo "config have one (self is your flake's own 'self' input):" >&2
      echo >&2
      echo '    system.configurationRevision = self.rev or self.dirtyRev or "unknown";' >&2
      echo "    environment.etc.\"$CONFIG_SOURCE\".source = self;" >&2
      echo >&2
      echo "Use --config-source NAME if yours is under a different /etc name." >&2
    }

    # The config folder you edit and rebuild from: --config-dir, else the
    # folder part of NH_OS_FLAKE / NH_FLAKE. Prints nothing (status 1) if
    # neither names an existing folder.
    working_config_dir() {
      local f
      if [[ -n "$CONFIG_DIR" ]]; then
        f="$CONFIG_DIR"
      else
        f="''${NH_OS_FLAKE:-''${NH_FLAKE:-}}"
        f="''${f%%#*}"
        f="''${f#path:}"
        f="''${f#git+file://}"
      fi
      [[ -n "$f" && -d "$f" ]] || return 1
      readlink -f "$f"
    }

    # Pages a recursive diff of two files or folders. --no-dereference so a
    # 'result' link in a working copy is compared as a link, not walked into
    # its whole system closure. Files that exist on only one side show as
    # "Only in ..." -- in a working copy those may just be untracked.
    show_diff() {
      local a="$1" b="$2" title="$3"
      if [[ ! -e "$a" || ! -e "$b" ]]; then
        echo
        [[ -e "$a" ]] || echo "Not in the first one: $a"
        [[ -e "$b" ]] || echo "Not in the second one: $b"
        return 0
      fi
      a=$(readlink -f "$a")
      b=$(readlink -f "$b")
      if diff -rq --no-dereference -x .git "$a" "$b" >/dev/null 2>&1; then
        echo
        echo "$title"
        echo "No differences."
        return 0
      fi
      {
        printf '%s\n' "$title"
        printf -- '--- %s\n+++ %s\n\n' "$a" "$b"
        diff -ru --no-dereference -x .git --color=always "$a" "$b" || true
      } | less -R || true
      # Returning straight to fzf would hide where you were; nothing to pause on.
      PAUSE_AFTER_CONFIG=0
    }

    # Copies FILE(s) (relative to SRC), or the whole snapshot, into a folder
    # you type in. Copies are made writable. Never replaces an existing file.
    copy_from_snapshot() {
      local src="$1" default_dest="$2"
      shift 2
      local dest f n=0 skipped=0
      prompt "Copy to folder (press enter for: $default_dest) [q to cancel]: " "$default_dest" dest ||
        { echo "Cancelled. Nothing was copied."; return 1; }
      dest="''${dest/#\~/$HOME}"

      if [[ "$1" == "$ALL_FILES" ]]; then
        if [[ -e "$dest" ]]; then
          echo "$dest already exists -- refusing to copy the whole snapshot into it." >&2
          echo "Pick a folder that doesn't exist yet." >&2
          return 1
        fi
        mkdir -p "$dest"
        cp -r --no-preserve=mode,ownership "$src/." "$dest"
        chmod -R u+w "$dest"
        echo "Copied the whole snapshot to $dest."
        return 0
      fi

      for f in "$@"; do
        if [[ -e "$dest/$f" || -L "$dest/$f" ]]; then
          echo "Skipped $f: $dest/$f already exists." >&2
          skipped=$((skipped + 1))
          continue
        fi
        mkdir -p "$(dirname "$dest/$f")"
        cp -P --no-preserve=mode,ownership "$src/$f" "$dest/$f"
        [[ -L "$dest/$f" ]] || chmod u+w "$dest/$f"
        n=$((n + 1))
      done
      if [[ "$skipped" -gt 0 ]]; then
        echo "Copied $n file(s) to $dest ($skipped skipped)."
      else
        echo "Copied $n file(s) to $dest."
      fi
    }

    # 'c' on one row: browse that generation's snapshot. Enter views,
    # Ctrl-D diffs against the running generation's snapshot, Ctrl-W against
    # your working config folder, Ctrl-S copies out. The "[all files]" row
    # makes any of those apply to the whole snapshot.
    browse_config() {
      local id="$1" top src label rev running running_src wd summary raw key
      local -a picked
      label=$(row_label "$id")
      if ! top=$(row_toplevel "$id"); then
        echo
        echo "Can't find the system build for $label -- it may have been garbage-collected." >&2
        return 1
      fi
      src="$top/etc/$CONFIG_SOURCE"
      if [[ ! -d "$src" ]]; then
        no_snapshot_msg "''${label^}"
        return 1
      fi
      src=$(readlink -f "$src")
      rev=$(gen_revision "$top")
      running=$(readlink -f /run/current-system 2>/dev/null || true)
      running_src="$running/etc/$CONFIG_SOURCE"
      wd=$(working_config_dir) || wd=""

      summary="$YIELD_DIR/config-summary"
      {
        echo "Config snapshot of $label"
        echo
        if [[ "$rev" == "-" ]]; then
          echo "  commit:   none recorded (system.configurationRevision not set)"
        else
          echo "  commit:   $rev"
        fi
        echo "  snapshot: $src"
        echo "  files:    $(find "$src" -type f -o -type l | wc -l)"
        echo
        echo "Pick this row to view, diff, or copy the whole snapshot."
        echo "A '*' after the commit means it was built with uncommitted changes;"
        echo "the snapshot still holds exactly the files it was built from."
      } >"$summary"

      PAUSE_AFTER_CONFIG=1
      while true; do
        raw=$(
          cd "$src" && {
            printf '%s\n' "$ALL_FILES"
            find . \( -type f -o -type l \) -printf '%P\n' | sort
          } | SHELL="$(command -v bash)" fzf --style full \
            --layout reverse \
            --header "Config of $label -- commit $rev"$'\n'"Working copy: ''${wd:-(none found -- pass --config-dir)}" \
            --border-label " 🌱 Config: $label " \
            "''${FZF_THEME_ARGS[@]}" \
            --footer "  Esc:back   Enter:view   Ctrl-S:copy   Tab:mark"$'\n'"  Ctrl-D:diff vs running   Ctrl-W:diff vs working" \
            --multi \
            --preview "if [ {} = '$ALL_FILES' ]; then cat '$summary'; else cat -- {}; fi" \
            --preview-window 'right,60%,wrap' \
            --expect=ctrl-d,ctrl-w,ctrl-s
        ) || return 0

        key=$(head -n1 <<<"$raw")
        mapfile -t picked < <(tail -n +2 <<<"$raw")
        [[ ''${#picked[@]} -gt 0 ]] || continue
        # "[all files]" anywhere in the selection means the whole snapshot.
        local p
        for p in "''${picked[@]}"; do
          [[ "$p" == "$ALL_FILES" ]] && picked=("$ALL_FILES") && break
        done

        case "$key" in
          ctrl-d)
            if [[ "$top" == "$running" ]]; then
              echo
              echo "$label is the running generation -- nothing to compare against."
              pause_after_action
            elif [[ ! -d "$running_src" ]]; then
              no_snapshot_msg "The running generation"
              pause_after_action
            else
              for p in "''${picked[@]}"; do
                [[ "$p" == "$ALL_FILES" ]] && p=""
                show_diff "$src/$p" "$running_src/$p" \
                  "Config diff: $label ($rev) -> running generation ($(gen_revision "$running"))''${p:+ -- $p}"
              done
              [[ "$PAUSE_AFTER_CONFIG" -eq 1 ]] && pause_after_action
            fi
            ;;
          ctrl-w)
            if [[ -z "$wd" ]]; then
              echo
              echo "No working config folder found. Pass --config-dir DIR, or set" >&2
              echo "NH_OS_FLAKE / NH_FLAKE to it." >&2
              pause_after_action
            else
              for p in "''${picked[@]}"; do
                [[ "$p" == "$ALL_FILES" ]] && p=""
                show_diff "$src/$p" "$wd/$p" \
                  "Config diff: $label ($rev) -> working copy $wd''${p:+ -- $p}"
              done
              [[ "$PAUSE_AFTER_CONFIG" -eq 1 ]] && pause_after_action
            fi
            ;;
          ctrl-s)
            echo
            # Default to $HOME, not $PWD: the tool is usually run from the
            # config repo (for the pins file), and a copy there would land
            # inside the repo.
            copy_from_snapshot "$src" "$HOME/config-''${label// /-}" "''${picked[@]}" || true
            pause_after_action
            ;;
          *)
            if [[ "''${picked[0]}" == "$ALL_FILES" ]]; then
              less -- "$summary" || true
            else
              less -- "''${picked[@]/#/$src/}" || true
            fi
            ;;
        esac
        PAUSE_AFTER_CONFIG=1
      done
    }

    # 'c' on two rows: diff their whole snapshots, older one first.
    diff_two_configs() {
      local a="$1" b="$2" top_a top_b la lb ra rb fa fb
      if [[ "$a" != pin:* && "$b" != pin:* && "$a" -gt "$b" ]]; then
        local t="$a"; a="$b"; b="$t"
      fi
      la=$(row_label "$a")
      lb=$(row_label "$b")
      top_a=$(row_toplevel "$a") || { echo; echo "Can't find the system build for $la." >&2; return 1; }
      top_b=$(row_toplevel "$b") || { echo; echo "Can't find the system build for $lb." >&2; return 1; }
      [[ -d "$top_a/etc/$CONFIG_SOURCE" ]] || { no_snapshot_msg "''${la^}"; return 1; }
      [[ -d "$top_b/etc/$CONFIG_SOURCE" ]] || { no_snapshot_msg "''${lb^}"; return 1; }
      ra=$(gen_revision "$top_a")
      rb=$(gen_revision "$top_b")
      PAUSE_AFTER_CONFIG=1
      show_diff "$top_a/etc/$CONFIG_SOURCE" "$top_b/etc/$CONFIG_SOURCE" \
        "Config diff: $la ($ra) -> $lb ($rb)"
      fa=$(gen_full_revision "$top_a")
      fb=$(gen_full_revision "$top_b")
      if [[ -n "$fa" && -n "$fb" && "$fa" != "$fb" ]]; then
        echo
        echo "Both were built from clean commits, so git has the same diff:"
        echo "    git diff ''${fa:0:12} ''${fb:0:12}"
      fi
      if [[ "$PAUSE_AFTER_CONFIG" -eq 1 || ( -n "$fa" && -n "$fb" ) ]]; then
        pause_after_action
      fi
      return 0
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

      for link in "''${LINKS[@]}"; do
        gen=$(basename "$link" | sed -E 's/system-([0-9]+)-link/\1/')
        top=$(readlink -f "$link" 2>/dev/null) || continue
        [[ -e "$top" ]] || continue
        gen_list+=("$gen")
        top_list+=("$top")
        base=$(basename "$top")
        [[ -s "$YIELD_DIR/c-$base" ]] || missing+=("$top")
      done
      [[ ''${#gen_list[@]} -gt 0 ]] || return 1

      # 1) Closures not cached yet this session, in parallel. Generations
      #    sharing one toplevel are only queried once.
      if [[ ''${#missing[@]} -gt 0 ]]; then
        echo "Measuring YIELD for ''${#missing[@]} generation(s) (only new ones are measured on later redraws)..." >&2
        printf '%s\n' "''${missing[@]}" | sort -u |
          xargs -r -P "$(nproc 2>/dev/null || echo 4)" -I{} sh -c \
            'b=$(basename "$1"); nix-store -qR "$1" >"$2/c-$b.tmp" 2>/dev/null && mv "$2/c-$b.tmp" "$2/c-$b"' \
            _ {} "$YIELD_DIR" || true
      fi

      : >"$owners"
      local i
      for i in "''${!gen_list[@]}"; do
        base=$(basename "''${top_list[$i]}")
        # A generation whose closure couldn't be read would make everything it
        # shares with others look unique to them -- refuse rather than guess.
        [[ -s "$YIELD_DIR/c-$base" ]] || return 1
        awk -v g="''${gen_list[$i]}" '{ print g " " $0 }' "$YIELD_DIR/c-$base" >>"$owners"
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

      for gen in "''${gen_list[@]}"; do YIELD["$gen"]=0; done
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
    FIRST_DRAW=1
    while true; do
      # Redraws re-read the boot menu and re-measure YIELD, which takes a few
      # seconds with nothing else on screen -- say so, or it looks frozen.
      if [[ "$FIRST_DRAW" -eq 0 && -t 1 ]]; then
        echo
        echo "Refreshing the list..."
      fi
      FIRST_DRAW=0

      # Booted vs. running vs. profile-head generation -- see
      # resolve_running_generations in boot-backend.sh. They're normally the
      # same number, but after a rebuild dies with ENOSPC on a full /boot, the
      # profile head points at a generation that never reached the boot menu
      # while the machine is still running the older one it booted. Marking the
      # head "(current)" there was wrong, and made rescue/harvest refuse to run.
      resolve_running_generations

      read_boot_menu

      # Surface a failed read loudly, and PAUSE for it -- same reasoning as
      # pause_after_action (see its comment above): a message printed right
      # before fzf redraws the full-screen list gets wiped before there's any
      # real chance to read it. A boot menu that simply hasn't been read yet
      # (no sudo given this session) isn't a failure -- the header says so
      # quietly instead.
      if [[ "$BOOT_STATE" == failed ]]; then
        echo
        echo "⚠️  Could not read the boot menu -- see the 'Note:' above for why" >&2
        echo "   (usually a permissions problem reading under /boot). The BOOT" >&2
        echo "   column you're about to see is NOT a confirmed-empty boot menu" >&2
        echo "   -- it's an UNREADABLE one. Until this is fixed, 'p' (prune)" >&2
        echo "   and 'h' (harvest) refuse every generation, since neither can" >&2
        echo "   tell which ones are really on the boot menu." >&2
        pause_after_action
      fi

      shopt -s nullglob
      LINKS=(/nix/var/nix/profiles/system-*-link)
      shopt -u nullglob

      if [[ ''${#LINKS[@]} -eq 0 ]]; then
        echo "No generations found under /nix/var/nix/profiles/. Are you on NixOS?" >&2
        exit 1
      fi

      YIELD_OK=0
      if [[ "$YIELD_ENABLED" -eq 1 ]]; then
        compute_yields && YIELD_OK=1
      fi

      ROWS=()
      for link in "''${LINKS[@]}"; do
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
          [[ -n "$kernel_dir" ]] && kernel_ver="''${kernel_dir#*-linux-}"
        fi

        marker=""
        if [[ -n "$BOOTED_GEN" && "$gen" == "$BOOTED_GEN" ]]; then
          marker=" (booted)"
        elif [[ -n "$RUNNING_GEN" && "$gen" == "$RUNNING_GEN" ]]; then
          marker=" (running)"
        fi

        boot_marker="-"
        if [[ "$BOOT_STATE" == locked ]]; then
          boot_marker="?"
        elif [[ -n "''${IN_BOOTLOADER[$gen]:-}" ]]; then
          boot_marker="✓"
        fi

        yield_str="?"
        [[ "$YIELD_OK" -eq 1 && -n "''${YIELD[$gen]:-}" ]] && yield_str=$(fmt_bytes "''${YIELD[$gen]}")

        cache_revision "$target"
        rev_str="''${REV_CACHE[$target]}"

        ROWS+=("''${gen}"$'\t'"''${boot_marker}"$'\t'"''${yield_str}"$'\t'"''${gen_date}"$'\t'"''${rev_str}"$'\t'"''${nixos_ver}"$'\t'"''${kernel_ver}''${marker}")
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
          # A pin's toplevel survives its generation, so its commit does too.
          prev_str="-"
          if ptop=$(row_toplevel "pin:''${pname}"); then
            cache_revision "$ptop"
            prev_str="''${REV_CACHE[$ptop]}"
          fi
          PIN_ROWS+=("pin:''${pname}"$'\t'''📌'$'\t'''-'$'\t'"''${pdate}"$'\t'"''${prev_str}"$'\t'''-'$'\t'"pinned: ''${pname}")
        done < <(jq -r '.[] | "\(.name)\t\(.title)"' "$OUTPUT")
      fi

      BODY=$(
        {
          printf '%s\n' "''${ROWS[@]}"
          if [[ ''${#PIN_ROWS[@]} -gt 0 ]]; then
            printf '%s\n' "''${PIN_ROWS[@]}"
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
        [[ -n "$boot_used" ]] && BOOT_USAGE="/boot: ''${boot_used} used, ''${boot_avail} free (''${boot_pcent} full)"
      fi

      BOOT_COUNT_STR="$BOOT_COUNT"
      [[ "$BOOT_STATE" == locked ]] && BOOT_COUNT_STR="?"
      HEADER_TEXT="NixOS Generations (''${#ROWS[@]} total, ''${BOOT_COUNT_STR} in bootloader, ''${#PIN_ROWS[@]} pinned -- $BOOTLOADER)"
      [[ -n "$BOOT_USAGE" ]] && HEADER_TEXT="''${HEADER_TEXT}"$'\n'"''${BOOT_USAGE}"
      case "$BOOT_STATE" in
        locked)
          HEADER_TEXT="''${HEADER_TEXT}"$'\n'"BOOT column not read yet (the boot menu is root-only) -- press b to read it with sudo"
          ;;
        stale)
          HEADER_TEXT="''${HEADER_TEXT}"$'\n'"BOOT column as of ''${BOOT_LAST_READ_AT} (sudo has timed out) -- press b to re-read it"
          ;;
      esac
      if [[ "$YIELD_ENABLED" -eq 1 && "$YIELD_OK" -eq 0 ]]; then
        HEADER_TEXT="''${HEADER_TEXT}"$'\n'"YIELD unavailable (couldn't read store closures) -- column shows '?'"
      fi
      if [[ -n "$HEAD_GEN" && -n "$BOOTED_GEN" && "$HEAD_GEN" != "$BOOTED_GEN" ]]; then
        if [[ -z "''${IN_BOOTLOADER[$HEAD_GEN]:-}" && "$BOOT_STATE" == ok ]]; then
          HEADER_TEXT="''${HEADER_TEXT}"$'\n'"Profile head is gen ''${HEAD_GEN}, but it never made it onto the boot menu -- you booted gen ''${BOOTED_GEN}"
        elif [[ "$BOOTLOADER" == limine ]]; then
          # Limine defaults to the newest generation, not the profile head.
          HEADER_TEXT="''${HEADER_TEXT}"$'\n'"Profile head is gen ''${HEAD_GEN} -- you booted gen ''${BOOTED_GEN} (Limine boots gen $(newest_gen) by default)"
        else
          HEADER_TEXT="''${HEADER_TEXT}"$'\n'"Profile head is gen ''${HEAD_GEN} (next boot's default) -- you booted gen ''${BOOTED_GEN}"
        fi
      fi
      ENTER_LABEL="Enter:pin/unpin"
      backend_supports_pin || ENTER_LABEL="Enter:pin(Limine only)"
      FOOTER_TEXT="  q/Esc:quit   ''${ENTER_LABEL}   Tab:multi-select   r:pick   p:prune   h:harvest   c:config   g:gc   ?:help  "
      FOOTER_TEXT+=$'\n'"  b:read boot menu (sudo)   ↑↓:move   Type to filter  "

      RAW=$(
        {
          printf 'GEN\tBOOT\tYIELD\tBUILT\tREV\tNIXOS VERSION\tKERNEL\n'
          printf '%s\n' "$BODY"
        } | column -t -s $'\t' -R 3 |
          fzf --style full \
            --layout reverse \
            --header-first \
            --header-lines=1 \
            --header "$HEADER_TEXT" \
            --border-label ' 🌱 Gardener ' \
            "''${FZF_THEME_ARGS[@]}" \
            --footer "$FOOTER_TEXT" \
            --multi \
            --bind 'q:abort' \
            --bind '?:toggle-preview' \
            --preview "cat '$HELP_FILE'" \
            --preview-window '~3,down,70%:hidden:wrap' \
            --expect=p,g,h,c,r,b
      ) || true

      KEY=$(head -n1 <<<"$RAW")
      SELECTED=$(tail -n +2 <<<"$RAW")

      if [[ "$KEY" == "b" ]]; then
        # Fill in the BOOT column. Nothing else -- the redraw shows the result.
        if [[ "$BOOT_STATE" == ok ]]; then
          continue
        fi
        ensure_root "Reading the boot menu" || pause_after_action
        continue
      fi

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

      if [[ "$KEY" == "r" ]]; then
        if [[ ''${#SELECTED_GENS[@]} -gt 1 ]]; then
          echo
          echo "Pick goes back to one generation -- you selected ''${#SELECTED_GENS[@]}." >&2
        elif [[ "''${SELECTED_GENS[0]}" == pin:* ]]; then
          echo
          echo "''\'''${SELECTED_GENS[0]#pin:}' is a pin, not a generation. Pins are only for booting" >&2
          echo "from the boot menu; pick the generation row it came from instead." >&2
        else
          # '|| true': see the note above prune_generation's call below.
          pick_generation "''${SELECTED_GENS[0]}" || true
        fi
        pause_after_action
        continue
      fi

      if [[ "$KEY" == "p" ]]; then
        # Ask for sudo once, before the first generation, so every check
        # below sees the boot menu as it really is.
        if ! ensure_root "Pruning"; then
          pause_after_action
          continue
        fi
        for GEN in "''${SELECTED_GENS[@]}"; do
          if [[ "$GEN" == pin:* ]]; then
            echo
            echo "''\'''${GEN#pin:}' is a pin, not a generation -- pins aren't pruned." >&2
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

      if [[ "$KEY" == "c" ]]; then
        # One row: browse its config snapshot. Two: diff them. Both pause on
        # their own when there's something left on screen to read.
        case ''${#SELECTED_GENS[@]} in
          1) browse_config "''${SELECTED_GENS[0]}" || pause_after_action ;;
          2) diff_two_configs "''${SELECTED_GENS[0]}" "''${SELECTED_GENS[1]}" || pause_after_action ;;
          *)
            echo
            echo "'c' takes one row (browse its config) or two (diff them) --" >&2
            echo "you selected ''${#SELECTED_GENS[@]}." >&2
            pause_after_action
            ;;
        esac
        continue
      fi

      if [[ "$KEY" == "h" ]]; then
        if ! ensure_root "Harvesting"; then
          pause_after_action
          continue
        fi
        for GEN in "''${SELECTED_GENS[@]}"; do
          if [[ "$GEN" == pin:* ]]; then
            echo
            echo "''\'''${GEN#pin:}' is a pin, not a generation -- pins aren't harvested." >&2
            echo "Select it alone and press Enter to unpin it instead." >&2
            pause_after_action
            continue
          fi
          if [[ "$BOOT_STATE" != ok ]]; then
            echo
            echo "Can't read the boot menu, so there's no telling whether generation" >&2
            echo "$GEN is on it -- refusing to harvest it." >&2
            pause_after_action
            continue
          fi
          if [[ -z "''${IN_BOOTLOADER[$GEN]:-}" ]]; then
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
      if [[ ''${#SELECTED_GENS[@]} -gt 1 ]]; then
        echo
        echo "Pin/unpin only supports one row at a time -- you selected ''${#SELECTED_GENS[@]}." >&2
        echo "Tab-select multiple generations for prune ('p') or harvest ('h') instead." >&2
        echo
        pause_after_action
        continue
      fi
      GEN="''${SELECTED_GENS[0]}"

      if [[ "$GEN" == pin:* ]]; then
        unpin_generation "''${GEN#pin:}" || true
        pause_after_action
        continue
      fi

      LINK="/nix/var/nix/profiles/system-''${GEN}-link"
      TARGET=$(readlink -f "$LINK")
      echo "Selected generation $GEN -> $TARGET"
      # '|| true': pin_generation returns 1 on 'q' at any prompt (cancel, back
      # to the picker). Called bare like this under `set -e`, a non-zero
      # return would otherwise kill the whole script instead of just this
      # attempt -- see the same note above harvest_generation's call.
      pin_generation "$GEN" "$LINK" "$TARGET" || true
      pause_after_action
    done
  '';

  # --- libexec/boot-gardener/rescue.sh: full-/boot rescue tool ---------------
  rescueSh = writeText "rescue.sh" ''
    #!/usr/bin/env bash
    # rescue — diagnostic + rescue tool for a 100%-full /boot on a
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

    MIN_KEPT=2 # never go below this many kept generations (booted included)

    EVICT_GEN=""
    APPLY=0
    BOOTLOADER_OVERRIDE=""

    SELF="$(readlink -f "''${BASH_SOURCE[0]}")"
    # shellcheck source=./boot-backend.sh
    source "$(dirname "$SELF")/boot-backend.sh"

    usage() {
      cat <<'EOF'
    boot-gardener rescue — diagnostic + rescue tool for a full /boot partition

    Usage:
      boot-gardener rescue               Report orphaned files (referenced by no
                                         current boot-menu entry)
      boot-gardener rescue --evict N     Also preview evicting generation N's
                                         boot-menu entry, and what additional
                                         files that would orphan
      boot-gardener rescue --apply       Actually delete Phase 1 orphaned files
                                         (requires typed confirmation)
      boot-gardener rescue --evict N --apply
                                         Actually evict generation N's boot-menu
                                         entry and delete its now-orphaned files
                                         (requires typed confirmation)
      boot-gardener rescue --bootloader limine|systemd-boot|grub
                                         Skip auto-detection and use this backend
      boot-gardener rescue --help        Show this help

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
          EVICT_GEN="''${2:-}"
          shift 2
          ;;
        --apply)
          APPLY=1
          shift
          ;;
        --bootloader)
          BOOTLOADER_OVERRIDE="''${2:-}"
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

    if [[ ''${#PROFILE_LINKS[@]} -eq 0 ]]; then
      echo "Error: no /nix/var/nix/profiles/system-*-link entries exist at all." >&2
      echo "Refusing to preview any eviction -- there's nothing to prune yet." >&2
      exit 1
    fi

    # Which generations must never be evicted: the one actually booted, the one
    # activated right now, and the profile head. See resolve_running_generations
    # in boot-backend.sh for why these are three separate things -- in short,
    # a `nixos-rebuild boot` that dies with ENOSPC on a full /boot has already
    # advanced the profile head to a generation that never reached the boot
    # menu, while the machine is still running an older one. The previous
    # "profile head == booted" assumption made this script refuse outright in
    # exactly that situation, the one it exists for.
    resolve_running_generations

    if [[ -z "$BOOTED_GEN" ]]; then
      # The running system doesn't match any profile generation at all. That
      # almost always means it was activated with `nixos-rebuild test` /
      # `switch-to-configuration test` (which skips creating a generation), or
      # the generation it was booted from has since been deleted.
      echo "Error: could not determine the currently-booted generation number." >&2
      echo "/run/current-system -> $CURRENT_SYSTEM" >&2
      [[ -e /run/booted-system ]] && echo "/run/booted-system  -> $(readlink -f /run/booted-system)" >&2
      echo "...and no /nix/var/nix/profiles/system-*-link resolves to that store path." >&2
      echo >&2
      echo "This usually means the running system was activated with 'nixos-rebuild test'" >&2
      echo "(or 'switch-to-configuration test'), which skips creating a profile generation," >&2
      echo "or the generation it was booted from has since been deleted." >&2
      echo >&2
      echo "Refusing to preview any eviction -- can't guarantee the running system" >&2
      echo "would be protected." >&2
      exit 1
    fi

    echo "Booted generation: $BOOTED_GEN"
    [[ -n "$RUNNING_GEN" && "$RUNNING_GEN" != "$BOOTED_GEN" ]] && echo "Running (activated since boot): $RUNNING_GEN"
    if [[ -n "$HEAD_GEN" && "$HEAD_GEN" != "$BOOTED_GEN" ]]; then
      echo "Profile head: $HEAD_GEN (not the booted generation -- typically a rebuild that"
      echo "  failed to install its boot entry, e.g. because /boot was full)"
    fi
    echo

    if is_protected_gen "$EVICT_GEN"; then
      if [[ "$EVICT_GEN" == "$BOOTED_GEN" ]]; then
        echo "Refusing to preview evicting generation $EVICT_GEN -- it is the currently booted generation." >&2
      elif [[ "$EVICT_GEN" == "$RUNNING_GEN" ]]; then
        echo "Refusing to preview evicting generation $EVICT_GEN -- it is the currently running (activated) generation." >&2
      elif [[ "$EVICT_GEN" != "$HEAD_GEN" ]]; then
        echo "Refusing to preview evicting generation $EVICT_GEN -- it's the exact same system as the" >&2
        echo "booted/running generation (identical store path), so its boot entry may be the one" >&2
        echo "you actually booted from. It'll be safe to harvest after you've booted something else." >&2
      else
        echo "Refusing to preview evicting generation $EVICT_GEN -- it is the system profile's head" >&2
        echo "(the generation nixos-rebuild considers current), and nix-env can't delete that." >&2
        echo "Roll the profile back first if you really want it gone:" >&2
        echo "  sudo nix-env -p /nix/var/nix/profiles/system --switch-generation $BOOTED_GEN" >&2
      fi
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
    # Green-yellow highlight for the apply summary's delete step and the
    # generation-number prompt. Off for NO_COLOR or when the output isn't a
    # terminal.
    APPLY_HIGHLIGHT="" APPLY_RESET=""
    if [[ -z "''${NO_COLOR:-}" && -t 1 ]]; then
      APPLY_HIGHLIGHT=$'\033[38;2;173;255;47m'
      APPLY_RESET=$'\033[0m'
    fi

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
    echo "  $STEP. ''${APPLY_HIGHLIGHT}Delete the $NEWLY_ORPHANED_COUNT newly-orphaned file(s) above (recover $((NEWLY_ORPHANED_BYTES / 1024 / 1024)) MiB)''${APPLY_RESET}"
    STEP=$((STEP + 1))
    echo "  $STEP. Run: nix-env --delete-generations $EVICT_GEN --profile /nix/var/nix/profiles/system"
    echo
    echo "Generation $EVICT_GEN's boot menu entry cannot be recovered after this except from the backup."
    confirm_exact "''${APPLY_HIGHLIGHT}Type the generation number ($EVICT_GEN) to confirm, or 'q' to cancel:''${APPLY_RESET} " "$EVICT_GEN"
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
    for pgen in $PROTECTED_GENS; do
      # Only a protected generation that was on the boot menu to begin with has
      # to still be there -- e.g. a profile head whose own boot-entry install is
      # what hit ENOSPC was never on it.
      if grep -qxF "$pgen" <<<"$KEPT_GENS" && ! grep -qxF "$pgen" <<<"$NEW_KEPT_GENS"; then
        echo "Validation failed: protected generation $pgen missing from the edited file." >&2
        VALIDATION_FAILED=1
      fi
    done
    grep -qxF "$EVICT_GEN" <<<"$NEW_KEPT_GENS" && { echo "Validation failed: generation $EVICT_GEN still present after removal." >&2; VALIDATION_FAILED=1; }

    if [[ "$VALIDATION_FAILED" -eq 1 ]]; then
      echo "Refusing to write $BOOT_CONF_DISPLAY -- validation failed. Nothing was changed." >&2
      exit 1
    fi
    echo "Validation passed ($NEW_KEPT_COUNT kept generations remain, booted generation $BOOTED_GEN intact)."
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
  '';

  # --- libexec/boot-gardener/boot-backend.sh: bootloader abstraction --------
  # (sourced by gardener.sh and rescue.sh, never executed directly)
  bootBackendSh = writeText "boot-backend.sh" ''
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
    #   backend_boot_menu_readable
    #       Returns 0 if the boot-menu config can be read right now without a
    #       sudo password prompt. The picker checks this before every
    #       lenient read, so just opening the list never asks for a password.
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

    # --- Generic Root-Read Helpers ----------------------------------------------

    # Every sudo call in the read helpers below goes through here. rescue.sh
    # leaves _BG_SUDO_NONINTERACTIVE unset, so sudo prompts for a password as
    # usual. The interactive list sets it to 1: there, just browsing must
    # never ask for a password, so sudo only runs if it can without one
    # (NOPASSWD, or a still-fresh sudo timestamp). The list asks for the
    # password itself, up front, only when an action actually needs root --
    # see ensure_root in gardener.sh.
    _bg_sudo() {
      if [[ "''${_BG_SUDO_NONINTERACTIVE:-0}" == 1 ]]; then
        sudo -n "$@"
      else
        sudo "$@"
      fi
    }

    # 0 if sudo works right now without asking for a password.
    _bg_sudo_ready() {
      command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null
    }

    read_root_file() {
      # Strict: exits the script if the file can't be read at all.
      local path="$1"
      if [[ -r "$path" ]]; then
        cat "$path"
      elif command -v sudo >/dev/null 2>&1; then
        # Parent directories here (e.g. /boot, /boot/limine) are often not
        # traversable by a non-root user, so -r/-e on the file itself can't be
        # trusted -- just attempt sudo directly rather than gating on a test.
        _bg_sudo cat "$path"
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
        if content=$(_bg_sudo cat "$path" 2>&1); then
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
      local path="$1" pattern="''${2:-*}"
      if [[ -r "$path" ]]; then
        find "$path" -maxdepth 1 -type f -name "$pattern" -printf '%f\t%s\n'
      elif command -v sudo >/dev/null 2>&1; then
        _bg_sudo find "$path" -maxdepth 1 -type f -name "$pattern" -printf '%f\t%s\n'
      else
        echo "Error: cannot list '$path' (not readable, and no sudo available)." >&2
        exit 1
      fi
    }

    try_list_root_dir() {
      # Lenient counterpart to list_root_dir, matching try_read_root_file.
      local path="$1" pattern="''${2:-*}" out
      if [[ -r "$path" ]]; then
        find "$path" -maxdepth 1 -type f -name "$pattern" -printf '%f\t%s\n'
        return 0
      fi
      if command -v sudo >/dev/null 2>&1; then
        if out=$(_bg_sudo find "$path" -maxdepth 1 -type f -name "$pattern" -printf '%f\t%s\n' 2>&1); then
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

    # --- which generation is actually running? ----------------------------------
    #
    # Three different things get called "the current generation", and on a
    # healthy system they're all the same number -- but a full /boot is exactly
    # the situation where they come apart:
    #
    #   BOOTED_GEN   what the machine actually booted       (/run/booted-system)
    #   RUNNING_GEN  what's activated right now             (/run/current-system)
    #                -- differs from BOOTED_GEN after a 'switch' without a reboot
    #   HEAD_GEN     the system profile's head              (/nix/var/nix/profiles/system)
    #                -- what nix-env/nixos-rebuild call "current", and what the
    #                next boot *would* default to if its boot entry got written
    #
    # `nixos-rebuild boot`/`switch` advances HEAD_GEN *before* installing the
    # bootloader entry. When that install then dies with ENOSPC, the profile
    # head points at a generation that never made it onto the boot menu --
    # while the machine is still running whatever older generation it booted.
    # Treating HEAD_GEN as "the booted one" there makes the tool protect the
    # wrong generation and refuse to help at all, which is the one moment it's
    # needed most.
    #
    # resolve_running_generations sets all three, plus PROTECTED_GENS -- a
    # space-separated list of all three *and* every other generation sharing
    # the booted or running store path (see below) -- and never exits.
    # Any of them can come back empty if it can't be resolved -- callers that
    # are about to delete something must fail closed on an empty BOOTED_GEN.
    #
    # Store path -> generation number is by matching every system-N-link, and
    # two generations can legitimately share one store path (re-running switch
    # with no config changes). Ties are broken, in order, by: systemd-boot's
    # LoaderEntrySelected EFI variable (names the exact entry the firmware
    # booted -- only used for BOOTED_GEN), then the profile head if it's among
    # the tied generations, then the highest-numbered one. Since duplicates are
    # bit-identical closures, picking any of them keeps the running system's
    # store path alive; the order just makes the choice stable and sensible.
    # But without the EFI variable (Limine, GRUB) there's no way to know which
    # duplicate's boot entry was really the one used, so every duplicate of the
    # booted/running store path goes into PROTECTED_GENS: harvesting a
    # "duplicate" could otherwise remove the very boot entry you came in on.

    _BG_PROFILE_DIR="''${_BG_PROFILE_DIR:-/nix/var/nix/profiles}"
    _BG_RUN_DIR="''${_BG_RUN_DIR:-/run}"
    _BG_EFIVARS_DIR="''${_BG_EFIVARS_DIR:-/sys/firmware/efi/efivars}"
    _BG_LOADER_ENTRY_SELECTED="LoaderEntrySelected-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"

    _gen_of_link() {
      basename "$1" | sed -nE 's/^system-([0-9]+)-link$/\1/p'
    }

    _gens_for_store_path() {
      # Prints every generation number whose system-N-link resolves to $1.
      local want="$1" link target
      [[ -n "$want" ]] || return 0
      shopt -s nullglob
      for link in "$_BG_PROFILE_DIR"/system-*-link; do
        target="$(readlink -f "$link" 2>/dev/null || true)"
        [[ "$target" == "$want" ]] && _gen_of_link "$link"
      done
      shopt -u nullglob
    }

    _efi_selected_gen() {
      # systemd-boot only: the generation of the entry the firmware booted,
      # from the LoaderEntrySelected EFI variable (world-readable; 4 bytes of
      # attributes, then a UTF-16LE entry id like "nixos-generation-5.conf" or
      # "nixos-generation-5-specialisation-foo.conf"). Prints nothing if the
      # variable isn't there (not systemd-boot, not EFI, efivarfs not mounted).
      local var="$_BG_EFIVARS_DIR/$_BG_LOADER_ENTRY_SELECTED"
      [[ -r "$var" ]] || return 0
      tail -c +5 "$var" 2>/dev/null | tr -d '\0' |
        sed -nE 's/^nixos-generation-([0-9]+)([-.].*)?$/\1/p'
    }

    _pick_gen() {
      # $1: newline list of candidate gens  $2: preferred gen (optional)
      # $3: second-choice gen (optional). Falls back to the highest number.
      local cands="$1" pref
      [[ -n "$cands" ]] || return 0
      for pref in "''${2:-}" "''${3:-}"; do
        if [[ -n "$pref" ]] && grep -qxF "$pref" <<<"$cands"; then
          echo "$pref"
          return 0
        fi
      done
      sort -n <<<"$cands" | tail -n1
    }

    resolve_running_generations() {
      HEAD_GEN=""
      BOOTED_GEN=""
      RUNNING_GEN=""
      PROTECTED_GENS=""

      local head_link booted_path="" running_path="" efi_gen booted_cands="" running_cands=""
      if [[ -L "$_BG_PROFILE_DIR/system" ]]; then
        head_link="$(readlink "$_BG_PROFILE_DIR/system" 2>/dev/null || true)"
        HEAD_GEN="$(_gen_of_link "$head_link")"
      fi

      efi_gen="$(_efi_selected_gen)"

      if [[ -e "$_BG_RUN_DIR/booted-system" ]]; then
        booted_path="$(readlink -f "$_BG_RUN_DIR/booted-system" 2>/dev/null || true)"
        booted_cands="$(_gens_for_store_path "$booted_path")"
        BOOTED_GEN="$(_pick_gen "$booted_cands" "$efi_gen" "$HEAD_GEN")"
      fi

      if [[ -e "$_BG_RUN_DIR/current-system" ]]; then
        running_path="$(readlink -f "$_BG_RUN_DIR/current-system" 2>/dev/null || true)"
        if [[ -n "$BOOTED_GEN" && "$running_path" == "$booted_path" ]]; then
          RUNNING_GEN="$BOOTED_GEN"
        else
          running_cands="$(_gens_for_store_path "$running_path")"
          RUNNING_GEN="$(_pick_gen "$running_cands" "$HEAD_GEN")"
        fi
      fi

      # No /run/booted-system (very old or unusual setups): the running system
      # is the best available stand-in for what was booted.
      [[ -n "$BOOTED_GEN" ]] || BOOTED_GEN="$RUNNING_GEN"

      local g
      for g in "$BOOTED_GEN" "$RUNNING_GEN" "$HEAD_GEN" $booted_cands $running_cands; do
        [[ -n "$g" ]] || continue
        [[ " $PROTECTED_GENS " == *" $g "* ]] || PROTECTED_GENS="''${PROTECTED_GENS:+$PROTECTED_GENS }$g"
      done
      return 0
    }

    is_protected_gen() {
      [[ " $PROTECTED_GENS " == *" $1 "* ]]
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
        _bg_sudo test -e "$path" 2>/dev/null
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
        _bg_sudo stat -c '%Y' "$path" 2>/dev/null
      fi
    }

    _BACKEND_NAMES=(limine systemd-boot grub)

    # Prints "LIMIT COPIES" for the bootloader installer a system build
    # (toplevel) carries: LIMIT is how many of the newest profile generations
    # its boot menu keeps (0 = no limit), COPIES is 1 if it copies kernels and
    # initrds into /boot (0 for GRUB with copyKernels = false). Read from that
    # build's own installer files, so no root is needed. Returns 1 if it can't
    # tell. The three installers keep their limit in different places:
    #   Limine        "maxGenerations": N            in limine-install.json
    #   systemd-boot  CONFIGURATION_LIMIT = int("N") in its builder script
    #   GRUB          <attr name="configurationLimit"> then value="N", and
    #                 copyKernels the same way, in grub-config.xml
    # Each is found by following store paths out from switch-to-configuration
    # a few files deep, skipping binaries and anything large.
    backend_menu_limit_for() {
      local top="$1" stc f next limit="" copies=1 depth
      local -a queue=() seen=()
      stc="$top/bin/switch-to-configuration"
      [[ -r "$stc" ]] || return 1
      mapfile -t queue < <(grep -oE '/nix/store/[a-z0-9]{32}-[A-Za-z0-9._+-]*(install|systemd-boot|grub)[A-Za-z0-9._+/-]*' "$stc" 2>/dev/null | sort -u)
      for ((depth = 0; depth < 4 && ''${#queue[@]} > 0; depth++)); do
        next=()
        for f in "''${queue[@]}"; do
          [[ " ''${seen[*]} " == *" $f "* ]] && continue
          seen+=("$f")
          [[ -f "$f" && -r "$f" ]] || continue
          [[ $(stat -c %s "$f" 2>/dev/null || echo 0) -le 1048576 ]] || continue
          [[ "$(head -c 4 "$f" 2>/dev/null | tr -d '\0')" == $'\x7fELF' ]] && continue
          if [[ -z "$limit" ]]; then
            limit=$(grep -oE '"maxGenerations": *[0-9]+' "$f" 2>/dev/null | grep -oE '[0-9]+$' | head -n1) || true
          fi
          if [[ -z "$limit" ]]; then
            limit=$(grep -oE 'CONFIGURATION_LIMIT = int\("[0-9]+"\)' "$f" 2>/dev/null | grep -oE '[0-9]+' | head -n1) || true
          fi
          if [[ -z "$limit" ]] && grep -q 'name="configurationLimit"' "$f" 2>/dev/null; then
            limit=$(awk '/name="configurationLimit"/ { want = 1; next }
                         want && match($0, /value="[0-9]+"/) { print substr($0, RSTART + 7, RLENGTH - 8); exit }' "$f")
            if awk '/name="copyKernels"/ { want = 1; next }
                    want { exit ($0 ~ /value="false"/) ? 0 : 1 }' "$f"; then
              copies=0
            fi
          fi
          if [[ -n "$limit" ]]; then
            echo "$limit $copies"
            return 0
          fi
          mapfile -t -O "''${#next[@]}" next < <(grep -aoE '/nix/store/[a-z0-9]{32}-[A-Za-z0-9._+/-]+' "$f" 2>/dev/null | sort -u)
        done
        queue=("''${next[@]}")
      done
      return 1
    }

    # Which bootloader the running system installs, read without root:
    # switch-to-configuration names the installer script as a store path
    # (INSTALL_BOOTLOADER), and each NixOS loader module gives that script a
    # recognizable name. Prints the backend name, or returns 1 if it can't
    # tell (an unusual loader, or a layout this doesn't know).
    _bootloader_from_system() {
      local stc="$_BG_RUN_DIR/current-system/bin/switch-to-configuration" paths
      [[ -r "$stc" ]] || return 1
      paths="$(grep -oE '/nix/store/[a-z0-9]+-[A-Za-z0-9._+-]+' "$stc" 2>/dev/null)" || return 1
      if grep -qE -- '-limine-install' <<<"$paths"; then
        echo limine
      elif grep -qE -- '-install-systemd-boot' <<<"$paths"; then
        echo systemd-boot
      elif grep -qE -- '-install-grub' <<<"$paths"; then
        echo grub
      else
        return 1
      fi
    }

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
      for b in "''${_BACKEND_NAMES[@]}"; do
        marker="$(_marker_for_backend "$b")"
        path_exists_root "$marker" && found+=("$b")
      done

      # No marker seen, but only because we weren't allowed to look: /boot is
      # usually root-only, and the interactive list doesn't ask for a sudo
      # password just to start. Ask the running system which bootloader
      # installer it uses instead. If even that can't tell, fall back to the
      # old way and let sudo prompt.
      if [[ ''${#found[@]} -eq 0 && "''${_BG_SUDO_NONINTERACTIVE:-0}" == 1 ]] && ! _bg_sudo_ready; then
        if b="$(_bootloader_from_system)"; then
          echo "$b"
          return 0
        fi
        _BG_SUDO_NONINTERACTIVE=0 detect_bootloader
        return
      fi

      case "''${#found[@]}" in
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
          echo "''${found[0]}"
          ;;
        *)
          echo "Note: more than one bootloader marker exists (''${found[*]}) --" >&2
          echo "one is likely a stale leftover from before you switched" >&2
          echo "bootloaders. Picking whichever was rebuilt more recently." >&2
          local best="" best_mtime=-1 this_mtime all_known=1
          for b in "''${found[@]}"; do
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
      local override="''${1:-}"
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

    # 0 if the boot-menu config can be read right now without a password
    # prompt: either it's readable as-is, or sudo works without asking.
    backend_boot_menu_readable() {
      local p
      case "$BOOTLOADER" in
        limine) p="$LIMINE_CONF" ;;
        systemd-boot) p="$SYSTEMD_BOOT_ENTRIES_DIR" ;;
        grub) p="$GRUB_CONF" ;;
      esac
      if [[ -d "$p" ]]; then
        [[ -r "$p" && -x "$p" ]] && return 0
      elif [[ -r "$p" ]]; then
        return 0
      fi
      _bg_sudo_ready
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
        echo "''${BASH_REMATCH[1]}"
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
        systemd-boot) echo "nixos-generation-''${gen}.conf" ;;
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
      local conf_content="$1" exclude_gen="''${2:-}" filtered="$1"
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
      local exclude_entry="''${1:-}" listing fname all_content=""
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
      local conf_content="$1" exclude_gen="''${2:-}" filtered="$1"
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
      local exclude="''${1:-}"
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
          backup="''${LIMINE_CONF}.bak-$(date +%Y%m%d%H%M%S)"
          local new_content orig_mode
          new_content=$(_limine_conf_without_gen "$entry_id")
          # Capture the original file's permission bits before touching
          # anything -- the write below goes through a mktemp file (600 by
          # default), and without this, `cp` (no -p) onto ''${LIMINE_CONF}.new
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
          sudo cp "$tmpfile" "''${LIMINE_CONF}.new"
          sudo mv "''${LIMINE_CONF}.new" "$LIMINE_CONF"
          [[ -n "$orig_mode" ]] && sudo chmod "$orig_mode" "$LIMINE_CONF"
          rm -f "$tmpfile"
          ;;
        systemd-boot)
          local entry_path="$SYSTEMD_BOOT_ENTRIES_DIR/$entry_id"
          backup="''${entry_path}.bak-$(date +%Y%m%d%H%M%S)"
          echo "Backing up to $backup..."
          sudo cp -p "$entry_path" "$backup"
          echo "Removing $entry_path..."
          sudo rm -f "$entry_path"
          ;;
        grub)
          backup="''${GRUB_CONF}.bak-$(date +%Y%m%d%H%M%S)"
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
          sudo cp "$tmpfile" "''${GRUB_CONF}.new"
          sudo mv "''${GRUB_CONF}.new" "$GRUB_CONF"
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
  '';
in
stdenvNoCC.mkDerivation {
  pname = "boot-gardener";
  version = "2.9.0";

  dontUnpack = true;
  dontBuild = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin $out/libexec/boot-gardener
    install -m755 ${bootBackendSh} $out/libexec/boot-gardener/boot-backend.sh
    install -m755 ${gardenerSh} $out/libexec/boot-gardener/gardener.sh
    install -m755 ${rescueSh} $out/libexec/boot-gardener/rescue.sh
    install -m755 ${dispatcher} $out/bin/boot-gardener

    wrapProgram $out/bin/boot-gardener \
      --prefix PATH : ${lib.makeBinPath [ jq fzf coreutils gnused gawk util-linux findutils diffutils less ]}

    runHook postInstall
  '';

  meta = with lib; {
    description = "Pick (roll back to), pin, prune, harvest, or garbage-collect NixOS generations in your Limine, systemd-boot, or GRUB boot menu, browse the config each was built from, or rescue a full /boot partition";
    platforms = platforms.linux;
    mainProgram = "boot-gardener";
  };
}
