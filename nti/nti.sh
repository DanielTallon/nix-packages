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
# "attr<TAB>version" for each package the last sync installed.
VERSIONS="$STATE_DIR/versions"
ELEMENT="nti-packages"
# A profile other than your default one (nix profile --profile), if set.
PROFILE_ARGS=()
[[ -n "${NTI_PROFILE:-}" ]] && PROFILE_ARGS=(--profile "$NTI_PROFILE")

NIX=(nix --extra-experimental-features "nix-command flakes")

# Shell setup files nti writes on every sync, for programs on the list that
# need a line in your shell config to work (see HOOKS below). Fish loads its
# file by itself; bash and zsh need one line in ~/.bashrc / ~/.zshrc.
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
FISH_HOOKS="$CONFIG_DIR/fish/conf.d/nti.fish"
BASH_HOOKS="$CONFIG_DIR/nti/hooks.bash"
ZSH_HOOKS="$CONFIG_DIR/nti/hooks.zsh"
# Your Nix profile, for the paths printed in hints.
PROFILE_LINK="${NTI_PROFILE:-$HOME/.nix-profile}"

# Programs that need shell setup, and the command that prints it. One per
# line: nixpkgs attr, the command, then its arguments for fish | bash | zsh
# (a "-" means that shell has none). The output is sourced in each new
# interactive shell.
# Order matters: fzf, mcfly, atuin and television all take over Ctrl+R and
# the last one loaded wins, so fzf comes first and the history tools after.
HOOKS='
fzf             fzf             --fish | --bash | --zsh
mcfly           mcfly           init fish | init bash | init zsh
mcfly-fzf       mcfly-fzf       init fish | init bash | init zsh
atuin           atuin           init fish | init bash | init zsh
television      tv              init fish | init bash | init zsh
zoxide          zoxide          init fish | init bash | init zsh
starship        starship        init fish | init bash | init zsh
direnv          direnv          hook fish | hook bash | hook zsh
mise            mise            activate fish | activate bash | activate zsh
broot           broot           --print-shell-function fish | --print-shell-function bash | --print-shell-function zsh
navi            navi            widget fish | widget bash | widget zsh
fnm             fnm             env --use-on-cd --shell fish | env --use-on-cd --shell bash | env --use-on-cd --shell zsh
nix-your-shell  nix-your-shell  fish | bash | zsh
pay-respects    pay-respects    fish | bash | zsh
carapace        carapace        _carapace fish | _carapace bash | _carapace zsh
'

# Setup that only works on top of another program's: "attr  needs attr".
# Without the second one on the list, the first one's setup is left out
# (it would print an error in every new shell), and sync says why.
HOOK_NEEDS='
mcfly-fzf       mcfly
'

# --- Looks -------------------------------------------------------------------

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  B=$'\e[1m' D=$'\e[2m' R=$'\e[0m'
  OK=$'\e[1;38;5;117m' BAD=$'\e[1;38;5;210m' NOTE=$'\e[38;5;183m' WARN=$'\e[1;38;2;241;250;140m'
else
  B="" D="" R="" OK="" BAD="" NOTE="" WARN=""
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
  ${B}nti hooks${R}            the shell setup nti does for programs on the list
  ${B}nti path${R}             print where the list is

PKG is a nixpkgs attribute name, as in packages.nix: ripgrep, kdePackages.kate.

The list: $FILE
  One package per line, editable by hand; run ${B}nti sync${R} after.
  NTI_FILE sets another file, NTI_NIXPKGS another nixpkgs flake (default: nixpkgs),
  NTI_PROFILE another Nix profile (default: your user profile).

