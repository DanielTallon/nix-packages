#!/usr/bin/env bash
# Checks that every fixture is recognised by the expected rule, and that the report contains
# each "# expect-output: <text>" line of its case.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
py=python3; command -v python3 >/dev/null || py="nix shell nixpkgs#python3 -c python3"
pass=0 fail=0
for f in "$here"/fixtures/*.txt; do
  name=$(basename "$f" .txt)
  case=$here/cases/$name.nix
  expect=$(sed -n 's/^# expect: //p' "$case" 2>/dev/null)
  expect=${expect:-${name%%--*}}
  got=$($py "$here/../nixed_error.py" --rule-id --flake "$here/.work/$name" "$f" | cut -d' ' -f1)
  ok=1
  if [ "$got" != "$expect" ]; then ok=0; echo "FAIL $name: expected $expect, got $got"; fi
  if grep -q '^# expect-output: ' "$case" 2>/dev/null; then
    report=$(NO_COLOR=1 $py "$here/../nixed_error.py" --flake "$here/.work/$name" "$f" | tr -s ' \n' ' ')
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
