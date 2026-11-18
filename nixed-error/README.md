# nixed-error

Explains a failed NixOS rebuild in plain words: what went wrong, the file and line, whether it's
**your config**, **upstream** (nixpkgs or another input), or **your machine** (disk, network), and how to fix it.

No LLM and no network. It matches Nix's output against a list of known errors in `rules.toml`
and does a bit of detective work: finding the real line of a missing `;`, the unclosed `{`, which
file sets a conflicting option, and whether a failed package is yours or from nixpkgs.

## Usage

```bash
nixed-error                         # re-evaluates your config and explains what fails
nixed-error --config ~/nixos#host   # ...a config somewhere else (flake folder, or a configuration.nix)
nh os switch 2>&1 | nixed-error     # explain output you pipe in
nixed-error saved-output.log        # explain a saved log
nixed-error -v                      # also show Nix's full message and a longer build log
nixed-error --list-rules            # every error it knows
```

With no input, it does a cheap `nix build --dry-run` of your system. Evaluation errors come back
right away. If evaluation succeeds, it finds the package that failed from the build log Nix keeps.
If that also succeeds, it looks at failed systemd units (e.g. home-manager activation).
home-manager only runs on `switch`, so `nh os build` can't show its errors.

It works with flakes and with a plain `configuration.nix`. Without `--config`, it looks in this order:
`$NH_OS_FLAKE` / `$NH_FLAKE` / `$FLAKE` (set for nh), `$NIXOS_CONFIG`, a `flake.nix` in `/etc/nixos`,
`nixos-config` in `$NIX_PATH`, then `/etc/nixos/configuration.nix`. If you use `nixos-rebuild --flake`
with a flake outside `/etc/nixos`, pass `--config` (or set `NH_OS_FLAKE`).

## Install

It lives in the [nix-packages](..) repo. Try it without installing:

```bash
nix run github:DanielTallon/nix-packages#nixed-error
```

To install, add `inputs.nix-packages.url = "github:DanielTallon/nix-packages";` to your flake inputs, then add
`inputs.nix-packages.packages.${pkgs.stdenv.hostPlatform.system}.nixed-error` to `environment.systemPackages`.

## Teaching it new errors

When it meets an error it doesn't know, it shows the cleaned-up message and saves the raw output to
`~/.local/state/nixed-error/unknown/`. To teach it, add a rule to `~/.config/nixed-error/rules.toml`
(same format as `rules.toml`; a rule with the same `id` replaces a built-in one):

```toml
[[rule]]
id = "my-new-error"
title = "Short headline"
match = '''regex with (?P<thing>named groups)'''
priority = 70             # highest matching rule wins
blame = "you"             # you | upstream | system | auto
locate = ["{{thing}}"]    # text to search for in your .nix files to find the line
explain = "What happened, using {{thing}}, {{file}}, {{line}}."
fix = "What to do."
```

Read the top of `rules.toml` for every field.

## Tests

Each file in `tests/cases/` is a small broken NixOS module. `tests/make-fixtures.sh` builds each one in a
throwaway flake and saves what your Nix prints to `tests/fixtures/`. `tests/run-tests.sh` checks that
each fixture is recognised by the right rule. To cover a new error, add a case, regenerate it, and
run the tests. Re-running `make-fixtures.sh` after a Nix upgrade shows whether the wording changed.