Shell setup: some programs (mcfly, zoxide, starship, direnv...) only work once
your shell runs their setup. nti writes that for whatever is on the list:
  fish  ${FISH_HOOKS/#$HOME/\~} (loaded by itself)
  bash  ${BASH_HOOKS/#$HOME/\~}
  zsh   ${ZSH_HOOKS/#$HOME/\~}
  (bash and zsh need one line in ~/.bashrc / ~/.zshrc: ${B}nti hooks${R} shows it)
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

# --- Shell setup -------------------------------------------------------------

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# "attr<TAB>command<TAB>fish args<TAB>bash args<TAB>zsh args" for each package
# on the list that needs shell setup, in HOOKS order. Left out: setup whose
# program needs another one that isn't on the list (see unmet_hooks).
active_hooks() {
  local on unmet attr bin rest f b z
  on=$(attrs | sort -u)
  unmet=$(unmet_hooks | cut -f1)
  while read -r attr bin rest; do
    [[ -n "$attr" ]] || continue
    grep -qxF -- "$attr" <<<"$on" || continue
    grep -qxF -- "$attr" <<<"$unmet" && continue
    IFS='|' read -r f b z <<<"$rest"
    printf '%s\t%s\t%s\t%s\t%s\n' "$attr" "$bin" "$(trim "$f")" "$(trim "$b")" "$(trim "$z")"
  done <<<"$HOOKS"
}

# "attr<TAB>what it needs" for each package on the list whose shell setup
# needs another package (HOOK_NEEDS) that isn't on the list.
unmet_hooks() {
  local on attr need
  on=$(attrs | sort -u)
  while read -r attr need; do
    [[ -n "$attr" ]] || continue
    grep -qxF -- "$attr" <<<"$on" || continue
    grep -qxF -- "$need" <<<"$on" && continue
    printf '%s\t%s\n' "$attr" "$need"
  done <<<"$HOOK_NEEDS"
}

# Says, for each package whose setup is left out, what to do about it.
warn_unmet_hooks() {
  local attr need
  while IFS=$'\t' read -r attr need; do
    [[ -n "$attr" ]] || continue
    printf '%s%s only works with %s, which isn'\''t on the list, so its shell setup is off.%s\n' \
      "$WARN" "$attr" "$need" "$R"
    say "  To fix it: ${B}nti add $need${R}, or ${B}nti drop $attr${R} if you're done with it."
  done < <(unmet_hooks)
}

# Writes stdin to the file, unless the file already says exactly that.
write_if_changed() {
  local file="$1" new
  new=$(cat)
  [[ -e "$file" && "$(cat "$file")" == "$new" ]] && return 0
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$new" >"$file"
}

hooks_header() {
  printf '%s\n' \
    "# Written by nti (Nix Temporary Install) on every sync: setup for the" \
    "# programs on its list that need it. nti rewrites this file, so change" \
    "# the list instead; 'nti hooks' shows what's here."
}

# Each line: "shell<TAB>its rc file<TAB>nti's file for it", for bash and zsh
# if installed. Fish needs no line: it loads conf.d by itself.
shell_rcs() {
  command -v bash >/dev/null && printf 'bash\t%s\t%s\n' "$HOME/.bashrc" "$BASH_HOOKS"
  command -v zsh >/dev/null && printf 'zsh\t%s\t%s\n' "${ZDOTDIR:-$HOME}/.zshrc" "$ZSH_HOOKS"
  return 0
}

# The line that loads nti's file ($1) from a bash or zsh rc file.
rc_line() { local f="${1/#$HOME/\~}"; printf '[ -f %s ] && . %s' "$f" "$f"; }

rc_loads() { [[ -e "$1" ]] && grep -qF "nti/hooks." "$1"; }

# Rewrites the shell setup files to match the list, and says what changed.
write_hooks() {
  local rows before now added removed sh rc file told
  rows=$(active_hooks)
  if [[ -z "$rows" ]]; then
    rm -f "$FISH_HOOKS" "$BASH_HOOKS" "$ZSH_HOOKS"
  else
    # Written for each shell that's installed, and always kept current once
    # it exists, so a sync without that shell on PATH can't leave it stale.
    if command -v fish >/dev/null || [[ -d "$CONFIG_DIR/fish" || -e "$FISH_HOOKS" ]]; then
      {
        hooks_header
        printf 'if status is-interactive\n'
        awk -F'\t' '$3 != "-" { printf "    type -q %s; and %s %s | source\n", $2, $2, $3 }' <<<"$rows"
        printf 'end\n'
      } | write_if_changed "$FISH_HOOKS"
    fi
    {
      hooks_header
      printf '[[ $- == *i* ]] || return 0\n'
      awk -F'\t' '$4 != "-" { printf "command -v %s >/dev/null && eval \"$(%s %s)\"\n", $2, $2, $4 }' <<<"$rows"
    } | write_if_changed "$BASH_HOOKS"
    if command -v zsh >/dev/null || [[ -e "$ZSH_HOOKS" ]]; then
      {
        hooks_header
        printf '[[ -o interactive ]] || return 0\n'
        awk -F'\t' '$5 != "-" { printf "(( $+commands[%s] )) && eval \"$(%s %s)\"\n", $2, $2, $5 }' <<<"$rows"
      } | write_if_changed "$ZSH_HOOKS"
    fi
  fi

  before=$(grep . "$STATE_DIR/hooked" 2>/dev/null | sort || true)
  now=$(cut -f1 <<<"$rows" | grep . | sort || true)
  printf '%s\n' "$now" >"$STATE_DIR/hooked"
  added=$(comm -13 <(printf '%s\n' "$before" | grep .) <(printf '%s\n' "$now" | grep .) || true)
  removed=$(comm -23 <(printf '%s\n' "$before" | grep .) <(printf '%s\n' "$now" | grep .) || true)
  [[ -n "$removed" ]] && ok "Shell setup removed: $(paste -sd' ' <<<"$removed" | sed 's/ /, /g')"
  warn_unmet_hooks
  [[ -z "$added" ]] && return 0
  ok "Shell setup added: $(paste -sd' ' <<<"$added" | sed 's/ /, /g'). Open a new terminal to use it."
  # Bash and zsh need a line in their rc file, once. Said for the shells
  # you use (your login shell, or one with an rc file) that lack it.
  while IFS=$'\t' read -r sh rc file; do
    told="$STATE_DIR/told-$sh"
    rc_loads "$rc" && continue
    [[ -e "$told" ]] && continue
    [[ -e "$rc" || "$(basename "${SHELL:-}")" == "$sh" ]] || continue
    note "For $sh, add this line to ${rc/#$HOME/\~} (or to your config, if Home Manager writes that file):"
    say "  $(rc_line "$file")"
    : >"$told"
  done < <(shell_rcs)
  return 0
}

cmd_hooks() {
  ensure_file
  local rows sh rc file
  rows=$(active_hooks)
  if [[ -z "$rows" ]]; then
    say "Nothing on the list needs shell setup."
  else
    say "Shell setup for programs on the list (in this order):"
    awk -F'\t' '{ printf "  %s\t%s %s\n", $1, $2, $3 }' <<<"$rows" | column -t -s $'\t'
  fi
  warn_unmet_hooks
  if out_of_sync; then
    printf '%sThe list changed since the last sync; nti sync updates this.%s\n' "$WARN" "$R"
  fi
  say
  say "fish  ${FISH_HOOKS/#$HOME/\~} (loads by itself)"
  while IFS=$'\t' read -r sh rc file; do
    if rc_loads "$rc"; then
      say "$sh  ${file/#$HOME/\~} (loaded from ${rc/#$HOME/\~})"
    else
      say "$sh  ${file/#$HOME/\~}: not loaded yet. Add this to ${rc/#$HOME/\~}:"
      say "      $(rc_line "$file")"
    fi
  done < <(shell_rcs)
  say
  say "${D}nti knows the setup for: $(awk 'NF { print $1 }' <<<"$HOOKS" | paste -sd' ' | sed 's/ /, /g').${R}"
  say "${D}For anything else, put its setup line in your shell config yourself.${R}"
}

# --- Things an install can't set up ------------------------------------------

# What a package ships that only works once your system config sets it up:
# "what<TAB>NixOS config line" per kind found. $1 = attr, $2 = store path.
system_parts() {
  local a="$1" o="$2"
  [[ -d "$o" ]] || return 0
  if compgen -G "$o/lib/udev/rules.d/*" >/dev/null || compgen -G "$o/etc/udev/rules.d/*" >/dev/null; then
    printf 'udev rules (device access)\tservices.udev.packages = [ pkgs.%s ];\n' "$a"
  fi
  if compgen -G "$o/lib/systemd/system/*" >/dev/null || compgen -G "$o/etc/systemd/system/*" >/dev/null; then
    printf 'system services\tsystemd.packages = [ pkgs.%s ];\n' "$a"
  fi
  if compgen -G "$o/share/dbus-1/system-services/*" >/dev/null || compgen -G "$o/share/dbus-1/system.d/*" >/dev/null ||
    compgen -G "$o/etc/dbus-1/system.d/*" >/dev/null; then
    printf 'D-Bus system services\tservices.dbus.packages = [ pkgs.%s ];\n' "$a"
  fi
  if compgen -G "$o/share/polkit-1/actions/*" >/dev/null; then
    printf 'polkit actions (admin prompts)\tenvironment.systemPackages = [ pkgs.%s ];\n' "$a"
  fi
  return 0
}

# "attr<TAB>config line" for each attr given that NixOS has a programs.* or
# services.* module for (on NixOS only). Such a module often sets up what a
# plain install can't: permissions, wrappers, services, groups.
nixos_modules() {
  [[ -e /etc/NIXOS && $# -gt 0 ]] || return 0
  NTI_ATTRS="$(printf '%s\n' "$@")" nix_eval --raw --expr "$PRELUDE"'
    let
      o = (import "${pkgs.path}/nixos/lib/eval-config.nix" { system = builtins.currentSystem; modules = [ ]; }).options;
      names = builtins.filter (s: s != "") (lib.splitString "\n" (builtins.getEnv "NTI_ATTRS"));
      has = set: n: set ? ${n} && set.${n} ? enable;
      line = a:
        let n = lib.last (lib.splitString "." a); in
        if has o.programs n then "programs.${n}.enable = true;"
        else if has o.services n then "services.${n}.enable = true;"
        else "";
    in lib.concatMapStrings (a: let l = line a; in lib.optionalString (l != "") "${a}\t${l}\n") names' 2>/dev/null || true
}

# After a sync installs something new: what it needs that nti can't do.
# $1 = the new attrs, one per line; $2 = info_json for them.
report_extras() {
  local new="$1" info="$2" mods a o parts mod units u
  # shellcheck disable=SC2046
  mods=$(nixos_modules $(printf '%s\n' "$new"))
  while read -r a; do
    [[ -n "$a" ]] || continue
    o=$(jq -r --arg a "$a" '.[$a].out // ""' <<<"$info")
    parts=$(system_parts "$a" "$o")
    mod=$(awk -F'\t' -v a="$a" '$1 == a { print $2 }' <<<"$mods")
    if [[ -n "$parts" ]]; then
      printf '\n%s%s may not fully work from nti:%s it comes with %s,\n' "$WARN" "$a" "$R" \
        "$(cut -f1 <<<"$parts" | paste -sd'|' | sed 's/|/, /g')"
      say "which only your system config can set up. To use all of it, put this in your"
      say "NixOS config and rebuild (then nti drop $a):"
      if [[ -n "$mod" ]]; then
        say "  $B$mod$R"
      else
        cut -f2 <<<"$parts" | sed "s/^/  /"
      fi
    elif [[ -n "$mod" ]] && ! awk -v a="$a" '$1 == a { f = 1 } END { exit !f }' <<<"$HOOKS"; then
      # (For programs in HOOKS, the module is mostly the shell setup nti does.)
      printf '\n'
      note "NixOS also has a module for $a: $mod"
      say "${D}Some programs need theirs for permissions or services. If $a doesn't fully"
      say "work from nti, use that line in your config instead (then nti drop $a).${R}"
    fi
    units=()
    for u in "$o"/lib/systemd/user/*.service; do
      [[ -e "$u" ]] && units+=("$(basename "$u")")
    done
    if [[ ${#units[@]} -gt 0 ]]; then
      printf '\n'
      note "$a comes with a background service you can run: ${units[*]}"
      say "  systemctl --user link ${PROFILE_LINK/#$HOME/\~}/lib/systemd/user/${units[0]}"
      say "  systemctl --user enable --now ${units[0]}"
      say "${D}nti doesn't start it for you. Disable it before you drop $a.${R}"
    fi
  done <<<"$new"
  return 0
}

# --- Commands ----------------------------------------------------------------

cmd_sync() {
  ensure_file
  mkdir -p "$STATE_DIR"
  local before after new gone current out changed=0 old_versions new_versions updated="" info_all=""
  before=$(cat "$SYNCED" 2>/dev/null || true)
  old_versions=$(cat "$VERSIONS" 2>/dev/null || true)
  new_versions=""
  after=$(attrs | sort -u)

  if [[ -z "$after" ]]; then
    if profile_has_element; then
      profile_do remove "$ELEMENT"
    fi
  else
    say "${D}Building the list...${R}"
    local log
    log=$(mktemp)
    # Nix's progress still shows; its errors are also kept, to explain below.
    if ! out=$(NTI_FILE="$FILE" NTI_NIXPKGS="$NIXPKGS" "${NIX[@]}" build --impure --no-link --print-out-paths --expr "$PRELUDE"'
      pkgs.buildEnv {
        name = "nti-packages";
        paths = let f = import (builtins.getEnv "NTI_FILE"); in
          f (builtins.intersectAttrs (builtins.functionArgs f) { inherit pkgs lib; });
        extraOutputsToInstall = [ "man" ];
      }' 2> >(tee "$log" >&2)); then
      sleep 0.1 # let tee finish writing
      explain_build_failure "$log"
      rm -f "$log"
      return 1
    fi
    rm -f "$log"
    current=$(profile_element_path)
    # Versions now, to say what a sync updated (same nixpkgs as the build).
    # shellcheck disable=SC2046
    info_all=$(info_json $(printf '%s\n' "$after") || true)
    new_versions=$(jq -r 'to_entries[] | "\(.key)\t\(.value.version)"' <<<"$info_all" 2>/dev/null || true)
    if [[ "$current" != "$out" ]]; then
      changed=1
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
  # Packages that were installed before and now have another version.
  if [[ -n "$old_versions" && -n "$new_versions" ]]; then
    updated=$(awk -F'\t' '
      NR == FNR { old[$1] = $2; next }
      ($1 in old) && old[$1] != $2 { printf "%s%s %s → %s", (n++ ? ", " : ""), $1, old[$1], $2 }
    ' <(printf '%s\n' "$old_versions") <(printf '%s\n' "$new_versions"))
  fi
  printf '%s\n' "$after" >"$SYNCED"
  printf '%s\n' "$new_versions" >"$VERSIONS"
  [[ -n "$new" ]] && ok "Installed: $(paste -sd' ' <<<"$new" | sed 's/ /, /g')"
  [[ -n "$gone" ]] && ok "Removed: $(paste -sd' ' <<<"$gone" | sed 's/ /, /g')"
  [[ -n "$updated" ]] && ok "Updated: $updated"
  if [[ -z "$new" && -z "$gone" && -z "$updated" ]]; then
    if [[ $changed -eq 1 && -n "$before" ]]; then
      ok "Refreshed: same versions, with newer libraries underneath."
    else
      ok "Up to date: $(wc -l < <(printf '%s\n' "$after" | grep .)) package(s) on the list."
    fi
  fi
  write_hooks
  if [[ -n "$new" && -n "$info_all" ]]; then
    report_extras "$new" "$info_all" || true
  fi
  return 0
}

# After a failed build: the common reason in plain words. Nothing is
# installed or removed when the build fails.
explain_build_failure() {
  local log="$1" sub names
  printf '\n'
  if grep -q "conflicting subpath" "$log"; then
    # The two store paths quoted after the message: /nix/store/HASH-NAME/SUBPATH
    mapfile -t names < <(grep -o "/nix/store/[a-z0-9]\{32\}-[^/'\`]*/[^'\`]*" "$log" | head -n 2)
    sub=$(sed 's|^/nix/store/[^/]*/||' <<<"${names[0]:-}")
    printf '%sTwo packages on the list both have %s:%s\n' "$BAD" "${sub:-the same file}" "$R"
    for n in "${names[@]}"; do
      n=${n#/nix/store/*-}
      say "  ${n%%/*}"
    done
    say "Keep just one of them on the list."
  else
    printf '%sThe list didn'\''t build (Nix'\''s error is above).%s\n' "$BAD" "$R"
  fi
}

cmd_add() {
  [[ $# -gt 0 ]] || die "add what? e.g. nti add ripgrep"
  ensure_file
  local info a added=0 backup new=()
  say "${D}Looking them up in nixpkgs...${R}"
  info=$(info_json "$@") || die "couldn't read nixpkgs ($NIXPKGS)."
  backup=$(cat "$FILE")
  for a in "$@"; do
    if on_list "$a"; then
      note "$a is already on the list."
    elif [[ $(jq -r --arg a "$a" '.[$a].ok' <<<"$info") != true ]]; then
      printf '%sCan'\''t add %s:%s\n' "$BAD" "$a" "$R"
      why_not "$a" | sed 's/^/  /'
    else
      file_add "$a"
      added=1
      new+=("$a")
      say "Added $B$a$R $(jq -r --arg a "$a" '.[$a].version' <<<"$info")"
    fi
  done
  if [[ $added -eq 1 ]] && ! cmd_sync; then
    printf '%s\n' "$backup" >"$FILE"
    note "So $(printf '%s, ' "${new[@]}" | sed 's/, $//') went back off the list, and nothing was installed."
    return 1
  fi
  return 0
}

cmd_drop() {
  [[ $# -gt 0 ]] || die "drop what? e.g. nti drop ripgrep"
  ensure_file
  local a dropped=0 backup
  backup=$(cat "$FILE")
  for a in "$@"; do
    if on_list "$a"; then
      file_drop "$a"
      dropped=1
    elif synced_attrs | grep -qxF -- "$a"; then
      dropped=1 # off the list already, still installed: the sync removes it
    else
      note "$a isn't on the list."
    fi
  done
  if [[ $dropped -eq 1 ]] && ! cmd_sync; then
    printf '%s\n' "$backup" >"$FILE"
    note "The list is back as it was; nothing was removed."
    return 1
  fi
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
  if [[ -z "$rows" && -z "$(pending_removals)" ]]; then
    say "Nothing on the list. Add something with ${B}nti add PKG${R}."
    return 0
  fi
  info=$(info_json $(cut -f1 <<<"$rows")) || info='{}'
  cfg=$(config_paths)
  list_rows "$rows" "$info" "$cfg" | column -t -s $'\t'
  if out_of_sync; then
    printf '\nThe list changed since the last sync.\n%sRun nti sync to install and remove what it says.%s\n' "$WARN" "$R"
  fi
}

# What the last sync installed, one attr per line.
synced_attrs() { grep . "$SYNCED" 2>/dev/null | sort -u || true; }

# Installed by the last sync, but not on the list any more.
pending_removals() { comm -23 <(synced_attrs) <(attrs | sort -u); }

# The list and what's installed differ (a hand edit not synced yet).
out_of_sync() { [[ "$(synced_attrs)" != "$(attrs | sort -u)" ]]; }

# One line per package: name, version, age, note, description.
list_rows() {
  local rows="$1" info="$2" cfg="$3" a d days age ver desc out flag today synced
  today=$(date +%s)
  synced=$(synced_attrs)
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
    elif ! grep -qxF -- "$a" <<<"$synced"; then
      flag="to install"
    elif [[ -n "$out" ]] && grep -qxF -- "$out" <<<"$cfg"; then
      flag="in config"
    else
      flag="on trial"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$a" "${ver:--}" "$age" "$flag" "${desc:0:60}"
  done < <(grep . <<<"$rows" || true)
  while read -r a; do
    [[ -n "$a" ]] && printf '%s\t-\t-\tto remove\t(off the list, still installed until you sync)\n' "$a"
  done < <(pending_removals)
}

cmd_edit() {
  ensure_file
  local before after
  before=$(attrs)
  "${VISUAL:-${EDITOR:-nano}}" "$FILE"
  after=$(attrs)
  if [[ "$before" == "$after" ]]; then
    note "No change to the list."
  elif ! cmd_sync; then
    note "Your edit is saved but not installed. Fix the list ('nti edit') and it will be."
    return 1
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
        --footer "  Enter:add   Tab:mark (and move down) to add several   Esc:back" |
      awk '{print $1}'
  ) || return 0
  [[ -n "$picked" ]] || return 0
  # Tab marks a line and moves down, so moving with Tab marks everything it
  # passes: check before adding several.
  if [[ $(wc -l <<<"$picked") -gt 1 ]]; then
    printf '\nAdd these %s?\n' "$(wc -l <<<"$picked")"
    sed 's/^/  /' <<<"$picked"
    read -rp "[y/N] " yn
    [[ "$yn" == [yY]* ]] || { note "Nothing added."; pause; return 0; }
  fi
  # shellcheck disable=SC2086
  cmd_add $picked || true
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
        if [[ -n "$rows" || -n "$(pending_removals)" ]]; then
          list_rows "$rows" "$info" "$cfg" | column -t -s $'\t'
        else
          printf 'PACKAGE\n(nothing yet: press a to add something)\n'
        fi
      } | fzf --style full --layout reverse --multi --no-input --ansi \
        --header-lines 1 --header-first \
        --header "Programs on trial, no rebuild needed.  List: ${FILE/#$HOME/\~}$(out_of_sync && printf '\n%s\n%s' "The list changed since the last sync." "${WARN}Press s to install and remove what it says.${R}")" \
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
      d) [[ -n "$picked" ]] && { cmd_drop $picked || true; pause; } ;;
      t) [[ -n "$picked" ]] && { cmd_try "$(head -n1 <<<"$picked")"; } ;;
      k) [[ -n "$picked" ]] && { printf '\n'; cmd_adopt $picked; pause; } ;;
      e) cmd_edit || true; pause ;;
      s) printf '\n'; cmd_sync || true; pause ;;
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
  hooks|setup)   shift; cmd_hooks ;;
  path)          say "$FILE" ;;
  help|-h|--help) usage ;;
  --version)     say "nti $VERSION" ;;
  *)             usage >&2; exit 1 ;;
esac
