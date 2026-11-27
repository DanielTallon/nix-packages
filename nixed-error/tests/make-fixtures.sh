#!/usr/bin/env bash
# Rebuilds tests/fixtures/<case>.txt from tests/cases/<case>.nix.
# Each case is a NixOS module dropped into a throwaway flake (tests/.work/<case>), so the
# fixture is exactly what your Nix prints. Usage: tests/make-fixtures.sh [case ...]
# Case headers:  "# mode: build"  build system.build.nixedErrorCase instead of evaluating
#                "# untracked"    create hosts/untracked.nix without git-adding it
#                "# untracked: <path> <text>"  create that file without git-adding it
#                "# deleted: <path> <text>"  git-add a file with that text, then delete it (a moved file)
#                "# mode: captured"  real output saved by hand (e.g. home-manager activation); left alone.
#                                    Its non-comment lines, if any, become .work/<case>/configuration.nix
#                "# mode: classic"  a plain configuration.nix (no flake, no git), nixpkgs from a channel
#                "# expect: id"   expected rule id (default: the file name)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
export here work=$here/.work
mkdir -p "$here/fixtures" "$work"
# classic cases get nixpkgs through this channel-style symlink (made once, before cases run in parallel)
mkdir -p "$work/_channels"; [ -e "$work/_channels/nixos" ] || ln -s "$(nix-instantiate --find-file nixpkgs)" "$work/_channels/nixos"

one() {
  local name=$1 dir=$work/$1 case=$here/cases/$1.nix
  if grep -q "^# mode: captured" "$case"; then
    # The case's non-comment lines, if any, become the config the report searches (a configuration.nix).
    if grep -qv '^#' "$case"; then
      rm -rf "$dir"; mkdir -p "$dir"; grep -v '^#' "$case" > "$dir/configuration.nix"
    fi
    echo "-- $name is captured by hand, kept"; return
  fi
  if grep -q "^# mode: classic" "$case"; then
    # A plain configuration.nix, no flake and no git, with nixpkgs from a channel-style symlink,
    # like a fresh NixOS install.
    rm -rf "$dir"; mkdir -p "$dir"
    cat > "$dir/configuration.nix" <<'EOF'
{ ... }:
{
  imports = [ ./case.nix ];
  boot.loader.grub.device = "nodev";
  fileSystems."/" = { device = "/dev/sda1"; fsType = "ext4"; };
  system.stateVersion = "26.05";
}
EOF
    cp "$case" "$dir/case.nix"
    if nix-build '<nixpkgs/nixos>' -A system --dry-run --show-trace -I "nixos-config=$dir/configuration.nix" \
         -I "nixpkgs=$work/_channels/nixos" > "$here/fixtures/$name.txt" 2>&1; then
      echo "!! $name did not fail"
    else
      echo "ok $name"
    fi
    return
  fi
  rm -rf "$dir"
  mkdir -p "$dir/hosts"
  cat > "$dir/flake.nix" <<'EOF'
{
  inputs.nixpkgs.url = "nixpkgs";
  outputs = { nixpkgs, ... }: {
    nixosConfigurations.testhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ ./hosts/base.nix ./hosts/case.nix ];
    };
  };
}
EOF
  cat > "$dir/hosts/base.nix" <<'EOF'
{ ... }:
{
  boot.loader.grub.device = "nodev";
  fileSystems."/" = { device = "/dev/sda1"; fsType = "ext4"; };
  system.stateVersion = "26.05";
}
EOF
  cp "$case" "$dir/hosts/case.nix"
  printf '{ ... }: { }\n' > "$dir/hosts/ssh-extra.nix"
  local deleted=()
  while read -r path text; do
    mkdir -p "$(dirname "$dir/$path")"
    printf '%s\n' "$text" > "$dir/$path"
    deleted+=("$dir/$path")
  done < <(sed -n 's/^# deleted: //p' "$case")
  git -C "$dir" init -q
  git -C "$dir" add -A
  [ ${#deleted[@]} -gt 0 ] && rm -f "${deleted[@]}"
  grep -qx '# untracked' "$case" && printf '{ ... }: { }\n' > "$dir/hosts/untracked.nix"
  while read -r path text; do
    mkdir -p "$(dirname "$dir/$path")"; printf '%s\n' "$text" > "$dir/$path"
  done < <(sed -n 's/^# untracked: //p' "$case")
  local attr="$dir#nixosConfigurations.testhost.config.system.build"
  local cmd=(nix build --dry-run --show-trace "$attr.toplevel")
  grep -q '^# mode: build' "$case" && cmd=(nix build --no-link --show-trace "$attr.nixedErrorCase")
  if "${cmd[@]}" > "$here/fixtures/$name.txt" 2>&1; then
    echo "!! $name did not fail"
  else
    echo "ok $name"
  fi
  grep -q '^# mode: build' "$case" && root_drv "$name"
  return 0
}
export -f one

# A failed build leaves no output to keep its .drv alive, so garbage collection deletes it, and reports
# that run `nix why-depends` on it (build-failure--chain) lose their chain. Root it in .work/gcroots/
# (a .drv root keeps the .drv files it depends on too). run-tests.sh calls this again for missing roots.
root_drv() {
  mkdir -p "$work/gcroots"
  nix-instantiate --add-root "$work/gcroots/$1.drv" --expr \
    "(builtins.getFlake \"path:$work/$1\").nixosConfigurations.testhost.config.system.build.nixedErrorCase" \
    >/dev/null 2>&1 || echo "note: couldn't GC-root $1's .drv"
}
export -f root_drv

if [ $# -gt 0 ]; then cases=("$@"); else cases=($(cd "$here/cases" && ls *.nix | sed 's/\.nix$//')); fi
printf '%s\n' "${cases[@]}" | xargs -P 4 -I{} bash -c 'one {}'
