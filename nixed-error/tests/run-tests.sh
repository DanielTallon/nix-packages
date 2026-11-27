#!/usr/bin/env bash
# Checks that every fixture is recognised by the expected rule, and that the report contains
# each "# expect-output: <text>" line of its case.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
py=python3; command -v python3 >/dev/null || py="nix shell nixpkgs#python3 -c python3"
pass=0 fail=0

# Captured fixtures name the nixpkgs source they were made with (/nix/store/…-source), and some reports quote it
# (broken--dependency's `broken = …` line). Garbage collection removes it, so fetch it back (same narHash, same
# path) and keep it with a GC root in .work/.
for f in $(grep -l '^# mode: captured' "$here"/cases/*.nix); do
  fx=$here/fixtures/$(basename "$f" .nix).txt
  [ -f "$fx" ] || continue
  for rev in $(grep -o 'github:NixOS/nixpkgs/[0-9a-f]\{40\}' "$fx" | sort -u); do
    root=$here/.work/gcroots/${rev##*/}
    [ -e "$root" ] && continue
    path=$(nix --extra-experimental-features 'nix-command flakes' flake prefetch --json "$rev" 2>/dev/null \
      | sed -n 's/.*"storePath":"\([^"]*\)".*/\1/p')
    if [ -n "$path" ]; then
      mkdir -p "${root%/*}"
      nix-store --add-root "$root" --realise "$path" >/dev/null
    else
      echo "note: couldn't fetch $rev for $(basename "$fx") (offline?); its report may lack nixpkgs quotes"
    fi
  done
done

# Build-mode fixtures name .drv files that reports look up (`nix why-depends`). make-fixtures.sh GC-roots them;
# put back a root that's missing (made before roots existed) or whose .drv was collected anyway.
# Re-instantiating the same .work flake (same flake.lock) gives the same .drv path.
for f in $(grep -l '^# mode: build' "$here"/cases/*.nix); do
  name=$(basename "$f" .nix) root=$here/.work/gcroots/$name.drv
  [ -d "$here/.work/$name" ] || continue
  [ -e "$root" ] && continue  # -e follows the link: false if it's gone or points at a deleted .drv
  mkdir -p "${root%/*}"
  nix-instantiate --add-root "$root" --expr \
    "(builtins.getFlake \"path:$here/.work/$name\").nixosConfigurations.testhost.config.system.build.nixedErrorCase" \
    >/dev/null 2>&1 || echo "note: couldn't GC-root $name's .drv (rerun make-fixtures.sh $name)"
done

for f in "$here"/fixtures/*.txt; do
  name=$(basename "$f" .txt)
  case=$here/cases/$name.nix
  expect=$(sed -n 's/^# expect: //p' "$case" 2>/dev/null)
  expect=${expect:-${name%%--*}}
  got=$($py "$here/../nixed_error.py" --rule-id --flake "$here/.work/$name" "$f" | cut -d' ' -f1)
  ok=1
  if [ "$got" != "$expect" ]; then ok=0; echo "FAIL $name: expected $expect, got $got"; fi
  if grep -q '^# expect-output: ' "$case" 2>/dev/null; then
    report=$(NO_COLOR=1 $py "$here/../nixed_error.py" --flake "$here/.work/$name" --host testhost "$f" | tr -s ' \n' ' ')
    while IFS= read -r want; do
      [[ $report == *"$want"* ]] || { ok=0; echo "FAIL $name: report lacks: $want"; }
    done < <(sed -n 's/^# expect-output: //p' "$case")
  fi
  if [ $ok = 1 ]; then pass=$((pass+1)); else fail=$((fail+1)); fi
done

# Finding the config with no input: --config at a plain configuration.nix folder must re-evaluate that
# folder (not whatever $NIX_PATH names), and a folder with no config must say so.
check() {  # name, expected text, command...
  local name=$1 want=$2; shift 2
  local out; out=$("$@" </dev/null 2>&1 | tr -s ' \n' ' ')
  if [[ $out == *"$want"* ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $name: lacks: $want"; fi
}
classic=$here/.work/option-not-exist--classic
if [ -d "$classic" ]; then
  check config-classic "re-evaluated $classic/configuration.nix" env NO_COLOR=1 $py "$here/../nixed_error.py" --config "$classic"
fi
empty=$(mktemp -d)
check config-missing "$empty (from --config) has no flake.nix or configuration.nix" env NO_COLOR=1 $py "$here/../nixed_error.py" --config "$empty"
rmdir "$empty"

# Picking the failed build from Nix's kept logs: a log ending in an error wins over builds Nix cut off
# (empty or unfinished logs closed just after it), and cut-off builds alone are not a failure.
logs=$(mktemp -d)
picked=$($py -c '
import os, sys, pathlib; sys.path.insert(0, sys.argv[1]); import nixed_error as n
n.NIX_LOG_DIR = d = pathlib.Path(sys.argv[2])
for name, log, t in [("aaa-bad", "compiling\nerror: oops\n", 100), ("bbb-cut", "", 101), ("ccc-cut", "building\n", 102)]:
    (d / name[:2]).mkdir(exist_ok=True); f = d / name[:2] / (name[2:] + ".drv"); f.write_text(log); os.utime(f, (t, t))
drv, cut = n.failed_build([f"/nix/store/{x}.drv" for x in ("aaa-bad", "bbb-cut", "ccc-cut")])
print("failed=" + pathlib.Path(drv).name if drv else "none")
drv, cut = n.failed_build([f"/nix/store/{x}.drv" for x in ("bbb-cut", "ccc-cut")])
print("cut-only", drv, len(cut))' "$here/.." "$logs" 2>&1)
check build-log-failed "failed=aaa-bad.drv" echo "$picked"
check build-log-cut-off "cut-only None 2" echo "$picked"
rm -rf "$logs"

echo "$pass passed, $fail failed"
[ $fail -eq 0 ]
