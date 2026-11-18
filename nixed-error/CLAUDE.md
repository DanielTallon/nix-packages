# nixed-error

Working title. It explains failed NixOS rebuilds in plain words: the file and line, whose fault it is
(your config / upstream / your machine), and how to fix it. It uses rule-based matching only, with no LLM
and no network. It was called `nix-helper` early on; that name was dropped because it was too close to `nh`.

## Status and constraints

- This folder lives in the user's nix-packages repo (`~/Develop/nix-packages/nixed-error`,
  github:DanielTallon/nix-packages). The flake builds it from `nixed-error.nix` here, and on a fresh VM it runs
  with `nix run github:DanielTallon/nix-packages#nixed-error`. The user commits and pushes that repo themselves.
- The user tests against their real config, `~/.dotfiles` (flake, host `nixos`, `NH_OS_FLAKE=/home/fredrick/.dotfiles#nixos`,
  Nix 2.34, uses `nh` and nixd). They break something on purpose, run `nh os build` and then `nixed-error`,
  and paste both outputs. For each miss: add or improve a rule, add a test case, run the tests.
  Only read `~/.dotfiles` files the user points to; never edit them.
- The "pipe it in" hint says `nixed-error` only if it's on PATH; else `$NIXED_ERROR_RUN` (the package's wrapper sets it to
  the nix-packages `nix run` command), else a `nix run <flake>#nixed-error` placeholder.
- Not installed on the user's PATH; they run it with `nix run /home/fredrick/Develop/nix-packages#nixed-error`
  (piped: `nh os build 2>&1 | nix run /home/fredrick/Develop/nix-packages#nixed-error`).
- Python isn't on the system PATH. Use `nix shell nixpkgs#python3 -c python3 nixed_error.py ...`.

## Layout

