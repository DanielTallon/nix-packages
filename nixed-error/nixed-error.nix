# nixed-error — single-file package.
#
# Explains failed NixOS rebuilds in plain words. The tool (nixed_error.py) and
# its rule list (rules.toml) are embedded below as Nix indented strings and
# installed side by side, because the script looks for rules.toml next to itself:
#
#   $out/bin/nixed-error                        (python3 wrapper)
#   $out/share/nixed-error/nixed_error.py
#   $out/share/nixed-error/rules.toml
#
# The source of truth lives in the nixed-error project; this file is generated
# from it. Regenerate instead of editing the embedded text by hand.
#
# EDITING NOTE — Nix indented-string escaping inside the embedded bodies:
#   ${      is written  ''${
#   ''      is written  '''
#   '${     is written  ''\'''${
# Everything else is literal.

{ lib, stdenvNoCC, makeWrapper, writeText, python3, git }:

let
  # --- share/nixed-error/nixed_error.py: the whole tool (stdlib only) -------
  script = writeText "nixed_error.py" ''
    #!/usr/bin/env python3
    """nixed-error: explain a failed NixOS rebuild in plain words.

    Pure pattern matching against rules.toml. No network, no LLM.

        nixed-error                       re-run the evaluation of your config and explain what fails
        nh os switch 2>&1 | nixed-error   explain output you piped in
        nixed-error build.log             explain a saved log
    """
    from __future__ import annotations

    import argparse
    import bz2
    import difflib
    import json
    import os
    import re
    import shutil
    import socket
    import subprocess
    import sys
    import textwrap
    import threading
    import time
    import tomllib
    from dataclasses import dataclass, field
    from pathlib import Path

    VERSION = "0.1.0"
    HERE = Path(__file__).resolve().parent
    BUILTIN_RULES = Path(os.environ.get("NIXED_ERROR_RULES", HERE / "rules.toml"))
    CONFIG_HOME = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    STATE_HOME = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state"))
    USER_RULES = CONFIG_HOME / "nixed-error" / "rules.toml"
    UNKNOWN_DIR = STATE_HOME / "nixed-error" / "unknown"
    NIX_LOG_DIR = Path("/nix/var/log/nix/drvs")

    ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07")
    BOX_PREFIX_RE = re.compile(r"^[─-╿ ]*(?=[─-╿])[─-╿]+ ?", re.M)
    ERROR_LINE_RE = re.compile(r"^\s*error:\s?(.*)$")
    LOC_RE = re.compile(r"\bat (?P<loc>«[^»]*»[^\s:]*|/[^\s:]+):(?P<line>\d+):(?P<col>\d+)")
    DEF_FILE_RE = re.compile(r"^\s*- In `(?P<path>[^']+)'", re.M)
    SUGGEST_RE = re.compile(r"Did you mean (?P<s>[^\n]+?)\?$", re.M)
    OPTION_CTX_RE = re.compile(r"while evaluating the option `(?P<opt>[^']+)'")
    SNIPPET_RE = re.compile(r"^\s*\d*\s*\|")
    LOG_LINE_RE = re.compile(r"^\s*> ?(.*)$", re.M)
    TEMPLATE_RE = re.compile(r"\{\{(\w+)\}\}")
    STORE_PREFIX_RE = re.compile(r"^/nix/store/[a-z0-9]{32}-[^/]+/?")
    STORE_HASH_RE = re.compile(r"/nix/store/[a-z0-9]{32}-")


    # ─── where things live ───────────────────────────────────────────────────────


    @dataclass
    class Origin:
        owner: str  # "you" | "upstream" | "cli"
        label: str  # "your config", "nixpkgs", "home-manager", ...
        display: str  # path as shown to the user
        real: Path | None  # readable file, for code snippets


    @dataclass
    class Loc:
        origin: Origin
        line: int | None = None
        col: int | None = None

        def describe(self) -> str:
            return self.origin.display + (f", line {self.line}" if self.line else "")


    def under(p: Path, base: Path) -> str | None:
        try:
            return str(p.relative_to(base))
        except ValueError:
            return None


    class Flake:
        """Knows which paths are yours (the flake dir) and which belong to inputs."""

        def __init__(self, path: str | None, load_inputs: bool = True):
            self.dir: Path | None = None
            self.store: Path | None = None
            self.inputs: dict[str, Path] = {}
            self._files: list[Path] | None = None
            if path:
                p = Path(re.sub(r"^(path:|git\+file://)", "", path)).expanduser()
                if p.is_dir():
                    self.dir = p.resolve()
            if self.dir and load_inputs and (self.dir / "flake.nix").exists():
                self._load_inputs()

        def _load_inputs(self) -> None:
            try:
                out = subprocess.run(
                    ["nix", "--extra-experimental-features", "nix-command flakes",
                     "flake", "archive", "--json", "--dry-run", str(self.dir)],
                    capture_output=True, text=True, timeout=30,
                )
                data = json.loads(out.stdout)
            except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError):
                return
            self.store = Path(data["path"]) if data.get("path") else None

            def walk(inputs: dict, prefix: str) -> None:
                for name, info in inputs.items():
                    full = prefix + name
                    if info.get("path") and Path(info["path"]) not in self.inputs.values():
                        self.inputs[full] = Path(info["path"])
                    walk(info.get("inputs", {}), full + "/")

            walk(data.get("inputs", {}), "")

        def origin(self, raw: str) -> Origin:
            if raw.startswith("«"):
                inner, _, rest = raw[1:].partition("»")
                if inner == "string":
                    return Origin("cli", "command line", "(command line)", None)
                if inner.startswith("path:"):
                    raw = inner[5:].split("?")[0] + rest
                else:  # e.g. «github:NixOS/nixpkgs/abc123»/lib/modules.nix or «https://…/nixexprs.tar.zst?…»
                    url = inner.split("?")[0]
                    if "nixpkgs" in url or "nixexprs" in url:
                        label = "nixpkgs"
                    elif m := re.match(r"(?:github|gitlab|sourcehut):[^/]+/([^/]+)", url):
                        label = m[1]
                    else:
                        label = re.sub(r"^[\w+]+:(//)?", "", url).strip("/").split("/")[-1] or "a flake input"
                    return Origin("upstream", label, f"{label}: {rest.lstrip('/')}", None)
            p = Path(raw)
            if self.dir and (rel := under(p, self.dir)) is not None:
                return Origin("you", "your config", rel, p)
            if self.store and (rel := under(p, self.store)) is not None:
                real = self.dir / rel if self.dir and (self.dir / rel).exists() else p
                return Origin("you", "your config", rel, real)
            for name, base in self.inputs.items():
                if (rel := under(p, base)) is not None:
                    return Origin("upstream", name, f"{name}: {rel}", p if p.exists() else None)
            if raw.startswith("/nix/store/"):
                rel = STORE_PREFIX_RE.sub("", raw)
                if self.dir and rel and (self.dir / rel).is_file() and self._same_file(p, self.dir / rel):
                    return Origin("you", "your config", rel, self.dir / rel)
                label = "nixpkgs" if rel.split("/")[0] in ("nixos", "pkgs", "lib") else "a flake input"
                return Origin("upstream", label, f"{label}: {rel}", p if p.exists() else None)
            # Without flakes, nixpkgs comes from a channel: a symlink into the store
            # (/nix/var/nix/profiles/per-user/root/channels/nixos/..., ~/.nix-defexpr/channels/...).
            try:
                resolved = p.resolve()
            except OSError:
                resolved = p
            if str(resolved).startswith("/nix/store/") or "/channels/" in raw:
                rel = STORE_PREFIX_RE.sub("", str(resolved)) if str(resolved).startswith("/nix/store/") else raw
                if m := re.search(r"/channels/([^/]+)/(.*)", raw):
                    label, rel = m[1], m[2]
                    label = "nixpkgs" if label.startswith(("nixos", "nixpkgs")) else label
                else:
                    label = "nixpkgs" if rel.split("/")[0] in ("nixos", "pkgs", "lib") else "a channel"
                return Origin("upstream", label, f"{label}: {rel}", p if p.exists() else None)
            shown = "~/" + rel if (rel := under(p, Path.home())) else raw
            return Origin("you", "your config", shown, p if p.exists() else None)

        @staticmethod
        def _same_file(store: Path, mine: Path) -> bool:
            """Is this store path a copy of your file? (Lazy trees give virtual paths that don't exist.)"""
            try:
                return not store.exists() or store.read_bytes() == mine.read_bytes()
            except OSError:
                return False

        def files(self) -> list[Path]:
            if self._files is None:
                self._files = []
                if self.dir:
                    try:
                        out = subprocess.run(
                            ["git", "-C", str(self.dir), "ls-files", "-co", "--exclude-standard", "*.nix"],
                            capture_output=True, text=True, timeout=10, check=True,
                        )
                        self._files = [self.dir / f for f in out.stdout.splitlines()]
                    except (OSError, subprocess.SubprocessError):
                        self._files = [
                            f for f in self.dir.rglob("*.nix")
                            if not any(part in (".git", "result") for part in f.parts)
                        ]
            return self._files

        def find(self, needles: list[str], prefer: list[Path] = (), regex: bool = False) -> Loc | None:
            """First line in your config containing one of the needles (tried in order)."""
            files = list(dict.fromkeys([*prefer, *self.files()]))
            for needle in needles:
                if not needle:
                    continue
                pat = re.compile(needle if regex else re.escape(needle))
                for f in files:
                    for i, line in enumerate(read_lines(f)):
                        if line.lstrip().startswith("#"):
                            continue
                        if m := pat.search(line):
                            return Loc(self.origin(str(f)), i + 1, m.start() + 1)
            return None


    def read_lines(path: Path | None) -> list[str]:
        try:
            return path.read_text(errors="replace").splitlines() if path else []
        except OSError:
            return []


    # ─── rules ───────────────────────────────────────────────────────────────────


    @dataclass
    class Rule:
        id: str
        title: str
        match: re.Pattern
        priority: int = 50
        blame: str = "auto"  # you | upstream | system | auto
        explain: str = ""
        fix: str = ""
        requires: re.Pattern | None = None  # must ALSO appear somewhere in the full output
        locate: list[str] = field(default_factory=list)  # text to search for in your files
        locate_regex: bool = False
        handler: str | None = None
        scope: str = "error"  # error | log | both
        user: bool = False


    def load_rules() -> list[Rule]:
        by_id: dict[str, Rule] = {}
        for path, user in ((BUILTIN_RULES, False), (USER_RULES, True)):
            if not path.exists():
                continue
            try:
                data = tomllib.loads(path.read_text())
            except tomllib.TOMLDecodeError as e:
                warn(f"skipping {path}: {e}")
                continue
            for raw in data.get("rule", []):
                try:
                    rule = Rule(
                        id=raw["id"], title=raw["title"],
                        match=re.compile(raw["match"], re.M),
                        priority=raw.get("priority", 50), blame=raw.get("blame", "auto"),
                        explain=raw.get("explain", ""), fix=raw.get("fix", ""),
                        requires=re.compile(raw["requires"], re.M | re.S) if raw.get("requires") else None,
                        locate=raw.get("locate", []), locate_regex=raw.get("locate_regex", False),
                        handler=raw.get("handler"), scope=raw.get("scope", "error"), user=user,
                    )
                except (KeyError, re.error) as e:
                    warn(f"skipping rule {raw.get('id', '?')} in {path}: {e}")
                    continue
                by_id[rule.id] = rule  # user rules replace built-in ones with the same id
        return list(by_id.values())


    def render(template: str, vars: dict[str, str]) -> str:
        return TEMPLATE_RE.sub(lambda m: vars.get(m[1], ""), template).strip("\n").rstrip()


    # ─── parsing nix output ──────────────────────────────────────────────────────


    @dataclass
    class Block:
        text: str
        message: str
        loc: tuple[str, int, int] | None


    def clean(text: str) -> str:
        return BOX_PREFIX_RE.sub("", ANSI_RE.sub("", text)).replace("\r", "")


    def split_blocks(text: str) -> list[Block]:
        lines = text.splitlines()
        starts = [i for i, l in enumerate(lines) if ERROR_LINE_RE.match(l)]
        if not starts:
            return [Block(text, text.strip(), None)]
        blocks = []
        for n, s in enumerate(starts):
            chunk = lines[s:(starts[n + 1] if n + 1 < len(starts) else len(lines))]
            body = [ERROR_LINE_RE.match(chunk[0])[1], *chunk[1:]]
            msg, loc = [], None
            for l in body:
                st = l.strip()
                if st.startswith("…"):
                    break  # trace frames start here
                if st.startswith("at ") and (m := LOC_RE.search(l)):
                    loc = loc or (m["loc"], int(m["line"]), int(m["col"]))
                    continue
                if not SNIPPET_RE.match(l):
                    msg.append(l)
            message = (msg[0].strip() + "\n" + textwrap.dedent("\n".join(msg[1:]))).strip()
            blocks.append(Block("\n".join(chunk), message, loc))
        return blocks


    def frames(text: str) -> list[tuple[str, int, int]]:
        return [(m["loc"], int(m["line"]), int(m["col"])) for m in LOC_RE.finditer(text)]


    def def_files(text: str) -> list[str]:
        out = []
        for m in DEF_FILE_RE.finditer(text):
            if p := re.match(r"(/[^\s,#']+|«[^»]+»[^\s,#']*)", m["path"]):
                out.append(p[1])
        return list(dict.fromkeys(out))


    def best_match(rules: list[Rule], blocks: list[Block], full: str, scope: str):
        best = None
        for bi, b in enumerate(blocks):
            for r in rules:
                if scope == "error" and r.scope == "log" or scope == "log" and r.scope == "error":
                    continue
                if not (m := r.match.search(b.text)):
                    continue
                if r.requires and not r.requires.search(full):
                    continue
                key = (r.priority, r.user, bi)
                if best is None or key > best[0]:
                    best = (key, r, m, b)
        return best[1:] if best else None


    # ─── the report ──────────────────────────────────────────────────────────────


    @dataclass
    class Report:
        title: str
        rule_id: str | None
        blame: str = "unknown"  # you | upstream | system | unknown
        explain: str = ""
        fix: str = ""
        loc: Loc | None = None
        others: list[Loc] = field(default_factory=list)
        nix_said: str = ""
        suggest: str = ""
        context: str = ""
        note: str = ""
        log_tail: list[str] = field(default_factory=list)
        cause: Report | None = None
        source: str = ""
        saved_to: Path | None = None


    def analyze(text: str, flake: Flake, rules: list[Rule], scope: str = "error") -> Report:
        text = clean(text)
        blocks = split_blocks(text)
        hit = best_match(rules, blocks, text, scope)
        all_frames = frames(text)
        defs = [flake.origin(d) for d in def_files(hit[2].text if hit else text)]

        if hit:
            rule, m, block = hit
            vars = {k: v for k, v in m.groupdict().items() if v is not None}
        else:
            rule = None
            block = [b for b in blocks if b.message][-1] if any(b.message for b in blocks) else blocks[-1]
            vars = {}
        derive_vars(vars, block, flake)

        rep = Report(title=rule.title if rule else "Unrecognised error", rule_id=rule.id if rule else None)
        rep.nix_said = shorten_paths(block.message, flake)
        if s := SUGGEST_RE.search(block.text):
            rep.suggest = s["s"]
        if ctx := OPTION_CTX_RE.findall(text):
            rep.context = ctx[-1]
        own_loc = Loc(flake.origin(block.loc[0]), block.loc[1], block.loc[2]) if block.loc else None

        if rep.context and rep.context.endswith(".package"):
            # a module's `package` option failed: you probably enabled that module (programs.foo = ...)
            parts = re.findall(r'"[^"]*"|[^.]+', rep.context)[:-1]
            vars.setdefault("pkg_option", ".".join(parts[-2:]))

        # 1. a rule can say what text to look for in your files
        if rule and rule.locate:
            # needles naming a var we don't have are skipped (they'd match too much); regex needles get vars escaped
            subst = {k: re.escape(v) for k, v in vars.items()} if rule.locate_regex else vars
            needles = [render(t, subst) for t in rule.locate if all(n in vars for n in TEMPLATE_RE.findall(t))]
            rep.loc = flake.find(needles, [d.real for d in defs if d.owner == "you" and d.real], rule.locate_regex)
        # 2. otherwise the most likely suspect from nix's own output
        if rep.loc is None:
            yours = [Loc(flake.origin(f[0]), f[1], f[2]) for f in all_frames]
            yours = [l for l in yours if l.origin.owner == "you"]
            if own_loc and own_loc.origin.owner == "you":
                rep.loc = own_loc
            elif defs and defs[0].owner == "you":
                rep.loc = Loc(defs[0])
            elif yours:
                rep.loc = yours[-1]
                if own_loc and own_loc.origin.owner == "upstream":
                    rep.note = (f"The error was raised inside {own_loc.origin.label}, but the last of your own "
                                f"files in the chain is {rep.loc.describe()}. That is usually where to look.")
            else:
                rep.loc = own_loc
        rep.others = [Loc(d) for d in defs if d.owner == "you" and (not rep.loc or d.real != rep.loc.origin.real)]

        if rule and rule.handler in HANDLERS:
            HANDLERS[rule.handler](rep, vars, flake, rules, text)

        if rep.loc and rep.loc.line:
            vars.setdefault("line", str(rep.loc.line))
        if rep.loc:
            vars.setdefault("file", rep.loc.origin.display)
            vars.setdefault("input", rep.loc.origin.label)

        if rule:
            if rep.blame == "unknown":
                rep.blame = rule.blame if rule.blame != "auto" else (
                    {"you": "you", "upstream": "upstream"}.get(rep.loc.origin.owner, "unknown") if rep.loc else "unknown")
            rep.explain = render(rule.explain, vars)
            rep.fix = render(rule.fix, vars)
        else:
            rep.blame = {"you": "you", "upstream": "upstream"}.get(rep.loc.origin.owner, "unknown") if rep.loc else "unknown"
            rep.explain = ("nixed-error has no rule for this error yet. Below is what Nix said, with the noise "
                           "stripped, and the most likely place in your files.")
        return rep


    def derive_vars(vars: dict[str, str], block: Block, flake: Flake) -> None:
        home = str(Path.home())
        for k, v in list(vars.items()):
            if v.startswith(home):
                v = "~" + v[len(home):]
            if "\n" in v.strip() or v.strip().startswith("- "):  # lists / multi-line captures: re-indent evenly
                v = "\n".join("  " + l.strip() for l in v.strip().splitlines())
            vars[k] = v
        if opt := vars.get("option"):
            parts = re.findall(r'"[^"]*"|[^.]+', opt)
            vars["opt_last"] = parts[-1]
            vars["opt_tail2"] = ".".join(parts[-2:])
            vars["opt_parent"] = ".".join(parts[:-1][-2:])
        if pkg := vars.get("pkg"):
            vars["pname"] = re.sub(r"-\d[\w.+~-]*$", "", pkg)
        # "Definition values:" lists from the module system, with readable paths
        if "Definition values:" in block.message:
            defs = block.message.split("Definition values:", 1)[1]
            defs = re.split(r"\n(?:Did you mean|Use `lib\.mk)", defs)[0]
            vars["definitions"] = textwrap.indent(shorten_paths(textwrap.dedent(defs).strip(), flake), "  ")
        elif "conflicting definition values:" in block.message:
            defs = block.message.split("conflicting definition values:", 1)[1].split("\nUse `lib.mk")[0]
            vars["definitions"] = textwrap.indent(shorten_paths(textwrap.dedent(defs).strip(), flake), "  ")


    def shorten_paths(s: str, flake: Flake) -> str:
        def repl(m: re.Match) -> str:
            return flake.origin(m[0]).display

        return re.sub(r"/nix/store/[a-z0-9]{32}-[^\s/'`\":]+/[^\s'`\":]+|(?<![\w/])/(?:home|etc|tmp)/[^\s'`\":]+",
                      repl, s)


    # ─── handlers: rule-specific detective work ──────────────────────────────────

    OPEN = {"{": "}", "[": "]", "(": ")"}
    CLOSE = {v: k for k, v in OPEN.items()}


    def _skip_string(src: str, i: int) -> int:
        """Index just past the string starting at i, or -1 if it never ends."""
        indented = src.startswith("'''", i)
        i += 2 if indented else 1
        depth = 0
        while i < len(src):
            if depth:  # inside ''${ ... } within the string
                if src[i] == "{":
                    depth += 1
                elif src[i] == "}":
                    depth -= 1
                elif src[i] == '"' or src.startswith("'''", i):
                    if (i := _skip_string(src, i)) < 0:
                        return -1
                    continue
                i += 1
                continue
            if indented:
                if src.startswith("'''\\", i):
                    i += 4
                    continue
                if src.startswith("''''", i) or src.startswith("'''$", i):
                    i += 3
                    continue
                if src.startswith("'''", i):
                    return i + 2
            else:
                if src[i] == "\\":
                    i += 2
                    continue
                if src[i] == '"':
                    return i + 1
            if src.startswith("''${", i):
                depth, i = 1, i + 2
                continue
            i += 1
        return -1


    def scan_brackets(src: str, stop: int | None = None) -> dict | None:
        """Tiny Nix tokenizer. Returns the first bracket/string problem it finds.

        With `stop` (a character offset), returns {"kind": "stack", ...} listing the brackets still
        open at that point, unless a problem shows up before it.
        """
        stack: list[tuple[str, int]] = []
        i, line, n = 0, 1, len(src)
        while i < n:
            if stop is not None and i >= stop:
                break
            c = src[i]
            if c == "\n":
                line += 1
                i += 1
            elif c == "#":
                j = src.find("\n", i)
                i = n if j < 0 else j
            elif src.startswith("/*", i):
                j = src.find("*/", i + 2)
                if j < 0:
                    return {"kind": "comment", "char": "/*", "line": line}
                line += src.count("\n", i, j)
                i = j + 2
            elif c == '"' or src.startswith("'''", i):
                end = _skip_string(src, i)
                if end < 0:
                    return {"kind": "string", "char": '"' if c == '"' else "'''", "line": line}
                line += src.count("\n", i, end)
                i = end
            elif c in OPEN:
                stack.append((c, line))
                i += 1
            elif c in CLOSE:
                if not stack or stack[-1][0] != CLOSE[c]:
                    return {"kind": "mismatch", "char": c, "line": line, "open": stack[-1] if stack else None}
                stack.pop()
                i += 1
            else:
                i += 1
        if stop is not None:
            return {"kind": "stack", "stack": stack, "line": line}
        if stack:
            return {"kind": "unclosed", "char": stack[-1][0], "line": stack[-1][1]}
        return None


    def open_at(lines: list[str], line: int, col: int) -> list[tuple[str, int]]:
        """Brackets still open just before (line, col), innermost last. Empty if the scan hits a problem first."""
        stop = sum(len(l) + 1 for l in lines[: line - 1]) + max(col - 1, 0)
        result = scan_brackets("\n".join(lines), stop)
        return result["stack"] if result and result["kind"] == "stack" else []


    def bracket_note(problem: dict) -> str:
        ch, ln = problem["char"], problem["line"]
        if problem["kind"] == "unclosed":
            return f"The `{ch}` opened on line {ln} is never closed with `{OPEN[ch]}`."
        if problem["kind"] == "string":
            return f"The string starting with {ch} on line {ln} is never closed."
        if problem["kind"] == "comment":
            return f"The /* comment on line {ln} is never closed with */."
        if problem.get("open"):
            o, ol = problem["open"]
            return f"Line {ln} closes with `{ch}`, but the bracket that is still open is the `{o}` from line {ol}."
        return f"Line {ln} has a `{ch}` that closes something that was never opened."


    def h_semicolon(rep: Report, vars: dict, flake: Flake, rules, text: str) -> None:
        loc = rep.loc
        lines = read_lines(loc.origin.real) if loc else []
        if not lines or not loc.line or loc.line > len(lines):
            vars["fix_line"] = str(loc.line) if loc and loc.line else "?"
            return
        before = lines[loc.line - 1][: (loc.col or 1) - 1]
        if re.fullmatch(r"""\s*[\w."''\'''${}/-]*\s*""", before):
            # Only an attribute name precedes the error, so the `;` belonged at the end of the previous line.
            j = loc.line - 2
            while j >= 0 and (not lines[j].strip() or lines[j].lstrip().startswith("#")):
                j -= 1
            if j >= 0:
                rep.loc = Loc(loc.origin, j + 1, len(lines[j].rstrip()) + 1)
                vars["fix_line"] = str(j + 1)
                vars["note"] = (f"Nix reports line {loc.line}, because it only noticed the problem when the "
                                f"next setting started. The real mistake is at the end of line {j + 1}.")
                return
        vars["fix_line"] = str(loc.line)


    def h_brackets(rep: Report, vars: dict, flake: Flake, rules, text: str) -> None:
        if not rep.loc or not rep.loc.origin.real:
            return
        lines = read_lines(rep.loc.origin.real)
        if rep.rule_id == "unexpected-eof" or not rep.loc.line:
            problem = scan_brackets("\n".join(lines))
        else:
            # Nix's position is reliable; only a problem found before it explains it better.
            stop = sum(len(l) + 1 for l in lines[: rep.loc.line - 1]) + max((rep.loc.col or 1) - 1, 0)
            problem = scan_brackets("\n".join(lines), stop)
            if problem and problem["kind"] == "stack":
                problem = None
        if problem:
            vars["note"] = bracket_note(problem)
            rep.loc = Loc(rep.loc.origin, problem["line"])


    def guess_missing_opener(lines: list[str], close_line: int, opener: str) -> int | None:
        """Walk up from a stray closer to the assignment whose value should have opened it."""
        for j in range(close_line - 2, -1, -1):
            code = lines[j].split("#")[0].rstrip()
            if not code.strip():
                continue
            if re.search(r"(?<![=!<>])=(?![=>])", code):
                return None if code.endswith(opener) else j + 1
        return None


    def h_stray_closer(rep: Report, vars: dict, flake: Flake, rules, text: str) -> None:
        closer = vars.get("got", "]")
        opener = CLOSE[closer]
        vars["opener"] = opener
        vars["close_line"] = str(rep.loc.line) if rep.loc and rep.loc.line else "?"
        lines = read_lines(rep.loc.origin.real) if rep.loc else []
        if not lines or not rep.loc.line:
            vars["fix_text"] = f"Find where this `{opener}` ... `{closer}` should start and add the `{opener}`."
            return
        close_line = rep.loc.line
        vars["close_line"] = str(close_line)
        stack = open_at(lines, close_line, rep.loc.col or 1)
        if stack and any(o == opener for o, _ in stack):
            # The matching opener exists further out, so the bracket opened last was never closed.
            top, top_line = stack[-1]
            rep.title = "Missing closing bracket"
            rep.others = [Loc(rep.loc.origin, top_line)]
            vars["explain_text"] = (f"The `{top}` opened on line {top_line} is never closed, so the `{closer}` on "
                                    f"line {close_line} arrives while it's still open.")
            vars["fix_text"] = f"Add `{OPEN[top]}` before the `{closer}` on line {close_line}, to close the `{top}` from line {top_line}."
            return
        vars["explain_text"] = f"Line {close_line} has a `{closer}` that closes something that was never opened."
        guess = guess_missing_opener(lines, close_line, opener)
        if guess:
            rep.others = [Loc(rep.loc.origin, close_line)]
            rep.loc = Loc(rep.loc.origin, guess, len(lines[guess - 1].rstrip()) + 1)
            vars["guess_line"] = str(guess)
            vars["note"] = (f"Most likely line {guess} is missing a `{opener}` at the end. Without it, Nix reads "
                            f"everything after it as one long expression, and only notices on line {close_line}, "
                            f"which is why its message is about a `;`.")
            vars["fix_text"] = f"Add `{opener}` at the end of line {guess}:\n    {lines[guess - 1].strip()} {opener}"
        else:
            vars["fix_text"] = (f"Find where this `{opener}` ... `{closer}` should start (usually right after an "
                                f"`=`) and add the missing `{opener}`.")


    ASSIGN_RE = re.compile(r"""^\s*([\w."''\'''${}-]+)\s*=(?![=>])""")


    def similar_setting(lines: list[str], name: str, skip: int) -> int | None:
        """Line of the setting whose name shares the longest beginning with `name` (at least 4 characters)."""
        best, best_len = None, 3
        for i, l in enumerate(lines):
            if i + 1 == skip or not (m := ASSIGN_RE.match(l)):
                continue
            n = len(os.path.commonprefix([m[1], name]))
            if n > best_len:
                best, best_len = i + 1, n
        return best


    def h_equals_inside(rep: Report, vars: dict, flake: Flake, rules, text: str) -> None:
        """An unexpected `=`: usually a `name = value` setting that ended up inside a list."""
        lines = read_lines(rep.loc.origin.real) if rep.loc else []
        ln, col = (rep.loc.line or 0, rep.loc.col or 1) if rep.loc else (0, 1)
        stack = open_at(lines, ln, col) if lines and ln else []
        if stack and stack[-1][0] == "[":
            ol = stack[-1][1]
            name = m[1] if (m := ASSIGN_RE.match(lines[ln - 1])) else lines[ln - 1].split("=")[0].strip()
            rep.others = [Loc(rep.loc.origin, ol)]
            vars["explain_text"] = (f"Line {ln} sets `{name}`, but it's inside the list opened on line {ol} "
                                    f"(`{lines[ol - 1].strip()}`). Lists only hold values, not `name = value` settings.")
            near = similar_setting(lines, name, ln)
            outer = m[1] if (m := ASSIGN_RE.match(lines[ol - 1])) else ""
            # The same setting again, inside its own list (`foo = [ … foo = [ x ]; … ]`): a snippet pasted
            # into the list it was meant to add to. Keep its contents, drop the wrapper.
            close = None
            if outer == name and lines[ln - 1].split("#")[0].rstrip().endswith("["):
                close = next((j for j in range(ln + 1, min(len(lines), ln + 200) + 1)
                              if not any(s[0] == "[" and s[1] == ln
                                         for s in open_at(lines, j, len(lines[j - 1]) + 1))), None)
            if close:
                vars["explain_text"] = (f"Line {ln} sets `{name}` again, inside the `{name}` list that line {ol} "
                                        f"already opened. Lists only hold values, not `name = value` settings.")
                vars["note"] = (f"It looks like a snippet was pasted into the list it was meant to add to. Its "
                                f"contents (lines {ln + 1}–{close - 1}) can stay where they are; only the wrapper has to go.")
                vars["fix_text"] = (f"Delete line {ln} (`{lines[ln - 1].strip()}`) and line {close} "
                                    f"(`{lines[close - 1].strip()}`), keeping the lines in between.")
            elif near:
                vars["note"] = (f"It probably belongs with the similar settings around line {near} "
                                f"(`{lines[near - 1].strip()}`).")
                vars["fix_text"] = f"Move line {ln} out of the list, to the block around line {near}."
            else:
                vars["fix_text"] = f"Move line {ln} out of the list, into the {{ }} block where that setting belongs."
        else:
            rep.title = "Syntax error"
            vars["explain_text"] = (f"Nix found an `=` on line {ln} where it didn't make sense. Common causes: a "
                                    "missing `;` at the end of the line before, or a missing `{` or `}`.")
            vars["fix_text"] = f"Look at line {ln} and the line just above it."


    def last_list_before(lines: list[str], ln: int) -> tuple[int, int] | None:
        """(opened, closed) lines of the last list that closed before line `ln`."""
        for j in range(ln - 2, -1, -1):
            code = lines[j].split("#")[0]
            if (k := code.rfind("]")) >= 0:
                stack = open_at(lines, j + 1, k + 1)
                if stack and stack[-1][0] == "[":
                    return stack[-1][1], j + 1
                return None
        return None


    def h_bare_word(rep: Report, vars: dict, flake: Flake, rules, text: str) -> None:
        """Nix wanted `name = ...` but found a lone word: usually a package that slipped out of its list."""
        lines = read_lines(rep.loc.origin.real) if rep.loc else []
        ln, col = (rep.loc.line or 0, rep.loc.col or 1) if rep.loc else (0, 1)
        word, word_line = None, ln
        if lines and ln:
            before = lines[ln - 1][: col - 1].split("#")[0].strip()
            if before:
                word = before
            else:
                j = ln - 2
                while j >= 0 and not lines[j].split("#")[0].strip():
                    j -= 1
                if j >= 0:
                    word, word_line = lines[j].split("#")[0].strip(), j + 1
        if not word or not re.fullmatch(r"[\w.'-]+", word):
            rep.title = "Syntax error"
            vars["explain_text"] = (f"Nix expected a setting name followed by `=` on line {ln}, but found something else. "
                                    "Common causes: a missing `;` at the end of the line before, or a value without "
                                    "`name =` in front of it.")
            vars["fix_text"] = f"Look at line {ln} and the line just above it."
            return
        rep.loc = Loc(rep.loc.origin, word_line)
        is_pkg = word.split(".")[-1] in set(nixpkgs_names(flake)) or word.startswith("pkgs")
        vars["explain_text"] = (f"Line {word_line} has `{word}` on its own, inside a {{ }} block where only "
                                f"`name = value;` settings are allowed." +
                                (f" `{word}` is a package name, so it probably slipped out of a package list." if is_pkg else ""))
        lst = last_list_before(lines, word_line)
        if lst:
            opened, closed = lst
            rep.others = [Loc(rep.loc.origin, closed)]
            vars["note"] = (f"The list just above (line {opened}: `{lines[opened - 1].strip()}`) ends on line {closed}, "
                            f"before `{word}`.")
            vars["fix_text"] = f"Move `{word}` up, before the `]` on line {closed}."
        else:
            vars["fix_text"] = f"Move `{word}` into the list where it belongs, or turn it into a setting (`{word} = ...;`)."


    def h_semicolon_inside(rep: Report, vars: dict, flake: Flake, rules, text: str) -> None:
        """An unexpected `;`: if a list or ( ) is still open there, its closing bracket is missing."""
        lines = read_lines(rep.loc.origin.real) if rep.loc else []
        ln, col = (rep.loc.line or 0, rep.loc.col or 1) if rep.loc else (0, 1)
        stack = open_at(lines, ln, col) if lines and ln else []
        if stack and stack[-1][0] in "[(":
            o, ol = stack[-1]
            closer, what = OPEN[o], "list" if o == "[" else "( )"
            rep.others = [Loc(rep.loc.origin, ol)]
            current = lines[ln - 1]
            fixed = (current[: col - 1] + closer + current[col - 1:]).strip()
            vars["explain_text"] = (f"The `{o}` opened on line {ol} is still open when Nix reaches the `;` on line "
                                    f"{ln}. A `;` can't be inside a {what}, so the `{closer}` that ends it is missing.")
            vars["fix_text"] = f"Add `{closer}` before the `;` on line {ln}:\n    {fixed}"
        elif stack and lines[ln - 1][: col - 1].strip() == "":
            # A `;` alone at the start of a line inside an open { } is the leftover end of `};`.
            o, ol = stack[-1]
            rep.others = [Loc(rep.loc.origin, ol)]
            vars["explain_text"] = (f"The `{{` opened on line {ol} (`{lines[ol - 1].strip()}`) is still open when Nix "
                                    f"reaches the `;` on line {ln}. A `;` on its own is the end of `}};`, so the `}}` "
                                    f"that closes line {ol} is missing.")
            vars["fix_text"] = f"Add `}}` before the `;` on line {ln}:\n    }};"
        elif lines[ln - 1][: col - 1].rstrip().endswith(";"):
            rep.title = "Doubled semicolon"
            vars["explain_text"] = f"Line {ln} has two `;` in a row."
            vars["fix_text"] = f"Remove one of the `;` on line {ln}."
        else:
            rep.title = "Unexpected semicolon"
            vars["explain_text"] = (f"Nix found a `;` on line {ln} where it didn't expect one. Usually a doubled `;;`, "
                                    "a `;` inside a list, or a `;` right after `let ... in <value>`.")
            vars["fix_text"] = f"Look at line {ln} and the line just above it."


    def nixpkgs_names(flake: Flake) -> list[str]:
        """Top-level package names in your flake's own nixpkgs (only names: nothing gets evaluated)."""
        path = flake.inputs.get("nixpkgs") or next((p for n, p in flake.inputs.items() if "nixpkgs" in n), None)
        expr = f"builtins.attrNames (import {path} {{ }})" if path else "builtins.attrNames (import <nixpkgs> { })"
        try:
            out = run(["nix", "--extra-experimental-features", "nix-command", "eval", "--impure", "--json",
                       "--expr", expr], timeout=60)
            return json.loads(out.stdout) if out.returncode == 0 else []
        except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError):
            return []


    def h_unknown_name(rep: Report, vars: dict, flake: Flake, rules, text: str) -> None:
        name = vars.get("name", "")
        lines = read_lines(rep.loc.origin.real) if rep.loc else []
        line = rep.loc.line if rep.loc and rep.loc.line else 0
        # Is the name inside a `with pkgs;` block? Then it can only be a package name.
        in_with = any(re.search(r"\bwith\s+pkgs\s*;", l.split("#")[0]) for l in lines[max(0, line - 300):line])
        names = nixpkgs_names(flake)
        close = difflib.get_close_matches(name, names, n=4, cutoff=0.7) if names else []
        if close:
            rep.suggest = ", ".join(f"`{c}`" for c in close)
        if in_with:
            vars["note"] = (f"This list uses `with pkgs;`, so `{name}` has to be a package name, and nixpkgs has "
                            f"no package called `{name}`.")
            vars["fix_text"] = (f"Change it to `{close[0]}`, if that's what you meant." if close else
                                f"Check the spelling: `nix search nixpkgs {name}` or search.nixos.org.")
        else:
            vars["note"] = ("Usually a typo, a package name without `pkgs.` in front, or a missing "
                            "`let ... in` / function argument.")
            vars["fix_text"] = (f"Change it to `pkgs.{close[0]}`, if that's what you meant." if close else
                                f"Check the spelling of `{name}`. If it's a package, write `pkgs.{name}`.")


    def h_module_arg(rep: Report, vars: dict, flake: Flake, rules, text: str) -> None:
        name = vars.get("name", "")
        lines = read_lines(rep.loc.origin.real) if rep.loc else []
        for i, l in enumerate(lines[:20]):
            if m := re.match(r"^(\s*\{)([^}]*)(\}\s*:.*)$", l):
                args = [a.strip() for a in m[2].split(",") if a.strip()]
                new = [a for a in args if a != "..."] + [name] + (["..."] if "..." in args else [])
                vars["header_old"] = l.strip()
                vars["header_new"] = f"{m[1].strip()} {', '.join(new)} {m[3].strip()}"
                vars["header_line"] = str(i + 1)
                break
        else:
            vars["header_new"] = f"{{ config, pkgs, lib, {name}, ... }}:"
        if name == "inputs" and flake.dir and not (flake.dir / "flake.nix").exists():
            vars["note"] = ("`inputs` only exists in flake-based configs, and yours is a plain configuration.nix. "
                            "Use the thing directly instead (e.g. `pkgs.foo`, or `import (fetchTarball …)`), or pass "
                            "your own value with `_module.args.inputs = …;`.")
        elif name in ("inputs", "osConfig", "specialArgs"):
            vars["note"] = (f"`{name}` is not a standard module argument. It must also be passed in from "
                            "flake.nix with `specialArgs = { inherit inputs; };` in `nixosSystem` (or "
                            "`home-manager.extraSpecialArgs` for home-manager modules).")


    def h_assertion(rep: Report, vars: dict, flake: Flake, rules, text: str) -> None:
        # Assertion messages usually name the options involved; find them in your files.
        opts = re.findall(r"\b[a-zA-Z][\w-]*(?:\.(?:\"[^\"]+\"|[\w-]+)){2,}", vars.get("list", ""))
        needles = []
        for o in opts:
            parts = re.findall(r'"[^"]*"|[^.]+', o)
            needles += [".".join(parts[-2:]), ".".join(parts[-3:-1])]
        if needles and (loc := flake.find(needles)):
            rep.loc = loc


    REPLACEMENT_RE = re.compile(
        r"\b(?:using|use|by|to)\s+[‘'`\"]?(?:pkgs\.)?(?!pkgs\.)(?P<r>[\w.+-]*\w)[’'`\"]?(?:\s+(?:instead|directly)|[.,;)]|$)",
        re.I | re.M)


    def h_removed_pkg(rep: Report, vars: dict, flake: Flake, rules, text: str) -> None:
        # Two ways to use a removed package: directly (pkgs.foo), or by enabling a module whose
        # `package` option defaults to it (programs.foo). A module can't simply be renamed: the new
        # package rarely has a module of its own, and the old module's settings don't carry over.
        name, file = vars.get("name", ""), rep.loc.origin.display if rep.loc else "your config"
        new = m["r"] if (m := REPLACEMENT_RE.search(vars.get("msg", ""))) and m["r"] != name else ""
        line = read_lines(rep.loc.origin.real)[rep.loc.line - 1] if rep.loc and rep.loc.line else ""
        module = vars.get("pkg_option", "")
        hm = "home-manager" in rep.context
        pkgs_opt = "home.packages" if hm else "environment.systemPackages"
        if module and module in line:
            vars["explain_text"] = (
                f"`{module}` on line {rep.loc.line} turns on {'home-manager' if hm else 'NixOS'}'s "
                f"{module.rsplit('.', 1)[-1]} module, which installs `pkgs.{name}`. After updating, nixpkgs no "
                "longer has that package (Nix's reason is below). Your config still enables the module, so this "
                "is an update you need to follow, not a bug.")
            # its `enable = true` (on the same line, or inside the block before it closes)
            lines, enable_ln = read_lines(rep.loc.origin.real), None
            indent = len(line) - len(line.lstrip())
            for i in range(rep.loc.line - 1, min(len(lines), rep.loc.line + 40)):
                if re.search(r"\benable\s*=\s*true\b", lines[i]):
                    enable_ln = i + 1
                    break
                if i >= rep.loc.line and lines[i].strip() and len(lines[i]) - len(lines[i].lstrip()) <= indent:
                    break
            off = (f"change `enable = true;` on line {enable_ln} to `enable = false;`" if enable_ln
                   else f"set `{module}.enable = false;`")
            fix = (f"Quickest: {off}. That keeps your settings in place in case {name} comes back, or you want "
                   f"them for reference.\n\nFor good: remove the `{module} = {{ … }};` block from {file} (it starts "
                   f"on line {rep.loc.line}). Its settings are for {name} and won't carry over to another program.")
            if new:
                fix += (f"\n\nTo use {new} instead, install it as a plain package: `{pkgs_opt} = [ pkgs.{new} ];`. "
                        f"Don't just rename the block to `{module.rsplit('.', 1)[0]}.{new}`: that only works if "
                        f"{'home-manager' if hm else 'NixOS'} has a module for {new}, which most programs don't "
                        "(check the options search first).")
        else:
            vars["explain_text"] = (
                f"After updating, nixpkgs no longer has `{name}` under that name (Nix's reason is below). "
                "Your config still uses the old name, so this is an update you need to follow, not a bug.")
            where = f"on line {rep.loc.line} of {file}" if rep.loc and rep.loc.line else f"in {file}"
            fix = (f"Replace `{name}` {where} with `{new}`." if new else f"Remove `{name}` {where}.") + (
                "" if new else " The message above may name a replacement to use instead.")
        vars["fix_text"] = fix


    def h_unfree(rep: Report, vars: dict, flake: Flake, rules, text: str) -> None:
        """An unfree package: show what pulls it in, and an `allowUnfree = false` or a predicate that blocks it."""
        pkg, pname = vars.get("pkg", ""), vars.get("pname", "")
        head = re.escape(pname.split("-")[0])
        set_re = rf"\b(?P<set>[\w-]*pkgs[\w-]*)\.{re.escape(pname)}(?![\w-])"  # pkgs.foo, pkgs-stable.foo, ...
        # Drivers and modules pull packages in without naming them: nvidia-x11 comes from videoDrivers / hardware.nvidia.
        use = flake.find([set_re, rf"videoDrivers\s*=.*\"{head}\"",
                          rf"\b(?:hardware|programs|services)\.{head}(?![\w-])", rf"(?<![\w.\"-]){re.escape(pname)}(?![\w-])"],
                         regex=True)
        pset = m["set"] if use and (m := re.search(set_re, read_lines(use.origin.real)[use.line - 1])) else "pkgs"
        explain = f"`{pkg}` has a non-free license, and NixOS only installs free software unless you allow it."
        if use:
            explain += f" It's pulled in by {use.describe()}."

        # `pkgs-stable = import inputs.nixpkgs-stable { ... }` is a separate copy of nixpkgs with its own config:
        # `nixpkgs.config` in your modules doesn't reach it.
        if pset != "pkgs" and (imp := flake.find([rf"(?<![\w-]){re.escape(pset)}\s*=\s*import\b"], regex=True)):
            lines = read_lines(imp.origin.real)
            end, depth = imp.line, 0
            for i in range(imp.line - 1, min(len(lines), imp.line + 30)):
                code = lines[i].split("#")[0]
                depth += code.count("{") - code.count("}")
                end = i + 1
                if depth <= 0 and (i > imp.line - 1 or "{" in code):
                    break
            block = {n: lines[n - 1].split("#")[0] for n in range(imp.line, end + 1)}
            off_ln = next((n for n, l in block.items() if re.search(r"\ballowUnfree\s*=\s*false\b", l)), None)
            pred_ln = next((n for n, l in block.items() if re.search(r"\ballowUnfreePredicate\s*=", l)), None)
            at = lambda n: f"line {n} of {imp.origin.display}"
            predicate = f'config.allowUnfreePredicate = pkg: builtins.elem (builtins.parseDrvName pkg.name).name [ "{pname}" ];'
            explain += (f" `{pset}` is its own copy of nixpkgs, made with `import` on {at(imp.line)}. That copy has "
                        "its own settings: `nixpkgs.config` in your modules doesn't reach it.")
            rep.others = [use] if use else []
            rep.context = ""
            if off_ln:
                rep.loc = Loc(imp.origin, off_ln)
                explain += f" {at(off_ln)[0].upper() + at(off_ln)[1:]} sets `allowUnfree = false` for it, which blocks {pname}."
                fix = (f"Change {at(off_ln)} to `true`, or keep it `false` and allow only this package, inside "
                       f"that same `import`:\n    {predicate}")
            elif pred_ln:
                rep.loc = Loc(imp.origin, pred_ln)
                explain += f" Its `allowUnfreePredicate` ({at(pred_ln)}) doesn't include {pname}."
                fix = f"Add \"{pname}\" to the list in the `allowUnfreePredicate` on {at(pred_ln)}."
            else:
                rep.loc = imp
                explain += " It doesn't allow unfree packages, even if your system does."
                fix = (f"Add `config.allowUnfree = true;` inside the `import {{ … }}` on {at(imp.line)}, or only "
                       f"this package:\n    {predicate}")
            vars["explain_text"], vars["fix_text"] = explain, fix
            return

        # the module option (`nixpkgs.config.allowUnfree`, or `allowUnfree` nested in `nixpkgs.config = { }`),
        # not an `import nixpkgs { config.allowUnfree = false; }`, which only affects that copy
        off = flake.find([r"\bnixpkgs\.config\.allowUnfree\s*=\s*false\b", r"^\s*allowUnfree\s*=\s*false\b"], regex=True)
        pred = flake.find([r"\ballowUnfreePredicate\s*="], regex=True)
        predicate = f'nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "{pname}" ];'
        hm = "(With home-manager and `useGlobalPkgs = false`, set it in your home-manager config too.)"
        rep.loc, rep.others = (off or use), [l for l in (use,) if l and off]
        if rep.loc:
            rep.context = ""  # the option nixpkgs was evaluating (tmpfiles, system-path, ...) only adds noise now
        if off:
            explain += f" {off.describe()} sets `allowUnfree = false`, which blocks it."
            fix = (f"Change line {off.line} of {off.origin.display} to `true`, or keep it `false` and allow only "
                   f"this package:\n    {predicate}")
        elif pred:
            explain += f" Your `allowUnfreePredicate` ({pred.describe()}) doesn't include it."
            fix = f"Add \"{pname}\" to the list in your `allowUnfreePredicate` on line {pred.line} of {pred.origin.display}."
        else:
            fix = f"Allow all unfree packages:\n    nixpkgs.config.allowUnfree = true;\nor only this one:\n    {predicate}\n{hm}"
        vars["explain_text"], vars["fix_text"] = explain, fix


    def git(flake: Flake, *args: str) -> str:
        if not flake.dir:
            return ""
        try:
            return subprocess.run(["git", "-C", str(flake.dir), *args], capture_output=True, timeout=10
                                  ).stdout.decode(errors="replace")
        except (OSError, subprocess.TimeoutExpired):
            return ""


    def import_roots(flake: Flake) -> list[str]:
        """Folders that import-tree loads, from `import-tree ./modules` in flake.nix."""
        src = "\n".join(read_lines(flake.dir / "flake.nix")) if flake.dir else ""
        return [r.rstrip("/") for r in re.findall(r"import-tree\s*\)?\s*\[?\s*\./([\w./-]+)", src)]


    def h_missing_module(rep: Report, vars: dict, flake: Flake, rules, text: str) -> None:
        """`config.flake.modules.nixos.foo` where no loaded file sets foo: usually its file was moved,
        deleted, never `git add`-ed, or sits outside the folders import-tree loads."""
        name, cls = vars.get("name", ""), vars.get("class") or vars.get("class2", "")
        prefix = vars.get("prefix", "")
        # what a definition looks like: `flake.modules.nixos.foo =` or `flake.nixosModules.foo =`
        defpath = re.sub(r"^(?:self|flake)\.", "", prefix)
        shown = f"flake.{defpath}.{name}"
        def_re = re.compile(rf"\b{re.escape(defpath)}\.{re.escape(name)}\s*=(?!=)")
        kind = {"nixos": "NixOS", "homeManager": "home-manager", "home": "home-manager",
                "darwin": "nix-darwin"}.get(cls, cls)
        use = f"line {rep.loc.line} of {rep.loc.origin.display}" if rep.loc and rep.loc.line else "your config"
        repo = "~/" + r if flake.dir and (r := under(flake.dir, Path.home())) else str(flake.dir or ".")
        roots = import_roots(flake)
        where = " and ".join(", ".join(f"./{r}" for r in roots).rsplit(", ", 1))
        vars["explain_text"] = f"{use[0].upper() + use[1:]} uses the {kind} module `{name}`, but no file sets `{shown}`."
        rep.context = ""  # whichever option Nix was evaluating (assertions, ...) when it hit the import is incidental
        line = read_lines(rep.loc.origin.real)[rep.loc.line - 1].strip() if rep.loc and rep.loc.line else ""
        ref = m[0] if (m := re.search(rf"[\w.]*\.{re.escape(name)}\b", line)) else name
        drop = (f"If you meant to drop the module, remove {use}." if line == ref
                else f"If you meant to drop the module, remove `{ref}` from {use}.")

        # Other modules of this kind, for "did you mean"
        names = set()
        all_re = re.compile(rf"\b{re.escape(defpath)}\.([\w-]+)\s*=(?!=)")
        for f in flake.files():
            for l in read_lines(f):
                names.update(all_re.findall(l))
        names.discard(name)
        close = difflib.get_close_matches(name, sorted(names), n=3, cutoff=0.7)

        # 1. A file in the flake folder defines it, but Nix doesn't load that file.
        if loc := flake.find([def_re.pattern], regex=True):
            rel = loc.origin.display
            rep.others = [loc]
            if rel in git(flake, "ls-files", "--others", "--exclude-standard").splitlines():
                vars["explain_text"] += (f" {rel} sets it, but that file isn't added to git, and flakes only see "
                                         "files git knows about.")
                vars["fix_text"] = f"    git -C {repo} add {rel}\n(It doesn't have to be committed, just added.)"
            elif roots and (not any(rel == r or rel.startswith(r + "/") for r in roots)
                            or any(p.startswith("_") for p in Path(rel).parts)):
                vars["explain_text"] += (f" {rel} (line {loc.line}) sets it, but import-tree only loads .nix files "
                                         f"under {where}, and skips any path with a part starting with `_`. "
                                         "So that file is never read.")
                vars["fix_text"] = f"Move {rel} into {'./' + roots[0]} (any subfolder works). {drop}"
            else:
                vars["explain_text"] += (f" {rel} sets it on line {loc.line}, yet Nix didn't see it. Check that "
                                         "the definition isn't inside a condition, and that the file is imported.")
                vars["fix_text"] = f"Look at line {loc.line} of {rel}."
            return

        # 2. A file that git knows defined it is gone. Step 1 searched every .nix file in the folder, tracked
        #    or not, so it wasn't just moved within the flake: it was deleted, or moved out of the folder.
        for l in git(flake, "status", "--porcelain", "--no-renames").splitlines():
            path = l[3:].strip().strip('"')
            if "D" not in l[:2] or not path.endswith(".nix"):
                continue
            old = git(flake, "show", f":{path}") or git(flake, "show", f"HEAD:{path}")
            if def_re.search(old):
                vars["explain_text"] += (f" {path} used to set it, but that file was deleted since your last commit, "
                                         f"and no other file in {repo} sets it now.")
                vars["fix_text"] = (f"Bring the file back from git:\n"
                                    f"    git -C {repo} checkout HEAD -- {path}\n\n{drop}")
                return

        # 3. Deleted in an earlier commit.
        out = git(flake, "log", "-1", "--diff-filter=D", "--name-only", "--format=%h %s", "-S", f"{defpath}.{name}")
        if out.strip():
            head, *files = [l for l in out.splitlines() if l.strip()]
            commit, _, subject = head.partition(" ")
            path = files[0] if files else "its file"
            vars["explain_text"] += f" {path} used to set it, but it was deleted in commit {commit} (“{subject}”)."
            vars["fix_text"] = f"Bring it back:\n    git -C {repo} checkout {commit}^ -- {path}\n\n{drop}"
            return

        # 4. A new file named after the module, not added to git yet (and not defining it, or step 1 had found it).
        untracked = [u for u in git(flake, "ls-files", "--others", "--exclude-standard", "*.nix").splitlines()]
        stem = lambda u: Path(u).stem.lower().replace("_", "-")
        named = [u for u in untracked if stem(u) == name.lower()] or [
            u for u in untracked if difflib.get_close_matches(name.lower(), [stem(u)], n=1, cutoff=0.8)
            or name.lower() in stem(u)]
        if named:
            rel = named[0]
            rep.others = [Loc(flake.origin(str(flake.dir / rel)), 1)]
            vars["explain_text"] += (f" {rel} looks like it's meant to, but it isn't added to git, so Nix can't see it "
                                     f"(flakes only see files git knows about). It also doesn't set `{shown}` yet, so "
                                     "adding it to git alone won't fix this.")
            vars["fix_text"] = (f"In {rel}, define the module:\n    {{ {shown} = {{ ... }}: {{ }}; }}\nthen add the "
                                f"file to git (it doesn't have to be committed):\n    git -C {repo} add {rel}\n\n{drop}")
            return

        # 5. Never defined: a typo, or a module still to be written.
        if close:
            rep.suggest = ", ".join(f"`{c}`" for c in close)
            vars["fix_text"] = f"Change `{name}` to `{close[0]}`, if that's what you meant. {drop}"
        else:
            vars["fix_text"] = (f"Create a file under {'./' + roots[0] if roots else 'your modules folder'} that sets "
                                f"`{shown} = {{ ... }};`. {drop}")
        vars["note"] = "It isn't a package, so `nix search` won't find it: modules like this are defined in your own files."


    HM_CLOBBER_RE = re.compile(r"Existing file '(?P<a>[^']+)' would be clobbered(?: by backing up '(?P<b>[^']+)')?$", re.M)


    def h_hm_file(rep: Report, vars: dict, flake: Flake, rules, text: str) -> None:
        """Files in the way of home-manager's links. home-manager lists every one, so explain them all,
        and say how to rerun it: a switch with no config change doesn't restart its service."""
        tilde = lambda p: "~/" + r if (r := under(Path(p), Path.home())) else p
        hits = [(m["b"], m["a"]) if m["b"] else (m["a"], None) for m in HM_CLOBBER_RE.finditer(text)]
        hits = [h for h in dict.fromkeys(hits) if (h[1] is not None) == ("backup" in vars)] or [(vars["file"], vars.get("backup"))]
        files, backups = [tilde(f) for f, _ in hits], [tilde(b) for _, b in hits if b]
        join = lambda xs: " and ".join(", ".join(f"`{x}`" for x in xs).rsplit(", ", 1))
        vars["files"], vars["backups"] = join(files), join(backups)
        many = len(files) > 1
        vars["already"] = "normal files are already there" if many else "a normal file is already there"
        vars["it"], vars["it_file"] = ("them", "those files") if many else ("it", "the file")
        vars["moves"] = "\n".join(f"    mv {f} {f}.old" for f in files)
        vars["removes"] = "\n".join(f"    rm {b}" for b in backups)
        vars["backup_age"] = ""
        try:
            when = time.localtime(Path(hits[0][1]).stat().st_mtime) if hits[0][1] else None
            if when:
                vars["backup_age"] = " (from " + time.strftime("%B ", when) + str(when.tm_mday) + (
                    time.strftime(", %Y", when) if when.tm_year != time.localtime().tm_year else "") + ")"
        except OSError:
            pass
        if len(hits) > 1:
            vars["backup_age"] = vars["backup_age"].replace(" (from", " (the first from")
        unit = (m[1] if (m := re.search(r"\b(home-manager-[\w@-]+)\.service\b", text)) else
                f"home-manager-{os.environ.get('USER', '$USER')}") + ".service"
        vars["rerun"] = f"sudo systemctl restart {unit}"
        vars["rerun_note"] = ("(`nh os switch` alone won't retry it if nothing in your config changed: NixOS only "
                              "restarts the home-manager service when its config does.)")


    def read_build_log(drv: str) -> str | None:
        name = Path(drv).name
        for f in (NIX_LOG_DIR / name[:2] / (name[2:] + ".bz2"), NIX_LOG_DIR / name[:2] / name[2:]):
            try:
                data = f.read_bytes()
                return (bz2.decompress(data) if f.suffix == ".bz2" else data).decode(errors="replace")
            except OSError:
                continue
        return None


    def h_build(rep: Report, vars: dict, flake: Flake, rules: list[Rule], text: str) -> None:
        drv = vars.get("drv", "")
        name = re.sub(r"^/nix/store/[a-z0-9]{32}-|\.drv$", "", drv)
        vars["name"] = name
        vars["pname"] = pname = re.sub(r"-\d[\w.+~-]*$", "", name)
        log = read_build_log(drv) if drv else None
        if log is None:
            log = "\n".join(LOG_LINE_RE.findall(text))
        log = clean(log)
        rep.log_tail = [l for l in log.splitlines() if l.strip()][-15:]
        if log.strip() and (cause := best_match(rules, [Block(log, log, None)], log, "log")):
            c_rule, c_m, _ = cause
            cvars = {k: v for k, v in c_m.groupdict().items() if v is not None} | {"name": name, "pname": pname}
            rep.cause = Report(title=c_rule.title, rule_id=c_rule.id, blame=c_rule.blame,
                               explain=render(c_rule.explain, cvars), fix=render(c_rule.fix, cvars))
            if c_rule.blame in ("system", "you"):
                rep.blame = c_rule.blame
        # Is this a package you wrote yourself?
        own = flake.find([rf"""(?:\bp?name\s*=\s*|\b(?:runCommand\w*|write\w+|mkDerivation|buildPythonApplication)\s+)["']{re.escape(pname)}["'-]"""],
                         regex=True)
        # Or a nixpkgs package you changed (`pkgs.foo.overrideAttrs`, an overlay's `prev.foo.override`)?
        changed = None if own else flake.find(
            [rf"\b{re.escape(pname)}\.(?:overrideAttrs|overrideDerivation|override)\b"], regex=True)
        if own:
            rep.loc = own
            if rep.blame == "unknown":
                rep.blame = "you"
            vars["owner_note"] = f"`{pname}` is a package defined in your own config ({own.describe()})."
            vars["advice"] = "The cause is in the end of the build log above: your build script or its source."
        elif changed:
            rep.loc = changed
            if rep.blame in ("unknown", "upstream"):
                rep.blame = "you"
            how = re.search(r"\.(override\w*)", read_lines(changed.origin.real)[changed.line - 1])[1]
            note = (f"`{pname}` comes from nixpkgs, but you change it with `{how}` on {changed.describe()}. "
                    "Plain nixpkgs packages are built and tested before they reach you, so the failure most "
                    "likely comes from your change (patches, build phases, hooks, version or src).")
            # The log's last lines often come straight from the override (an echo, a patch name, a command).
            lines = read_lines(changed.origin.real)
            block = range(changed.line - 1, min(len(lines), changed.line + 40))
            for out in reversed(rep.log_tail[-5:]):
                text = re.sub(r"^\s*>\s?", "", out).strip()
                if len(text) < 10:
                    continue
                if hit := next((i for i in block if text in lines[i] and not lines[i].lstrip().startswith("#")), None):
                    rep.loc = Loc(changed.origin, hit + 1)
                    note += f" The build log's line `{text}` comes from line {hit + 1} of your file."
                    break
            vars["owner_note"] = note
            vars["advice"] = (f"Look at your `{how}` on {changed.describe()}. To confirm, take the change out: if "
                              f"`{pname}` then builds, the cause is in what you changed.")
        else:
            rep.loc = None
            if rep.blame == "unknown":
                rep.blame = "upstream"
            vars["owner_note"] = (f"`{pname}` is not defined in your config, so it comes from nixpkgs or "
                                  "another input. This is usually not caused by anything you typed.")
            vars["advice"] = (f"Check whether it's already reported (github.com/NixOS/nixpkgs/issues, search "
                              f"\"{pname}\"). Meanwhile, go back to your previous flake.lock "
                              "(`git checkout flake.lock`) or remove the package for now.")
        rep.others = []


    HANDLERS = {
        "semicolon": h_semicolon, "brackets": h_brackets, "build": h_build,
        "module_arg": h_module_arg, "assertion": h_assertion, "stray_closer": h_stray_closer,
        "semicolon_inside": h_semicolon_inside,
        "equals_inside": h_equals_inside,
        "bare_word": h_bare_word,
        "unknown_name": h_unknown_name,
        "removed_pkg": h_removed_pkg,
        "missing_module": h_missing_module,
        "hm_file": h_hm_file,
        "unfree": h_unfree,
    }


    # ─── getting the error: reproduce it ourselves ──────────────────────────────


    def run(cmd: list[str], timeout: int | None = None) -> subprocess.CompletedProcess:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


    @dataclass
    class Config:
        """Where the user's NixOS config is: a flake (`ref` is a flake ref, `dir` its folder if local) or a
        classic configuration.nix (`ref` is that file, `dir` its folder). `problem` says why none was found."""
        kind: str = ""  # "flake" | "classic" | "" (not found)
        ref: str = ""
        dir: Path | None = None
        host: str = ""
        problem: str = ""


    def find_config(given: str | None, host: str | None) -> Config:
        """--config/--flake, then $NH_OS_FLAKE / $NH_FLAKE / $FLAKE (nh), then $NIXOS_CONFIG, then a flake in
        /etc/nixos, then `nixos-config` from $NIX_PATH, then /etc/nixos/configuration.nix."""
        env = next((os.environ[v] for v in ("NH_OS_FLAKE", "NH_FLAKE", "FLAKE") if os.environ.get(v)), None)
        ref = given or env
        hostname = socket.gethostname()
        if ref:
            path, _, ref_host = ref.partition("#")
            host = host or ref_host or hostname
            local = re.sub(r"^(?:path:|git\+file://)", "", path)
            if re.match(r"^[\w+-]+:", local):  # a remote flake ref (github:me/config): nothing local to read
                return Config("flake", path, None, host)
            p = Path(local).expanduser()
            if p.is_file():
                if p.name == "flake.nix":
                    return Config("flake", str(p.parent.resolve()), p.parent.resolve(), host)
                return Config("classic", str(p.resolve()), p.resolve().parent, host)
            if (p / "flake.nix").is_file():
                return Config("flake", str(p.resolve()), p.resolve(), host)
            for name in ("configuration.nix", "default.nix"):
                if (p / name).is_file():
                    return Config("classic", str((p / name).resolve()), p.resolve(), host)
            why = "doesn't exist" if not p.exists() else "has no flake.nix or configuration.nix"
            src = "--config" if given else next(v for v in ("NH_OS_FLAKE", "NH_FLAKE", "FLAKE") if os.environ.get(v))
            return Config(host=host, problem=f"{local} (from {src}) {why}.")
        host = host or hostname
        if nc := os.environ.get("NIXOS_CONFIG"):
            p = Path(nc).expanduser()
            p = p / "default.nix" if p.is_dir() else p
            if p.is_file():
                return Config("classic", str(p.resolve()), p.resolve().parent, host)
        if Path("/etc/nixos/flake.nix").is_file():
            return Config("flake", "/etc/nixos", Path("/etc/nixos").resolve(), host)
        try:
            found = subprocess.run(["nix-instantiate", "--find-file", "nixos-config"],
                                   capture_output=True, text=True, timeout=10).stdout.strip()
        except (OSError, subprocess.TimeoutExpired):
            found = ""
        for p in [Path(found)] * bool(found) + [Path("/etc/nixos/configuration.nix")]:
            p = p / "default.nix" if p.is_dir() else p
            if p.is_file():
                return Config("classic", str(p.resolve()), p.resolve().parent, host)
        return Config(host=host, problem="No NixOS config found: /etc/nixos has no flake.nix or configuration.nix, "
                                         "and $NH_OS_FLAKE, $NIXOS_CONFIG and $NIX_PATH don't name one.")


    def reproduce(cfg: Config) -> tuple[str | None, str]:
        """Returns (output to explain, how we got it). Output is None if nothing fails."""
        nixcmd = ["nix", "--extra-experimental-features", "nix-command flakes"]
        if cfg.kind == "flake":
            target = f'{cfg.ref}#nixosConfigurations."{cfg.host}".config.system.build.toplevel'
            cmd = [*nixcmd, "build", "--dry-run", "--show-trace", target]
            how = f"re-evaluated {cfg.ref}#{cfg.host}"
        else:
            cmd = ["nix-build", "<nixpkgs/nixos>", "-A", "system", "--dry-run", "--show-trace",
                   "-I", f"nixos-config={cfg.ref}"]
            how = f"re-evaluated {cfg.ref}"
        p = run_with_timer(cmd, "Re-checking your config to catch the error")
        if p.returncode != 0:
            return p.stderr + p.stdout, how

        # Evaluation is fine, so it was a build failure. Nix keeps logs of failed builds.
        drvs = re.findall(r"^\s+(/nix/store/\S+\.drv)$", p.stderr + p.stdout, re.M)
        logged = []
        for d in drvs:
            name = Path(d).name
            for f in (NIX_LOG_DIR / name[:2] / (name[2:] + ".bz2"), NIX_LOG_DIR / name[:2] / name[2:]):
                if f.exists():
                    logged.append((f.stat().st_mtime, d))
                    break
        if logged:
            _, drv = max(logged)
            return (f"error: Cannot build '{drv}'.\n       Reason: builder failed "
                    f"(log kept from the last attempt).\n"), how + " (evaluation is fine; found a failed build log)"

        # Builds fine too: maybe the switch itself (activation) failed.
        units = []
        for scope in ([], ["--user"]):
            out = run(["systemctl", *scope, "--failed", "--no-legend", "--plain"], timeout=10).stdout
            units += [(scope, l.split()[0]) for l in out.splitlines() if l.strip()]
        if units:
            scope, unit = next((u for u in units if "home-manager" in u[1]), units[0])
            jflag = "--user-unit" if scope else "-u"
            journal = run(["journalctl", "-b", jflag, unit, "-n", "40", "--no-pager", "-o", "cat"], timeout=10).stdout
            return f"error: unit {unit} failed\n{journal}", how + f" (builds fine; checked the failed unit {unit})"
        return None, how


    # ─── output ──────────────────────────────────────────────────────────────────

    COLOR = sys.stdout.isatty() and not os.environ.get("NO_COLOR")


    def c(code: str, s: str) -> str:
        return f"\x1b[{code}m{s}\x1b[0m" if COLOR else s


    def status(msg: str) -> None:
        print(c("2", msg), file=sys.stderr)


    def run_with_timer(cmd: list[str], msg: str) -> subprocess.CompletedProcess:
        """Run cmd, showing a ticking elapsed time on the terminal so a long evaluation doesn't look stuck."""
        if not sys.stderr.isatty():
            status(msg + "…")
            return run(cmd)
        start = time.monotonic()
        with subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as proc:
            out: dict[str, str] = {}

            def collect() -> None:
                out["stdout"], out["stderr"] = proc.communicate()

            reader = threading.Thread(target=collect, daemon=True)
            reader.start()
            try:
                while reader.is_alive():
                    secs = int(time.monotonic() - start)
                    hint = "  (a first check without cache can take a few minutes)" if secs >= 20 else ""
                    sys.stderr.write(f"\r\x1b[2K{c('2', f'{msg}… {secs}s{hint}')}")
                    sys.stderr.flush()
                    reader.join(0.5)
            finally:
                sys.stderr.write("\r\x1b[2K")
                sys.stderr.flush()
        status(f"{msg}: done in {int(time.monotonic() - start)}s")
        return subprocess.CompletedProcess(cmd, proc.returncode, out.get("stdout", ""), out.get("stderr", ""))


    def warn(msg: str) -> None:
        print(c("33", f"nixed-error: {msg}"), file=sys.stderr)


    BLAME = {
        "you": ("31", "Your config", "something in your own files"),
        "upstream": ("35", "Upstream", "not something you typed"),
        "system": ("33", "Your machine", "disk, network or permissions, not your config"),
        "unknown": ("2", "Unclear", "couldn't tell whose it is"),
    }


    def wrap(s: str, indent: str = "    ") -> str:
        width = min(shutil.get_terminal_size((100, 20)).columns, 100)
        out: list[str] = []
        prose: list[str] = []

        def flush() -> None:
            if prose:
                out.append(textwrap.fill(" ".join(prose), width, initial_indent=indent, subsequent_indent=indent,
                                         break_long_words=False, break_on_hyphens=False))
                prose.clear()

        # Consecutive prose lines are joined and re-wrapped; indented lines (code, lists) stay as they are.
        for line in s.split("\n"):
            if not line.strip():
                flush()
                if out and out[-1] != "":
                    out.append("")
            elif line.startswith((" ", "-")):
                flush()
                out.append(indent + line)
            else:
                prose.append(line.strip())
        flush()
        while out and out[-1] == "":
            out.pop()
        return "\n".join(out)


    def snippet(loc: Loc) -> str:
        lines = read_lines(loc.origin.real)
        if not lines or not loc.line or loc.line > len(lines):
            return ""
        lo, hi = max(1, loc.line - 2), min(len(lines), loc.line + 1)
        w = len(str(hi))
        out = []
        for n in range(lo, hi + 1):
            mark = c("31;1", "→") if n == loc.line else " "
            num = c("1", str(n).rjust(w)) if n == loc.line else c("2", str(n).rjust(w))
            out.append(f"    {mark} {num} │ {lines[n - 1]}")
        return "\n".join(out)


    def print_report(rep: Report, verbose: bool) -> None:
        color, label, sub = BLAME[rep.blame]
        print()
        print(c("1", f"✗ {rep.title}"))
        print(f"  {c('2', 'Whose:')} {c(color + ';1', label)} {c('2', '— ' + (rep.loc.origin.label if rep.blame == 'upstream' and rep.loc else sub))}")
        if rep.loc:
            print(f"  {c('2', 'Where:')} {rep.loc.describe()}")
        for o in rep.others:
            print(f"  {c('2', '  and:')} {o.describe()}")
        if rep.context and rep.context != "system.build.toplevel" and rep.rule_id not in (
                "missing-semicolon", "unexpected-eof", "syntax-error", "list-comma"):
            print(f"  {c('2', 'While:')} working out the option {rep.context}")
        if rep.loc and (sn := snippet(rep.loc)):
            print()
            print(sn)
        print()
        if rep.explain:
            print(wrap(rep.explain, "  "))
        if rep.note:
            print()
            print(wrap(rep.note, "  "))
        if rep.cause:
            print()
            print(c("1", f"  Why the build failed: {rep.cause.title}"))
            if rep.cause.explain:
                print(wrap(rep.cause.explain, "    "))
            if rep.cause.fix and not rep.fix:
                rep.fix = rep.cause.fix
            elif rep.cause.fix:
                rep.fix = rep.cause.fix + "\n\n" + rep.fix
        if rep.log_tail:
            print()
            tail = rep.log_tail[-(15 if verbose else 8):]
            # `/nix/store/<32-char hash>-coreutils-9.11/bin/mkdir` → `…/coreutils-9.11/bin/mkdir`: the hashes
            # make every line wrap and say nothing to a reader. -v keeps them.
            short = [l if verbose else STORE_HASH_RE.sub("…/", l) for l in tail]
            shortened = short != tail
            print(c("2", "  End of the build log" + (" (store paths shortened; -v for full):" if shortened else ":")))
            for l in short:
                print(c("2", "    > ") + l[:200])
        if rep.suggest:
            print()
            print(f"  {c('1', 'Did you mean:')} {rep.suggest}")
        if rep.fix:
            print()
            print(c("32;1", "  Fix"))
            print(wrap(rep.fix, "    "))
        if rep.nix_said and (verbose or rep.rule_id is None or len(rep.nix_said) < 400):
            print()
            print(c("2", "  What Nix said:"))
            said = rep.nix_said if verbose or rep.rule_id is None else rep.nix_said.splitlines()[0]
            print(c("2", textwrap.indent(said, "    ")))
        if rep.saved_to:
            print()
            print(c("2", f"  Saved to {rep.saved_to} so a rule can be written for it later."))
            print(c("2", f"  Add your own rules in {USER_RULES}"))
        print()
        if rep.source:
            print(c("2", f"  ({rep.source})"))


    def save_unknown(text: str) -> Path | None:
        try:
            UNKNOWN_DIR.mkdir(parents=True, exist_ok=True)
            path = UNKNOWN_DIR / time.strftime("%Y%m%d-%H%M%S.log")
            path.write_text(clean(text))
            return path
        except OSError:
            return None


    # ─── main ────────────────────────────────────────────────────────────────────


    def main(argv: list[str] | None = None) -> int:
        ap = argparse.ArgumentParser(
            prog="nixed-error",
            description="Explain a failed NixOS rebuild in plain words.",
            epilog="With no LOG and nothing piped in, nixed-error re-evaluates your config to capture the error itself.",
        )
        ap.add_argument("log", nargs="?", help="file with the failed output ('-' for stdin)")
        ap.add_argument("-c", "--config", "--flake", dest="config", metavar="PATH",
                        help="your config: a flake (folder or path#host) or a configuration.nix (file or folder). "
                             "Default: $NH_OS_FLAKE, $NH_FLAKE, $FLAKE, $NIXOS_CONFIG, a flake in /etc/nixos, "
                             "nixos-config from $NIX_PATH, then /etc/nixos/configuration.nix")
        ap.add_argument("-H", "--host", help="nixosConfigurations name, for flakes (default: from path#host, else hostname)")
        ap.add_argument("-v", "--verbose", action="store_true", help="show the full Nix message and longer logs")
        ap.add_argument("--list-rules", action="store_true", help="list known errors and exit")
        ap.add_argument("--rule-id", action="store_true", help=argparse.SUPPRESS)  # for tests
        ap.add_argument("--version", action="version", version=f"nixed-error {VERSION}")
        args = ap.parse_args(argv)

        rules = load_rules()
        if args.list_rules:
            for r in sorted(rules, key=lambda r: (-r.priority, r.id)):
                print(f"{r.id:28} {r.title}{c('2', '  (yours)') if r.user else '''}")
            print(c("2", f"\n{len(rules)} rules. Built-in: {BUILTIN_RULES}  Yours: {USER_RULES}"))
            return 0

        cfg = find_config(args.config, args.host)

        text, source = None, ""
        if args.log and args.log != "-":
            text, source = Path(args.log).read_text(errors="replace"), f"read from {args.log}"
        elif args.log == "-" or not sys.stdin.isatty():
            text, source = sys.stdin.read(), "read from piped input"
            if not text.strip():
                text = None
        if text is None:
            if cfg.problem:
                print(c("33", "\n? Couldn't find your config to re-check."))
                print(wrap(f"{cfg.problem} Point nixed-error at it with --config (a flake folder, path#host, or "
                           "a configuration.nix), or pipe in the output of the failed rebuild:", "  "))
                print("\n    sudo nixos-rebuild switch 2>&1 | nixed-error\n")
                return 2
            text, source = reproduce(cfg)
            if text is None:
                switch = ("nh os switch" if os.environ.get("NH_OS_FLAKE") or shutil.which("nh")
                          else "sudo nixos-rebuild switch")
                print(c("32", "\n✓ Couldn't reproduce a failure."))
                print(wrap("Your config evaluates, nothing that needs building has a failed log, and no "
                           "systemd units are in a failed state. If the rebuild failed while switching "
                           "(for example installing the bootloader), pipe its output in instead:", "  "))
                print(f"\n    {switch} 2>&1 | nixed-error\n")
                return 0

        flake = Flake(str(cfg.dir) if cfg.dir else None, load_inputs=not args.rule_id and cfg.kind == "flake")
        rep = analyze(text, flake, rules)
        rep.source = source
        if args.rule_id:
            print(rep.rule_id or "unknown", rep.blame)
            return 0
        if rep.rule_id is None:
            rep.saved_to = save_unknown(text)
        print_report(rep, args.verbose)
        return 1


    if __name__ == "__main__":
        try:
            sys.exit(main())
        except KeyboardInterrupt:
            sys.exit(130)
  '';

  # --- share/nixed-error/rules.toml: the built-in rules ---------------------
  rules = writeText "rules.toml" ''
    # nixed-error rules
    #
    # Each [[rule]] recognises one kind of Nix error. When several rules match, the highest
    # `priority` wins. Your own rules go in ~/.config/nixed-error/rules.toml with the same format;
    # a rule there with the same `id` replaces the built-in one.
    #
    #   id        unique name
    #   title     one-line headline
    #   match     regex (Python syntax) run against each `error:` block. Named groups like
    #             (?P<name>...) become {{name}} in the texts below.
    #   priority  0-100, default 50
    #   blame     you | upstream | system | auto (auto = decide from where the error points)
    #   explain   what happened, in plain words
    #   fix       what to do about it
    #   locate    list of texts to search for in your .nix files to find the exact line (first hit wins;
    #             a text naming a {{var}} that isn't set is skipped)
    #   locate_regex  true = the locate texts are regexes; {{vars}} are inserted escaped
    #   requires  regex that must also appear somewhere in the output (e.g. in trace context)
    #   handler   built-in detective work: semicolon | brackets | build | missing_module | ...
    #   scope     error (default) | log (only for build logs) | both
    #
    # Available in texts: every named group, plus {{file}}, {{line}}, {{input}}, {{note}},
    # {{opt_last}} (last part of an option name) and {{pname}} (package name without version).
    # Write regexes in ''''literal strings'''' so backslashes and quotes need no escaping.

    # ─── syntax ──────────────────────────────────────────────────────────────────

    [[rule]]
    id = "missing-semicolon"
    title = "Missing semicolon"
    match = ''''syntax error, unexpected (?!end of file|'[\]})]').+, expecting ';'$''''
    priority = 90
    blame = "you"
    handler = "semicolon"
    explain = """
    Line {{fix_line}} of {{file}} needs a `;` at the end. Every `name = value` inside { } must end with one.

    {{note}}
    """
    fix = "Add `;` at the end of line {{fix_line}}."

    [[rule]]
    id = "missing-opener"
    title = "Missing opening bracket"
    match = ''''syntax error, unexpected '(?P<got>[\]})])''''''
    priority = 91
    blame = "you"
    handler = "stray_closer"
    explain = """
    {{explain_text}}

    {{note}}
    """
    fix = "{{fix_text}}"

    [[rule]]
    id = "missing-closer"
    title = "Missing closing bracket"
    match = ''''syntax error, unexpected ';''''''
    priority = 85
    blame = "you"
    handler = "semicolon_inside"
    explain = "{{explain_text}}"
    fix = "{{fix_text}}"

    [[rule]]
    id = "setting-in-list"
    title = "Setting inside a list"
    match = ''''syntax error, unexpected '='$''''
    priority = 86
    blame = "you"
    handler = "equals_inside"
    explain = """
    {{explain_text}}

    {{note}}
    """
    fix = "{{fix_text}}"

    [[rule]]
    id = "value-without-name"
    title = "Value outside its list"
    match = ''''syntax error, unexpected [^\n]*, expecting '\.' or '=''''''
    priority = 86
    blame = "you"
    handler = "bare_word"
    explain = """
    {{explain_text}}

    {{note}}
    """
    fix = "{{fix_text}}"

    [[rule]]
    id = "list-comma"
    title = "Comma in a list"
    match = ''''syntax error, unexpected ','(?!.*expecting '[;}]')''''
    priority = 85
    blame = "you"
    handler = "brackets"
    explain = """
    Nix lists are separated by spaces, not commas: `[ pkgs.git pkgs.vim ]`, not `[ pkgs.git, pkgs.vim ]`.
    Commas only belong in function arguments like `{ pkgs, lib, ... }:`.

    {{note}}
    """
    fix = "Remove the comma(s) on line {{line}} and separate the items with spaces."

    [[rule]]
    id = "unexpected-eof"
    title = "Something is never closed"
    match = ''''syntax error, unexpected end of file''''
    priority = 90
    blame = "you"
    handler = "brackets"
    explain = """
    Nix reached the end of {{file}} while something was still open: a `{`, `[`, `(` or a string.

    {{note}}
    """
    fix = "Add the missing closing bracket or quote. Nix's own line number points at the end of the file, which is rarely where it belongs."

    [[rule]]
    id = "syntax-error"
    title = "Syntax error"
    match = ''''syntax error, unexpected (?P<got>[^\n]+?)(?:, expecting (?P<want>[^\n]+))?$''''
    priority = 80
    blame = "you"
    handler = "brackets"
    explain = """
    Nix couldn't read {{file}} near line {{line}}: it found {{got}} where it didn't make sense.
    Common causes: a missing `;` on the line before, an extra or missing `}` / `]`, or `=` used inside a list.

    {{note}}
    """
    fix = "Look at line {{line}} and the line just above it."

    # ─── names that don't exist ──────────────────────────────────────────────────

    [[rule]]
    id = "undefined-module-arg"
    title = "Module is missing an argument"
    match = ''''undefined variable '(?P<name>pkgs|lib|config|options|modulesPath|inputs|specialArgs|osConfig)\''''''
    priority = 75
    blame = "you"
    handler = "module_arg"
    explain = """
    {{file}} uses `{{name}}`, but the module doesn't ask for it. A module only gets the arguments listed
    on its first line.

    {{note}}
    """
    fix = """
    Change the first line of {{file}} to:
        {{header_new}}
    """

    [[rule]]
    id = "undefined-variable"
    title = "Unknown name"
    match = ''''undefined variable '(?P<name>[^']+)\''''''
    priority = 70
    blame = "you"
    handler = "unknown_name"
    explain = """
    `{{name}}` isn't defined anywhere Nix can see from line {{line}}.

    {{note}}
    """
    fix = "{{fix_text}}"

    [[rule]]
    id = "attribute-missing"
    title = "Name not found"
    match = ''''attribute '(?P<name>[^']+)' missing''''
    priority = 70
    explain = """
    Something tried to use `{{name}}`, but it doesn't exist there. If it's a package: it's misspelled, it was
    renamed or removed in your version of nixpkgs, or it lives under a sub-set (like `pkgs.kdePackages.{{name}}`).
    """
    fix = "Check the spelling. Search for the right name with `nix search nixpkgs {{name}}` or on search.nixos.org."

    [[rule]]
    id = "missing-module"
    title = "Module isn't defined anywhere"
    # flake-parts style: `config.flake.modules.nixos.foo` (or self.modules / nixosModules) where nothing sets foo.
    # Nix's code snippet must show the name under such a path, or it's an ordinary missing attribute.
    match = ''''attribute '(?P<name>[^']+)' missing\n\s*at [^\n]+\n(?:[^\n]*\n)*?\s*\d+\|[^\n]*?\b(?P<prefix>(?:flake|self)\.modules\.(?P<class>[\w-]+)|(?P<class2>nixos|home|homeManager|darwin)Modules)\.(?P=name)\b''''
    priority = 75
    blame = "you"
    handler = "missing_module"
    explain = """
    {{explain_text}}

    {{note}}
    """
    fix = "{{fix_text}}"

    [[rule]]
    id = "package-renamed-or-removed"
    title = "Package or option was renamed or removed"
    # "The ‘gnome.gedit’ alias was removed": the name is the quoted word, not "alias"
    match = ''''(?P<msg>(?:The )?[‘'`"]?(?P<name>[\w.+-]+)[’'`"]?(?: (?:alias|package|attribute))? (?:has been|was) (?:removed|renamed|replaced|dropped|moved)[^\n]*)''''
    priority = 75
    blame = "you"
    # a real use (pkgs.foo, or programs.foo when its `package` option failed) beats the name as a bare word;
    # the bare word must not be part of a longer name (flake.modules.nixos.foo, foo.nix, foo-bar)
    locate = [
      ''''pkgs\.{{name}}(?![\w-])'''',
      ''''(?<![\w.-]){{pkg_option}}(?![\w-])'''',
      ''''(?<![\w.-]){{name}}(?![\w.-])'''',
    ]
    locate_regex = true
    # the handler writes the texts: a module (programs.foo) needs different advice from a plain pkgs.foo
    handler = "removed_pkg"
    explain = "{{explain_text}}"
    fix = "{{fix_text}}"

    # ─── NixOS options (the module system) ───────────────────────────────────────

    [[rule]]
    id = "option-not-exist"
    title = "That option doesn't exist"
    match = ''''The option `(?P<option>[^']+)' does not exist''''
    priority = 80
    blame = "you"
    locate = ["{{opt_tail2}}", "{{opt_last}}"]
    explain = """
    NixOS has no option called `{{option}}`. Either it's misspelled, it was renamed or removed in your
    NixOS version, or it belongs to a module you haven't imported (a home-manager option in your NixOS
    config, or the other way round, is a classic).
    """
    fix = "Fix the name on line {{line}}. Look it up on search.nixos.org/options, or with `man configuration.nix`."

    [[rule]]
    id = "option-removed"
    title = "Option was removed from NixOS"
    match = ''''The option definition `(?P<option>[^']+)' in `[^']+' no longer has any effect; please remove it\.(?P<why>[^\n]*(?:\n\s+[^-\s][^\n]*)*)''''
    priority = 85
    blame = "you"
    locate = ["{{opt_tail2}}", "{{opt_last}}"]
    explain = """
    `{{option}}` used to exist but was removed in this NixOS version. NixOS's reason:
    {{why}}
    """
    fix = "Delete the `{{option}}` line in {{file}} (and add its replacement if the reason mentions one)."

    [[rule]]
    id = "option-renamed"
    title = "Option was renamed"
    match = ''''The option `(?P<option>[^']+)' (?:defined in `[^']+' )?has been renamed to `(?P<new>[^']+)'\.?''''
    priority = 85
    blame = "you"
    locate = ["{{opt_tail2}}", "{{opt_last}}"]
    explain = "`{{option}}` is now called `{{new}}`."
    fix = "Rename it to `{{new}}` in {{file}}."

    [[rule]]
    id = "option-wrong-type"
    title = "Wrong kind of value for an option"
    match = ''''A definition for option `(?P<option>[^']+)' is not of type `(?P<type>[^\n]+?)'\. Definition values:''''
    priority = 80
    blame = "you"
    locate = ["{{opt_tail2}}", "{{opt_last}}"]
    explain = """
    `{{option}}` expects: {{type}}.
    The value you gave is something else. Typical mix-ups: a list `[ ]` where a single string is wanted (or
    the reverse), a missing pair of quotes, or `true` written as `"true"`.
    """
    fix = """
    Change the value on line {{line}} to the expected kind. What you gave:
    {{definitions}}
    """

    [[rule]]
    id = "option-conflict"
    title = "Option is set to two different values"
    match = ''''The option `(?P<option>[^']+)' (?:has conflicting definition values|is defined multiple times)''''
    priority = 80
    blame = "you"
    locate = ["{{opt_tail2}}", "{{opt_last}}"]
    explain = """
    `{{option}}` is set in more than one place with different values, and it can only have one:
    {{definitions}}
    """
    fix = "Remove one of them, or force yours to win: `{{option}} = lib.mkForce <value>;`"

    [[rule]]
    id = "option-no-value"
    title = "A required option isn't set"
    match = ''''The option `(?P<option>[^']+)' (?:is used but not defined|was accessed but has no value defined)''''
    priority = 80
    blame = "you"
    locate = ["{{opt_tail2}}", "{{opt_parent}}"]
    explain = "Something needs `{{option}}`, but nothing sets it, and it has no default."
    fix = "Set `{{option}} = ...;` in your config."

    [[rule]]
    id = "failed-assertion"
    title = "A module refused your config"
    match = ''''Failed assertions:\s*\n(?P<list>(?:\s*- [^\n]*\n?(?:\s{3,}[^-\s][^\n]*\n?)*)+)''''
    priority = 60
    blame = "you"
    handler = "assertion"
    explain = """
    A NixOS module checked your settings and found a combination that can't work. Its message is
    usually exact:
    {{list}}
    """
    fix = "Do what the message above asks. The line shown is where one of the options it names is set."

    [[rule]]
    id = "infinite-recursion-imports"
    title = "Infinite recursion: `config` used inside `imports`"
    match = ''''infinite recursion encountered''''
    requires = ''''you probably reference `config` in `imports`''''
    priority = 80
    blame = "you"
    explain = """
    `imports` is decided before `config` exists, so `imports` can't depend on `config`
    (e.g. `imports = lib.optional config.foo.enable ./bar.nix;`).
    """
    fix = "Import the file unconditionally and put `lib.mkIf config.foo.enable { ... }` inside it instead."

    [[rule]]
    id = "infinite-recursion"
    title = "Infinite recursion"
    match = ''''infinite recursion encountered''''
    priority = 70
    blame = "you"
    explain = """
    Something in your config depends on itself. Common causes: using `config.x` to define `x`, using
    `pkgs` inside `nixpkgs.overlays`/`nixpkgs.config`, or `rec { a = a; }`. The place shown is the last of your
    files Nix passed through, which is a good place to start.
    """
    fix = "Look for a value that (indirectly) refers to itself around line {{line}}."

    # ─── packages that refuse to evaluate ────────────────────────────────────────

    [[rule]]
    id = "unfree"
    title = "Package is unfree and not allowed"
    match = ''''(?:Refusing to evaluate package|Package) [‘'](?P<pkg>[^’']+)[’'][^\n]*(?:because it has an unfree license|has an unfree license)''''
    priority = 85
    blame = "you"
    # the handler finds what pulls the package in (pkgs.foo, or a driver/module like videoDrivers = [ "nvidia" ])
    # and an `allowUnfree = false` or `allowUnfreePredicate` that blocks it
    handler = "unfree"
    explain = "{{explain_text}}"
    fix = "{{fix_text}}"

    [[rule]]
    id = "insecure"
    title = "Package is marked insecure"
    match = ''''Package [‘'](?P<pkg>[^’']+)[’'][^\n]*is marked as insecure''''
    priority = 85
    blame = "upstream"
    explain = "`{{pkg}}` has known security problems, so nixpkgs refuses to build it without your permission. Something you use depends on it."
    fix = """
    Prefer an alternative if there is one. To accept the risk:
        nixpkgs.config.permittedInsecurePackages = [ "{{pkg}}" ];
    """

    [[rule]]
    id = "broken"
    title = "Package is marked broken"
    match = ''''Package [‘'](?P<pkg>[^’']+)[’'][^\n]*is marked as broken''''
    priority = 85
    blame = "upstream"
    explain = "nixpkgs maintainers have marked `{{pkg}}` as broken in your nixpkgs version, so it won't build."
    fix = "Wait for a fix and update your flake, remove it for now, or try anyway with `nixpkgs.config.allowBroken = true;`."

    [[rule]]
    id = "unsupported-platform"
    title = "Package isn't available on this system"
    match = ''''Package [‘'](?P<pkg>[^’']+)[’'][^\n]*is not available on the requested hostPlatform''''
    priority = 85
    blame = "you"
    locate = ["{{pname}}"]
    explain = "`{{pkg}}` doesn't support your CPU/OS (for example it's x86-only, or macOS-only)."
    fix = "Remove it or use an alternative."

    # ─── flakes & files ──────────────────────────────────────────────────────────

    [[rule]]
    id = "untracked-file"
    title = "New file isn't added to git"
    match = ''''Path '(?P<path>[^']+)' in the repository "(?P<repo>[^"]+)" is not tracked by Git''''
    priority = 95
    blame = "you"
    explain = """
    Flakes only see files git knows about. `{{path}}` exists, but you never ran `git add` on it,
    so to Nix it doesn't exist.
    """
    fix = """
        git -C {{repo}} add {{path}}
    (It doesn't have to be committed, just added.)
    """

    [[rule]]
    id = "file-missing-in-flake"
    title = "File not found (probably not added to git)"
    match = ''''getting status of '/nix/store/[^']+?-source/(?P<path>[^']+)': No such file or directory''''
    priority = 85
    blame = "you"
    explain = "Nix can't find `{{path}}` in your flake. Either the path is misspelled, or the file is new and not `git add`-ed yet (flakes ignore untracked files)."
    fix = "Check the path, then `git add {{path}}` in your flake folder."

    [[rule]]
    id = "path-not-exist"
    title = "File or folder doesn't exist"
    match = ''''path '(?P<path>[^']+)' does not exist''''
    priority = 70
    blame = "you"
    explain = "Your config refers to `{{path}}`, which doesn't exist. Check for a typo, a wrong relative path (`./` is relative to the file it's written in), or a file not yet added to git."
    fix = "Fix the path on line {{line}}."

    [[rule]]
    id = "host-not-in-flake"
    title = "No configuration with that name in your flake"
    match = ''''flake '(?P<flake>[^']+)' does not provide attribute '(?P<attr>[^']+)'(?P<rest>[^\n]*)''''
    priority = 90
    blame = "you"
    explain = """
    Your flake has no `{{attr}}`. For NixOS this usually means the name under `nixosConfigurations.<name>`
    in flake.nix doesn't match your hostname (or what NH_OS_FLAKE / --hostname says).
    """
    fix = "Make the name in flake.nix match `hostname`, or pass it explicitly: `nh os switch -H <name>`."

    [[rule]]
    id = "lock-file-needs-update"
    title = "flake.lock needs to change"
    match = ''''(?:requires lock file changes but they're not allowed|cannot write modified lock file)''''
    priority = 80
    blame = "you"
    explain = "You added or changed an input in flake.nix, but flake.lock can't be updated in this mode."
    fix = "Run `nix flake lock` (or `nix flake update <input>`) in your flake folder."

    [[rule]]
    id = "experimental-feature"
    title = "Flakes / nix-command not enabled"
    match = ''''experimental Nix feature '(?P<feature>[^']+)' is disabled''''
    priority = 90
    blame = "system"
    explain = "The `{{feature}}` feature is off in this Nix."
    fix = "Add `nix.settings.experimental-features = [ \"nix-command\" \"flakes\" ];` to your config."

    # ─── type errors in Nix code ─────────────────────────────────────────────────

    [[rule]]
    id = "wrong-type"
    title = "Wrong kind of value"
    match = ''''(?:expected a (?P<want>[\w ]+?) but found (?P<got>[^:\n]+)|value is (?P<got2>[^\n]+?) while an? (?P<want2>[\w ]+?) was expected)''''
    priority = 60
    explain = """
    Nix needed {{want}}{{want2}} but got {{got}}{{got2}}. Typical: a string where a list is wanted (missing `[ ]`),
    a function that wasn't called with its argument, or a package set where a single package is wanted.
    """
    fix = "Check the value on line {{line}}."

    [[rule]]
    id = "not-a-function"
    title = "Called something that isn't a function"
    match = ''''attempt to call something which is not a function but (?P<got>[^:\n]+)''''
    priority = 65
    explain = """
    Nix read something on line {{line}} as a function call. Often two values next to each other without
    something between them (a missing `;`, or a missing `++` between two lists), or a stray argument.
    """
    fix = "Look at line {{line}} for two values side by side."

    [[rule]]
    id = "cannot-coerce"
    title = "Can't turn that into text"
    match = ''''cannot coerce (?P<got>[^\n]+?) to a string''''
    priority = 60
    explain = "Something tried to use {{got}} as text (for example inside \"''${...}\"), but that kind of value can't become text."
    fix = "Use the right part of it (e.g. `''${pkg}` for a package path, `toString x` for a number, `lib.concatStringsSep` for lists)."

    [[rule]]
    id = "missing-function-arg"
    title = "Function called without a required argument"
    match = ''''function '(?P<fn>[^']*)' called without required argument '(?P<arg>[^']+)\''''''
    priority = 70
    explain = """
    `{{fn}}` needs an argument called `{{arg}}` but didn't get it. In a module: `{{arg}}` isn't a normal
    module argument, so it must be passed via `specialArgs` / `extraSpecialArgs` in flake.nix. With
    `callPackage`: nothing named `{{arg}}` exists in pkgs.
    """
    fix = "Pass `{{arg}}` in, or remove it from the function's argument list."

    [[rule]]
    id = "unexpected-function-arg"
    title = "Function got an argument it doesn't accept"
    match = ''''function '(?P<fn>[^']*)' called with unexpected argument '(?P<arg>[^']+)\''''''
    priority = 70
    explain = "`{{fn}}` doesn't take an argument called `{{arg}}`. Probably a typo, or an argument that was renamed in a newer version."
    fix = "Check the spelling of `{{arg}}`, or add `...` to the function's argument list if it should accept extras."

    [[rule]]
    id = "stack-overflow"
    title = "Evaluation went too deep"
    match = ''''(?:stack overflow|max-call-depth exceeded)''''
    priority = 60
    explain = "Evaluation recursed too deep. Almost always an infinite loop in a function or overlay that keeps calling itself."
    fix = "Look for something that refers to itself, starting at the place shown."

    # ─── building ────────────────────────────────────────────────────────────────

    [[rule]]
    id = "hash-mismatch"
    title = "Hash doesn't match the download"
    match = ''''hash mismatch in fixed-output derivation '(?P<drv>[^']+)':\s*specified:\s*(?P<specified>\S+)\s*got:\s*(?P<got>\S+)''''
    priority = 90
    locate = ["{{specified}}"]
    explain = """
    A download didn't match the hash written in the Nix file. If the hash is in your config, you either
    used a placeholder (that's normal: Nix tells you the real one) or the source changed.
    """
    fix = """
    Replace the hash with the one Nix got:
        {{got}}
    """

    [[rule]]
    id = "build-failure"
    title = "A package failed to build"
    match = ''''(?:Cannot build|builder for) '(?P<drv>/nix/store/[^']+\.drv)'(?:\.\s*Reason: builder failed| failed)''''
    priority = 60
    handler = "build"
    explain = """
    `{{name}}` failed while building.

    {{owner_note}}
    """
    fix = """
    {{advice}}

    Full log: `nix log {{drv}}`
    """

    [[rule]]
    id = "dependency-failed"
    title = "A dependency failed to build"
    match = ''''(?:\d+ dependenc(?:y|ies) (?:of derivation '(?P<drv>[^']+)' )?failed(?: to build)?|Reason: \d+ dependenc(?:y|ies) failed)''''
    priority = 10
    blame = "unknown"
    explain = "Something your system needs failed to build. Nix's real error should be above this line in the output."
    fix = "Run with -v, or run nixed-error with no input so it can find the failed build log itself."

    [[rule]]
    id = "collision"
    title = "Two packages provide the same file"
    match = ''''collision between [`'](?P<a>[^'`]+)['`] and [`'](?P<b>[^'`]+)['`]''''
    priority = 75
    scope = "both"
    blame = "you"
    explain = "Two installed packages both contain the same file, so they can't both be in your profile:\n  {{a}}\n  {{b}}"
    fix = "Remove one of them, or give one priority: `(lib.hiPrio pkgs.<name>)` in your package list."

    # ─── causes found inside build logs ──────────────────────────────────────────

    [[rule]]
    id = "log-tests-failed"
    title = "The package's own tests failed"
    match = ''''(?i)(?:\b\d+ (?:tests? )?failed\b|test suite failed|tests? failed|FAILED \(failures?=)''''
    priority = 50
    scope = "log"
    blame = "upstream"
    explain = "The package compiled, but its test suite failed. Usually a bug in nixpkgs or flaky tests, not your config."
    fix = """
    Wait for a fix, or skip the tests with an overlay:
        nixpkgs.overlays = [ (final: prev: { {{pname}} = prev.{{pname}}.overrideAttrs { doCheck = false; }; }) ];
    """

    [[rule]]
    id = "log-out-of-memory"
    title = "Ran out of memory while building"
    match = ''''(?i)(?:out of memory|cannot allocate memory|virtual memory exhausted|Killed\s+(?:signal 9|.*cc1)|killed by the OOM)''''
    priority = 80
    scope = "log"
    blame = "system"
    explain = "The build used more RAM than you have. Big packages (browsers, compilers) do this when building from source."
    fix = "Build with fewer jobs: `nh os switch -- --cores 2 --max-jobs 1`, add swap/zram, or use a version that's in the binary cache."

    # ─── your machine ────────────────────────────────────────────────────────────

    [[rule]]
    id = "disk-full"
    title = "Disk is full"
    match = ''''No space left on device''''
    priority = 95
    scope = "both"
    blame = "system"
    explain = "A disk filled up during the rebuild. Often /nix/store, or the /boot partition (which only fits a few kernels)."
    fix = """
    Free space with `nh clean all --keep 3` (or `sudo nix-collect-garbage -d`), then check `df -h / /boot`.
    If /boot is full, set `boot.loader.systemd-boot.configurationLimit = 5;` and rebuild.
    """

    [[rule]]
    id = "network"
    title = "Download failed (network)"
    match = ''''(?:unable to download|Could(?:n't| not) resolve host|Connection timed out|SSL connect error|Failed to connect to|HTTP error 50\d|error: cannot connect to socket)''''
    priority = 85
    scope = "both"
    blame = "system"
    explain = "Nix couldn't download something. Your internet connection, DNS, or the server itself had a problem."
    fix = "Check your connection and try again. If one server is down, `--option substituters https://cache.nixos.org` can help."

    [[rule]]
    id = "bootloader"
    title = "Installing the bootloader failed"
    match = ''''(?:Failed to install bootloader|install-grub\.pl.*failed|bootctl.*(?:failed|error))''''
    priority = 80
    blame = "system"
    explain = "The new system was built, but writing it to the boot partition failed. Most often /boot is full or not mounted."
    fix = "Check `df -h /boot` and `findmnt /boot`. Limit generations with `boot.loader.systemd-boot.configurationLimit = 5;`."

    [[rule]]
    id = "hm-file-in-the-way"
    title = "home-manager won't overwrite an existing file"
    match = ''''Existing file '(?P<file>[^']+)' would be clobbered$''''
    priority = 90
    blame = "system"
    handler = "hm_file"
    explain = """
    home-manager wants to manage {{files}}, but {{already}}, and it won't delete {{it}}. Nothing
    in your config is wrong: something (you, or the program itself) wrote {{it_file}} where home-manager puts its links.
    """
    fix = """
    Move {{it}} away and run home-manager again:
    {{moves}}
        {{rerun}}

    Or let home-manager move such files aside by itself from now on:
        home-manager.backupFileExtension = "backup";

    {{rerun_note}}
    """

    [[rule]]
    id = "hm-backup-exists"
    title = "home-manager's backup file is already taken"
    match = ''''Existing file '(?P<backup>[^']+)' would be clobbered by backing up '(?P<file>[^']+)''''''
    priority = 91
    blame = "system"
    handler = "hm_file"
    explain = """
    A normal file is in the way of {{files}}. Your config sets `home-manager.backupFileExtension`, so
    home-manager tries to rename it to {{backups}}, but a backup by that name is already there{{backup_age}}, and
    home-manager won't overwrite it.
    """
    fix = """
    Look at both files and keep what you need, then delete the old backup and run home-manager again:
    {{removes}}
        {{rerun}}

    Or let home-manager replace old backups from now on:
        home-manager.overwriteBackup = true;

    {{rerun_note}}
    """

    [[rule]]
    id = "unit-failed"
    title = "A service failed after switching"
    match = ''''^error: unit (?P<unit>\S+) failed''''
    priority = 5
    blame = "unknown"
    explain = """
    Your config built fine, but the service `{{unit}}` is in a failed state. It may or may not be from your last
    rebuild. The end of its log is shown below.
    """
    fix = "See the full log with `journalctl -b -u {{unit}}` (or `--user-unit` for user services)."
  '';
in
stdenvNoCC.mkDerivation {
  pname = "nixed-error";
  version = "0.1.0";

  dontUnpack = true;
  dontBuild = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    install -Dm644 ${script} $out/share/nixed-error/nixed_error.py
    install -Dm644 ${rules} $out/share/nixed-error/rules.toml

    # nix, systemctl and journalctl come from the running system. git is only a
    # fallback (--suffix), since a fresh NixOS install doesn't ship it.
    makeWrapper ${python3.interpreter} $out/bin/nixed-error \
      --add-flags $out/share/nixed-error/nixed_error.py \
      --suffix PATH : ${lib.makeBinPath [ git ]}

    runHook postInstall
  '';

  meta = with lib; {
    description = "Explain failed NixOS rebuilds in plain words";
    platforms = platforms.linux;
    mainProgram = "nixed-error";
  };
}
