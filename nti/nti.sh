#!/usr/bin/env bash
# nti — Nix Temporary Install (or Not That Into, depending on how it goes).
#
# Programs you're trying out, installed for you without a system rebuild.
# They're listed one per line in a plain Nix file (by default
# ~/.config/nti/packages.nix) that nti edits and you can too. `nti sync` makes
# your Nix user profile match the file: everything on the list is installed,
# anything taken off it is gone. Packages come from the `nixpkgs` flake
# registry entry, which on NixOS is your system's own pinned nixpkgs.
#
# The whole list is installed as one entry in your Nix user profile
# (`nix profile`), named nti-packages, so nti never touches anything else you
# installed there. nti never edits your system config: `nti adopt` only
# prints the line to put in it.
set -euo pipefail

VERSION="@version@"

FILE="${NTI_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/nti/packages.nix}"
NIXPKGS="${NTI_NIXPKGS:-nixpkgs}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/nti"
SYNCED="$STATE_DIR/synced"
ELEMENT="nti-packages"
# A profile other than your default one (nix profile --profile), if set.
PROFILE_ARGS=()
[[ -n "${NTI_PROFILE:-}" ]] && PROFILE_ARGS=(--profile "$NTI_PROFILE")

NIX=(nix --extra-experimental-features "nix-command flakes")

# --- Looks -------------------------------------------------------------------

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  B=$'\e[1m' D=$'\e[2m' R=$'\e[0m'
  OK=$'\e[1;38;5;117m' BAD=$'\e[1;38;5;210m' NOTE=$'\e[38;5;183m'
else
  B="" D="" R="" OK="" BAD="" NOTE=""
fi

FZF_COLORS="fg:#c5c8e6,fg+:#f8f8f2:bold,bg+:#2a2d4a,selected-bg:#262a48"
FZF_COLORS+=",hl:#8be9fd,hl+:#8be9fd:bold,query:#f8f8f2,prompt:#bd93f9"
FZF_COLORS+=",pointer:#ff79c6,marker:#8be9fd,spinner:#bd93f9,info:#8a8fc0"
FZF_COLORS+=",gutter:#1e2035,scrollbar:#6272a4,separator:#3b3f66"
FZF_COLORS+=",border:#6272a4,label:#bd93f9,list-border:#6272a4,list-label:#bd93f9"
FZF_COLORS+=",input-border:#6272a4,input-label:#8be9fd"
FZF_COLORS+=",header:#8be9fd,header-border:#6272a4,header-label:#8be9fd"
FZF_COLORS+=",footer:#a4a9d6,footer-border:#6272a4,footer-label:#bd93f9"
FZF_COLORS+=",preview-fg:#c5c8e6,preview-border:#6272a4,preview-label:#8be9fd"
FZF_THEME=()
[[ -z "${NO_COLOR:-}" ]] && FZF_THEME=(--color "${NTI_COLORS:-$FZF_COLORS}")

say()  { printf '%s\n' "$*"; }
ok()   { printf '%s%s%s\n' "$OK" "$*" "$R"; }
note() { printf '%s%s%s\n' "$NOTE" "$*" "$R"; }
die()  { printf '%snti: %s%s\n' "$BAD" "$*" "$R" >&2; exit 1; }

usage() {
  cat <<EOF
${B}nti${R} $VERSION: Nix Temporary Install. Try programs without a rebuild.

  ${B}nti${R}                  the menu (in a terminal)
  ${B}nti list${R}             what's on the list, how long, and what each is
  ${B}nti add${R} PKG...       put PKG on the list and install it
  ${B}nti drop${R} PKG...      take PKG off the list and uninstall it
  ${B}nti try${R} PKG          a shell with PKG in it, nothing installed
  ${B}nti search${R} WORDS     search nixpkgs
  ${B}nti adopt${R} PKG...     keep PKG for good: prints the line for your config
  ${B}nti edit${R}             open the list in \$VISUAL/\$EDITOR, then sync
  ${B}nti sync${R}             make what's installed match the list
  ${B}nti clean${R}            delete what dropped packages left in /nix/store
  ${B}nti path${R}             print where the list is

PKG is a nixpkgs attribute name, as in packages.nix: ripgrep, kdePackages.kate.

The list: $FILE
  One package per line, editable by hand; run ${B}nti sync${R} after.
  NTI_FILE sets another file, NTI_NIXPKGS another nixpkgs flake (default: nixpkgs),
  NTI_PROFILE another Nix profile (default: your user profile).
EOF
}

# --- The list file -----------------------------------------------------------