- `nixed_error.py`: the whole tool (Python 3.11+ stdlib only).
  - Input: a file argument, piped stdin, or nothing. `find_config()` picks the config (a `Config`: flake or
    classic configuration.nix): `--config`/`--flake`, `$NH_OS_FLAKE`/`$NH_FLAKE`/`$FLAKE`, `$NIXOS_CONFIG`,
    `/etc/nixos/flake.nix`, `nixos-config` in `$NIX_PATH`, `/etc/nixos/configuration.nix`; else it says so
    (exit 2). With no input, `reproduce()` runs `nix build --dry-run --show-trace` on the flake, or
    `nix-build '<nixpkgs/nixos>' -I nixos-config=<file>` for a classic config. If that evaluates, it looks for a failed
    build log in `/nix/var/log/nix/drvs` (`failed_build()`: only logs whose last 25 lines show an error count; Nix also
    keeps logs of builds it cut off, often empty, and a batch of only those means an interrupted build, which the
    "Couldn't reproduce" message then mentions), then for failed systemd units (it emits `error: [user ]unit X failed`; the
    `unit` handler reads the journal itself). Classic configs were tested on a fresh NixOS VM without flakes
    (2026-10-13), run with `nix run github:DanielTallon/nix-packages#nixed-error`: unknown name, option typo,
    missing `;`, wrong type and a failing oneshot service (re-check and piped) all worked. Removing a failed service's definition and switching cleared the unit there, so the leftover path is rare.
  - `analyze()` splits the output into `error:` blocks, picks the best-matching rule (highest
    `priority`, then user rules, then the later block), and finds the suspect location. The order is: the rule's
    `locate` text searched in the user's files, then Nix's own location if it's in the user's files, then
    "Definition values" files, then the deepest user frame in the trace.
  - `Flake.origin()` classifies paths as yours or upstream (flake dir, the flake's store copy, inputs from
    `nix flake archive --json --dry-run`, `«github:…»`/`«https://…»` sources).
  - `HANDLERS`: rule-specific detective work. `semicolon`, `brackets`, `stray_closer`, `semicolon_inside`,
    `equals_inside` and `bare_word` handle syntax and use the small tokenizer `scan_brackets()` / `open_at()`
    (which brackets are open at Nix's error position). `duplicate_attr` (`attribute 'x' already defined`, a parse
    error, so `lib.mkForce` can't help) shows both copies and suggests deleting the one indented less than its block
    (a pasted snippet), and lists the file's other repeats, since Nix stops at the first. `repeated_settings()`
    finds them line by line with Nix's merge rules: two `name = {` blocks merge, a value set twice doesn't.
    A pasted `name = { … }` block whose settings all repeat others with the same value is offered as one deletion.
    `unknown_name` suggests close names from the flake's
    nixpkgs (`builtins.attrNames`). `removed_pkg` writes different advice for a removed package used
    directly (`pkgs.foo`) and one pulled in by enabling a module (`programs.foo`, which can't just be
    renamed to the replacement). `missing_module` handles flake-parts modules (`config.flake.modules.nixos.foo`)
  that nothing defines: it checks for a defining file that is untracked, outside the import-tree folders, deleted
  or moved (git status), deleted in an old commit, or an untracked file named after the module that doesn't define it
  yet (e.g. a new `fake.nix` holding only a placeholder), else suggests close names. The others are `module_arg`,
  `assertion`, `build` (your own package; a nixpkgs package you `override`/`overrideAttrs`, pointing at the
  override line or the line the log's last output comes from; else upstream; `trace_build()` runs `nix why-depends
  --derivation` from the system's (or the outermost failed) .drv to show the chain, naming collectors like
  `home-manager-path` by their option, and points at the package your files install, else at the module that makes
  the derivation (searched in the inputs' `modules/`) and where you set its `cfg = config.<option>`) and `hm_file` (every file home-manager says is in the way, the leftover backup's date, and a rerun command). `unfree` points at an `allowUnfree = false` line (or an `allowUnfreePredicate`) and
  at what pulls the package in, including drivers that never name it (`videoDrivers = [ "nvidia" ]`). For a
  package from a second set (`pkgs-stable.foo`), it follows the set back to its `import nixpkgs { config… }`,
  which `nixpkgs.config` doesn't reach, and points at that import's own setting (or its missing `config`).
  `insecure` quotes nixpkgs' "Known issues", points at what pulls the package in (else blames a dependency), and for
  a discontinued package says to remove it rather than permit it (`permittedInsecurePackages` names one exact version).
  `broken` (both the old "is marked as broken" and the newer "has problems: - broken:" wording) quotes the package's
  own `broken = …` condition from the nixpkgs source, and follows the trace's `while evaluating derivation` frames
  (outermost first, skipping unversioned NixOS wrappers like `man-paths`) to the first package your files name, so
  a broken dependency is traced to what you installed (`mcp-nixos` > `fastmcp` > `fastmcp-slim`). It suggests removing
  that, pinning it from the nixpkgs revision before your last update (`older_nixpkgs()`, from flake.lock's git
  history), or waiting; the `problems.handlers` override comes last, as a long shot.
  `option_type` compares what a typed option wants (`boolean`, `list of …`, `string…`, `null or …` stripped) with
  the value under "Definition values:" and, when clear, prints the corrected line (`"yes"` → `true`, `[ "x" ]` → `"x"`). For an enum (`one of …`) given a value of the right kind, the headline says the value isn't allowed, and `closest_value()` suggests a same-letters-other-case match, else one within one or two typos (OSA distance).
  `unit` handles a failed systemd unit (from the re-check, or piped `nixos-rebuild` output with
  `the following units failed:`): the program's own journal lines as the log (`journalctl -o short-unix`, else the
  `systemctl status` lines in the text), the exit status in words (`203/EXEC`, exit code, OOM, timeout,
  start limit), and where it comes from. `unit_defined_in()` asks the config itself
  (`options.systemd.services.definitionsWithLocations`, filtered to the unit, ~0.5 s with the eval cache) which files
  define it: a module in an input (blamed upstream, `Whose:` names the input, `module_switch()` finds the option it
  hangs on, `cfg = config.…` before `mkIf config.….enable`, and where you set it, else the `inputs.<x>.…Modules`
  import line), or your own file (pointing at its `ExecStart`/`script`; replacing the command makes it yours even if
  a module makes it). Without an answer it falls back to name matching (`systemd.services.<name>`,
  `services.<name>.enable`). Then when it failed: during the piped switch, during the last switch (`/run/current-system`'s
  mtime), earlier, or left over (`LoadState=not-found` and nothing in the config names it). If nothing is failed now,
  `recovered_unit()` reads the journal for a unit still failed when the last switch ended but restarted fine since
  (`Restart=on-failure`), and the report explains the failed run. A network error in its log (a timer catching up
  at boot, before DNS) suggests `wants`/`after = [ "network-online.target" ]`. Its quote is labelled
  "What systemd said". A `Driver/library version mismatch` in the log (the update changed the NVIDIA driver but the
  old kernel module is still loaded) is blamed on the machine instead: it points at `videoDrivers`, shows the loaded
  vs. new version (`/proc/driver/nvidia/version`, `NVML library version:`), and says to `nh os boot` (or
  `nixos-rebuild boot`) and reboot, not to touch the service. No `--update`: the switch already used the new
  nixpkgs, and updating again could bring yet another driver.
- `rules.toml`: 51 rules. The header documents every field. Templates use `{{var}}` (named regex groups
  plus handler-set vars). Regexes go in `'''literal strings'''`. Single newlines in texts are re-wrapped,
  blank lines separate paragraphs, and indented lines are printed as-is.
- User rules: `~/.config/nixed-error/rules.toml` (same `id` replaces a built-in). Unrecognised errors are
  saved to `~/.local/state/nixed-error/unknown/`.
- `nixed-error.nix`: the package, called from the repo's `flake.nix` (`makeWrapper` around python3; rules.toml installed next to the script).

## Tests

- `tests/cases/<rule-id>.nix` (or `<rule-id>--variant.nix`): a broken NixOS module. Headers: `# mode: build`
  (build `system.build.nixedErrorCase` instead of evaluating), `# untracked` (adds a file without
  `git add`; `# untracked: <path> <text>` creates that file instead), `# deleted: <path> <text>` (git-adds a file, then deletes it), `# mode: captured` (the fixture is real output
  saved by hand, e.g. home-manager activation, which a throwaway flake can't produce; make-fixtures leaves it alone, and turns the case's non-comment lines, if any, into `.work/<case>/configuration.nix` for the report to search),
  `# mode: classic` (a plain configuration.nix in a folder with no flake and no git, nixpkgs through a
  channel-style symlink), `# expect: <rule-id>`, `# expect-output: <text>` (may repeat; the full
  report must contain the text, with whitespace squeezed, so wrapped lines still match).
- `tests/make-fixtures.sh [case ...]` builds each case in a throwaway git flake under `tests/.work/` (gitignored)
  and saves Nix's real output to `tests/fixtures/`. Rerun it after a Nix upgrade to catch wording changes.
- `tests/run-tests.sh` checks that each fixture is matched by the expected rule and has its expected output (currently 63/63, including two checks of finding the config and two of picking the failed build log).
  Also eyeball the full report: `nix shell nixpkgs#python3 -c python3 nixed_error.py --flake tests/.work/<case> tests/fixtures/<case>.txt`.

## Lessons from testing

- Trust Nix's error position. Earlier, a whole-file bracket scan jumped to a later, unrelated line.
  Only move away from Nix's line for a problem found *before* it.
- Nix's wording misleads: "expecting ';'" is often a missing `[`/`]`, and the reported line is
  often one after the real mistake. Look at what's open at the error position before trusting the words.
- Pass-through options (`programs.*.settings`, `extraOpts`, `extraConfig`) accept any key, so typos there
  are not Nix errors at all. Example: `programs.gamemode.settings.general.rencie` built fine.

- A plain-text `locate` of a bare name matches too early (`cavalier` hit `flake.modules.nixos.cavalier`
  on line 4 instead of `programs.cavalier` on line 46). Look for real uses first (`pkgs.foo`,
  `{{pkg_option}}`), then the name as a whole word (`locate_regex`).
- home-manager (as a NixOS module) only touches files during activation, so `nh os build` never shows its
  errors, and `nh os switch` with no config change doesn't restart `home-manager-<user>.service` either.
  To test or retry: `sudo systemctl restart home-manager-<user>.service`. The user's config sets
  `backupFileExtension`, so a file in the way only fails when an old `.backup` already exists
  (`Existing file 'X.backup' would be clobbered by backing up 'X'`: the file in the way is X, not the backup).

## Ideas put off for later

- Scan every `.nix` file with `nix-instantiate --parse` to report several syntax errors at once
  (Nix itself stops at the first error).
- Explain every failed package when a build fails with `--keep-going`, not just the latest.
- Catch typos in pass-through settings (needs per-program key lists, or checking program logs after switching).
- Untested against real errors so far: conflicts. The unit handler's "failed before your last switch" and leftover
  paths depend on the machine's systemd state, so no fixture covers them.
- Find a better name.