ensure_file() {
  [[ -e "$FILE" ]] && return
  mkdir -p "$(dirname "$FILE")"
  cat >"$FILE" <<'EOF'
# Programs on trial, installed by nti (Nix Temporary Install) without a
# rebuild. One package per line, as nixpkgs attribute names (ripgrep,
# kdePackages.kate); the comment after each is the day it was added.
# nti adds and removes lines; you can edit by hand too, then run `nti sync`.
{ pkgs, ... }:
with pkgs; [
]
EOF
}

# "attr<TAB>date" for each package on the list. A line inside the [ ] whose
# first word looks like an attribute name is a package; the date is the first
# YYYY-MM-DD in its comment, if any.
entries() {
  ensure_file
  awk '
    !inlist && /\[/ { inlist = 1; sub(/.*\[/, "") }
    inlist {
      if ($0 ~ /^[[:space:]]*\]/) exit
      line = $0
      comment = ""
      if (index(line, "#")) { comment = substr(line, index(line, "#")); line = substr(line, 1, index(line, "#") - 1) }
      n = split(line, w, /[[:space:]]+/)
      for (i = 1; i <= n; i++) {
        if (w[i] ~ /^[A-Za-z_][A-Za-z0-9_.+-]*$/) {
          d = ""
          if (match(comment, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) d = substr(comment, RSTART, RLENGTH)
          print w[i] "\t" d
        }
      }
    }
  ' "$FILE"
}

attrs() { entries | cut -f1; }

on_list() { attrs | grep -qxF -- "$1"; }

# Adds a line before the closing ] of the list.
file_add() {
  local attr="$1" tmp
  tmp=$(mktemp)
  awk -v line="  $attr  # added $(date +%F)" '
    { lines[NR] = $0 }
    /^[[:space:]]*\]/ { close_at = NR }
    END {
      for (i = 1; i <= NR; i++) {
        if (i == close_at) print line
        print lines[i]
      }
      if (!close_at) exit 1
    }
  ' "$FILE" >"$tmp" || { rm -f "$tmp"; die "can't find the closing ] of the list in $FILE"; }
  cat "$tmp" >"$FILE"
  rm -f "$tmp"
}

# Removes the line(s) whose package is attr.
file_drop() {
  local attr="$1" tmp
  tmp=$(mktemp)
  awk -v attr="$attr" '
    !inlist && /\[/ { inlist = 1 }
    inlist && !done {
      if ($0 ~ /^[[:space:]]*\]/) done = 1
      line = $0
      sub(/#.*/, "", line)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (line == attr) next
    }
    { print }
  ' "$FILE" >"$tmp"
  cat "$tmp" >"$FILE"
  rm -f "$tmp"
}

# --- Nix ---------------------------------------------------------------------

# The nixpkgs every command uses (NTI_NIXPKGS), with the user's own nixpkgs
# config (~/.config/nixpkgs/config.nix: allowUnfree and so on).
PRELUDE='
  let
    pkgs = import (builtins.getFlake (builtins.getEnv "NTI_NIXPKGS")) { system = builtins.currentSystem; };
    lib = pkgs.lib;
    get = a: lib.attrByPath (lib.splitString "." a) null pkgs;
  in'

nix_eval() {
  NTI_NIXPKGS="$NIXPKGS" "${NIX[@]}" eval --impure "$@"
}

# JSON object: attr -> { ok, version, description, out } for each attr given.
info_json() {
  local list
  list=$(printf '%s\n' "$@")
  NTI_ATTRS="$list" nix_eval --json --expr "$PRELUDE"'
    let
      names = builtins.filter (s: s != "") (lib.splitString "\n" (builtins.getEnv "NTI_ATTRS"));
      one = a:
        let
          p = get a;
          isDrv = p != null && lib.isDerivation p;
          out = if isDrv then builtins.tryEval (p.outPath) else { success = false; };
        in {
          ok = out.success;
          found = p != null;
          version = if isDrv then (p.version or "") else "";
          description = if isDrv then (p.meta.description or "") else "";
          out = if out.success then builtins.unsafeDiscardStringContext out.value else "";
        };
    in lib.genAttrs names one' 2>/dev/null
}

# Why attr can't be installed: the common reasons in a line, anything else in
# Nix's words (the last lines of its error).
why_not() {
  local err cfg="${XDG_CONFIG_HOME:-$HOME/.config}/nixpkgs/config.nix"
  err=$(NTI_ATTR="$1" nix_eval --raw --expr "$PRELUDE"'
    let p = get (builtins.getEnv "NTI_ATTR"); in
    if p == null then throw "nixpkgs has no package called ${builtins.getEnv "NTI_ATTR"}"
    else p.outPath' 2>&1 >/dev/null || true)
  if grep -q "has an unfree license" <<<"$err"; then
    say "it's unfree (not open source). To allow unfree packages, put"
    say "{ allowUnfree = true; } in $cfg"
  elif grep -q "is marked as broken" <<<"$err"; then
    say "nixpkgs marks it as broken: it doesn't build or work right now."
  elif grep -q "is marked as insecure" <<<"$err"; then
    say "nixpkgs marks it as insecure (known security problems), so it's blocked."
  elif grep -q "is not available on the requested hostPlatform" <<<"$err"; then
    say "it isn't available for this kind of computer ($(uname -m))."
  else
    grep -v '^\s*\(…\|at \|[0-9]*|\|error:\s*$\)' <<<"$err" | grep . | sed 's/^\s*error: //' | tail -n 3
  fi
}

# Store paths the system and Home Manager install (NixOS), to spot packages
# that are already in your config.
config_paths() {
  local p
  for p in /run/current-system/sw "/etc/profiles/per-user/$USER" "$HOME/.local/state/home-manager/gcroots/current-home/home-path"; do
    [[ -e "$p" ]] && nix-store -q --references "$(readlink -f "$p")" 2>/dev/null
  done | sort -u
}

# Runs `nix profile ACTION ARG` quietly; on failure, says what Nix said.
profile_do() {
  local err
  err=$("${NIX[@]}" profile "$1" "${PROFILE_ARGS[@]}" "$2" 2>&1 >/dev/null) ||
    die "nix profile $1 failed:$(printf "\n%s" "$err" | tail -n 4)"
}

profile_has_element() {
  "${NIX[@]}" profile list "${PROFILE_ARGS[@]}" --json 2>/dev/null | jq -e --arg n "$ELEMENT" '
    .elements | if type == "object" then has($n) else any(.[]; .name? == $n) end' >/dev/null
}

profile_element_path() {
  "${NIX[@]}" profile list "${PROFILE_ARGS[@]}" --json 2>/dev/null | jq -r --arg n "$ELEMENT" '
    .elements | if type == "object" then .[$n].storePaths[0] // empty
    else (map(select(.name? == $n)) | .[0].storePaths[0] // empty) end'
}

# --- Commands ----------------------------------------------------------------

cmd_sync() {
  ensure_file
  mkdir -p "$STATE_DIR"
  local before after new gone current out
  before=$(cat "$SYNCED" 2>/dev/null || true)
  after=$(attrs | sort -u)

  if [[ -z "$after" ]]; then
    if profile_has_element; then
      profile_do remove "$ELEMENT"
    fi
  else
    say "${D}Building the list...${R}"
    out=$(NTI_FILE="$FILE" NTI_NIXPKGS="$NIXPKGS" "${NIX[@]}" build --impure --no-link --print-out-paths --expr "$PRELUDE"'
      pkgs.buildEnv {
        name = "nti-packages";
        paths = let f = import (builtins.getEnv "NTI_FILE"); in
          f (builtins.intersectAttrs (builtins.functionArgs f) { inherit pkgs lib; });
        extraOutputsToInstall = [ "man" ];
      }') || die "the list didn't build, so nothing changed. Fix $FILE (or 'nti drop' the package above) and run 'nti sync'."
    current=$(profile_element_path)
    if [[ "$current" != "$out" ]]; then
      # Built first, so the swap is two quick steps that can't fail halfway
      # on a download or a compile.
      if [[ -n "$current" ]] || profile_has_element; then
        profile_do remove "$ELEMENT"
      fi
      profile_do add "$out"
    fi
  fi

  new=$(comm -13 <(printf '%s\n' "$before" | grep .) <(printf '%s\n' "$after" | grep .) || true)
  gone=$(comm -23 <(printf '%s\n' "$before" | grep .) <(printf '%s\n' "$after" | grep .) || true)
  printf '%s\n' "$after" >"$SYNCED"
  [[ -n "$new" ]] && ok "Installed: $(paste -sd' ' <<<"$new" | sed 's/ /, /g')"
  [[ -n "$gone" ]] && ok "Removed: $(paste -sd' ' <<<"$gone" | sed 's/ /, /g')"
  [[ -z "$new" && -z "$gone" ]] && ok "Up to date: $(wc -l < <(printf '%s\n' "$after" | grep .)) package(s) on the list."
  return 0
}

cmd_add() {
  [[ $# -gt 0 ]] || die "add what? e.g. nti add ripgrep"
  ensure_file
  local info a added=0
  say "${D}Looking them up in nixpkgs...${R}"
  info=$(info_json "$@") || die "couldn't read nixpkgs ($NIXPKGS)."
  for a in "$@"; do
    if on_list "$a"; then
      note "$a is already on the list."
    elif [[ $(jq -r --arg a "$a" '.[$a].ok' <<<"$info") != true ]]; then
      printf '%sCan'\''t add %s:%s\n' "$BAD" "$a" "$R"
      why_not "$a" | sed 's/^/  /'
    else
      file_add "$a"
      added=1
      say "Added $B$a$R $(jq -r --arg a "$a" '.[$a].version' <<<"$info")"
    fi
  done
  [[ $added -eq 1 ]] && cmd_sync
  return 0
}

cmd_drop() {
  [[ $# -gt 0 ]] || die "drop what? e.g. nti drop ripgrep"
  ensure_file
  local a dropped=0
  for a in "$@"; do
    if on_list "$a"; then
      file_drop "$a"
      dropped=1
    else
      note "$a isn't on the list."
    fi
  done
  [[ $dropped -eq 1 ]] && cmd_sync
  [[ $dropped -eq 1 ]] && say "${D}What it left in /nix/store goes with your next garbage collection, or now with 'nti clean'.${R}"
  return 0
}

cmd_try() {
  [[ $# -ge 1 ]] || die "try what? e.g. nti try ripgrep"
  local a="$1"
  note "A shell with $a in it. Nothing is installed; type 'exit' to leave."
  NTI_NIXPKGS="$NIXPKGS" "${NIX[@]}" shell "$NIXPKGS#$a" || true
  note "Back from $a. To keep it around: nti add $a"
}

cmd_search() {
  [[ $# -ge 1 ]] || die "search for what? e.g. nti search markdown viewer"
  "${NIX[@]}" search "$NIXPKGS" "$@"
}

cmd_adopt() {
  [[ $# -gt 0 ]] || die "adopt what? e.g. nti adopt ripgrep"
  local a
  say "To keep these for good, add them to the package list in your system or"
  say "Home Manager config (environment.systemPackages or home.packages):"
  say
  for a in "$@"; do
    on_list "$a" || note "  ($a isn't on nti's list, but here it is anyway.)"
    say "  $B$a$R"
  done
  say
  say "Then rebuild, and take them off nti's list: ${B}nti drop $*${R}"
  say "${D}(nti list marks a package \"in config\" once your rebuilt system has it.)${R}"
}

cmd_list() {
  ensure_file
  local rows info cfg
  rows=$(entries)
  if [[ -z "$rows" ]]; then
    say "Nothing on the list. Add something with ${B}nti add PKG${R}."
    return 0
  fi
  info=$(info_json $(cut -f1 <<<"$rows")) || info='{}'
  cfg=$(config_paths)
  list_rows "$rows" "$info" "$cfg" | column -t -s $'\t'
}

# One line per package: name, version, age, note, description.
list_rows() {
  local rows="$1" info="$2" cfg="$3" a d days age ver desc out flag today
  today=$(date +%s)
  printf 'PACKAGE\tVERSION\tFOR\tSTATUS\tDESCRIPTION\n'
  while IFS=$'\t' read -r a d; do
    age="-"
    if [[ -n "$d" ]] && days=$(( (today - $(date -d "$d" +%s)) / 86400 )) 2>/dev/null; then
      age="${days}d"
    fi
    ver=$(jq -r --arg a "$a" '.[$a].version // ""' <<<"$info")
    desc=$(jq -r --arg a "$a" '.[$a].description // ""' <<<"$info")
    out=$(jq -r --arg a "$a" '.[$a].out // ""' <<<"$info")
    if [[ $(jq -r --arg a "$a" '.[$a].ok // false' <<<"$info") != true ]]; then
      flag="broken"
    elif [[ -n "$out" ]] && grep -qxF -- "$out" <<<"$cfg"; then
      flag="in config"
    else
      flag="on trial"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$a" "${ver:--}" "$age" "$flag" "${desc:0:60}"
  done <<<"$rows"
}

cmd_edit() {
  ensure_file
  local before after
  before=$(attrs)
  "${VISUAL:-${EDITOR:-nano}}" "$FILE"
  after=$(attrs)
  if [[ "$before" == "$after" ]]; then
    note "No change to the list."
  else
    cmd_sync
  fi
}

cmd_clean() {
  say "Old versions of your Nix profile keep dropped packages on disk, so you"
  say "can roll back. This deletes every old version of your user profile"
  say "(not the system's) and then collects garbage."
  read -rp "Go ahead? [y/N] " yn
  [[ "$yn" == [yY]* ]] || { note "Nothing deleted."; return 0; }
  "${NIX[@]}" profile wipe-history "${PROFILE_ARGS[@]}"
  "${NIX[@]}" store gc
}

# --- The menu ----------------------------------------------------------------

pause() { printf '\n%sPress Enter to go back.%s' "$D" "$R"; read -r _ || true; }

menu_add() {
  local words picked
  printf '\n'
  read -rp "Search nixpkgs for: " words || return 0
  [[ -n "$words" ]] || return 0
  say "${D}Searching...${R}"
  picked=$(
    "${NIX[@]}" search "$NIXPKGS" $words --json 2>/dev/null |
      jq -r 'to_entries[] | (.key | split(".") | .[2:] | join(".")) + "\t" + .value.version + "\t" + .value.description' |
      column -t -s $'\t' -l 3 |
      fzf --style full --layout reverse --multi \
        --border-label " nti: add " "${FZF_THEME[@]}" \
        --header "Results for: $words" \
        --footer "  Enter:add   Tab:mark several   Esc:back" |
      awk '{print $1}'
  ) || return 0
  [[ -n "$picked" ]] || return 0
  # shellcheck disable=SC2086
  cmd_add $picked
  pause
}

menu() {
  local rows info cfg raw key picked
  while true; do
    ensure_file
    rows=$(entries)
    if [[ -n "$rows" ]]; then
      info=$(info_json $(cut -f1 <<<"$rows")) || info='{}'
    else
      info='{}'
    fi
    cfg=$(config_paths)
    raw=$(
      {
        if [[ -n "$rows" ]]; then
          list_rows "$rows" "$info" "$cfg" | column -t -s $'\t'
        else
          printf 'PACKAGE\n(nothing yet: press a to add something)\n'
        fi
      } | fzf --style full --layout reverse --multi --no-input \
        --header-lines 1 --header-first \
        --header "Programs on trial, no rebuild needed.  List: ${FILE/#$HOME/\~}" \
        --border-label " nti " "${FZF_THEME[@]}" \
        --footer "  a:add   d:drop   t:try   k:keep for good   e:edit list   s:sync   c:clean   q:quit"$'\n'"  Tab:mark several   ?:help" \
        --bind 'q:abort' --bind '?:toggle-preview' \
        --preview "$0 help" --preview-window 'down,70%:hidden:wrap' \
        --expect=a,d,t,k,e,s,c,enter
    ) || return 0
    key=$(head -n1 <<<"$raw")
    picked=$(tail -n +2 <<<"$raw" | awk '{print $1}' | grep -v '^(nothing' || true)
    case "$key" in
      a) menu_add ;;
      d) [[ -n "$picked" ]] && { cmd_drop $picked; pause; } ;;
      t) [[ -n "$picked" ]] && { cmd_try "$(head -n1 <<<"$picked")"; } ;;
      k) [[ -n "$picked" ]] && { printf '\n'; cmd_adopt $picked; pause; } ;;
      e) cmd_edit; pause ;;
      s) printf '\n'; cmd_sync; pause ;;
      c) printf '\n'; cmd_clean; pause ;;
      enter) [[ -n "$picked" ]] && { printf '\n'; NTI_ATTR="$(head -n1 <<<"$picked")" show_one; pause; } ;;
    esac
  done
}

show_one() {
  local a="$NTI_ATTR"
  NTI_ATTR="$a" nix_eval --raw --expr "$PRELUDE"'
    let p = get (builtins.getEnv "NTI_ATTR"); m = p.meta or {}; in
    "${p.name or "?"}\n\n${m.description or ""}\n\n${m.longDescription or ""}\nHomepage: ${m.homepage or "-"}\n"' 2>/dev/null || say "$a"
  say "Keys: t to try it in a shell, k to keep it for good, d to drop it."
}

# --- Main --------------------------------------------------------------------

for tool in nix jq; do
  command -v "$tool" >/dev/null || die "needs $tool on PATH."
done

case "${1:-}" in
  "")            if [[ -t 0 && -t 1 ]]; then menu; else cmd_list; fi ;;
  list|ls)       shift; cmd_list "$@" ;;
  add|install)   shift; cmd_add "$@" ;;
  drop|rm|remove) shift; cmd_drop "$@" ;;
  try|shell)     shift; cmd_try "$@" ;;
  search|find)   shift; cmd_search "$@" ;;
  adopt|keep)    shift; cmd_adopt "$@" ;;
  edit)          shift; cmd_edit ;;
  sync)          shift; cmd_sync ;;
  clean|gc)      shift; cmd_clean ;;
  path)          say "$FILE" ;;
  help|-h|--help) usage ;;
  --version)     say "nti $VERSION" ;;
  *)             usage >&2; exit 1 ;;
esac
