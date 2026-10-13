#!/usr/bin/env bash
# Detect bash forms whose failure is silent and whose shape is mechanically recognisable.
# Findings are non-blocking lint warnings; rationale and fix direction per rule:
# skills/lint/references/plugin-checks-rationale.md ("Bash pitfall check").
#
# Rules:
#   grep-c-echo-fallback  a zero-fallback (echo or printf) inside a `grep -c` substitution captures "0\n0" on no match
#   if-bang-rc            `if ! cmd; then ... $?` reads the negated status, always 0
#   nested-mktemp-cd      `cd "$(mktemp ...)"`: a failed mktemp makes it `cd ""`, a no-op
#   sed-inplace-gnu       `sed -i` without an attached suffix: GNU and BSD disagree on the argument form
#   pipestatus-subst      `v=$(a | b)` then `${PIPESTATUS[...]}`: it holds the substitution's own status, not the stages'
#
# Scan scope: plugins/rite/{hooks,scripts}/**/*.sh excluding tests/ (fixtures embed the
# patterns deliberately), and fenced code blocks of plugins/rite/**/*.md. Comment lines are
# skipped. Exclusion marker: `drift-check-ignore` on the finding line or the line above.
#
# Usage: bash-pitfall-check.sh --all [--repo-root DIR] [--quiet] [--skip-if-no-target]
#        bash-pitfall-check.sh --target FILE [--target FILE ...] [--repo-root DIR] [--quiet]
# Exit: 0 clean, 1 findings, 2 invocation error or a file or directory that could not be scanned.
set -uo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  printf '%s\n' 'ERROR: python3 is required for bash-pitfall-check.sh' >&2
  exit 2
fi

python3 - "$@" <<'PY'
import os, re, sys

args = sys.argv[1:]; root = ""; use_all = False; quiet = False; skip = False; targets = []
i = 0
while i < len(args):
    a = args[i]
    if a == "--all": use_all = True; i += 1
    elif a == "--quiet": quiet = True; i += 1
    elif a == "--skip-if-no-target": skip = True; i += 1
    elif a == "--target" and i + 1 < len(args): targets.append(args[i + 1]); i += 2
    elif a == "--repo-root" and i + 1 < len(args): root = args[i + 1]; i += 2
    elif a in ("-h", "--help"):
        print("Usage: bash-pitfall-check.sh --all|--target FILE [--repo-root DIR] [--quiet] [--skip-if-no-target]")
        sys.exit(0)
    else:
        print(f"ERROR: unknown or incomplete argument: {a}", file=sys.stderr); sys.exit(2)
root = os.path.abspath(root or os.popen("git rev-parse --show-toplevel 2>/dev/null").read().strip() or os.getcwd())
if not os.path.isdir(root):
    print(f"ERROR: repository root is not a directory: {root}", file=sys.stderr); sys.exit(2)
if not use_all and not targets:
    print("ERROR: no targets specified (use --all or --target FILE)", file=sys.stderr); sys.exit(2)

plugin = os.path.join(root, "plugins/rite")
if use_all:
    if not os.path.isdir(plugin):
        if skip:
            print("Total bash-pitfall findings: 0", file=sys.stderr); sys.exit(0)
        print(f"ERROR: --all requested but plugins/rite does not exist under {root}", file=sys.stderr); sys.exit(2)
    walk_errors = {}
    def walk(top):
        return os.walk(top, onerror=lambda e: walk_errors.setdefault(e.filename, e))
    for base in ("hooks", "scripts"):
        if not os.path.isdir(os.path.join(plugin, base)): continue
        for d, dirs, files in walk(os.path.join(plugin, base)):
            dirs[:] = sorted(x for x in dirs if x != "tests")
            targets += [os.path.relpath(os.path.join(d, f), root) for f in sorted(files) if f.endswith(".sh")]
    for d, dirs, files in walk(plugin):
        dirs.sort()
        targets += [os.path.relpath(os.path.join(d, f), root) for f in sorted(files) if f.endswith(".md")]
    for e in walk_errors.values():
        print(f"WARNING: cannot list {e.filename}: {e.strerror} — not scanned", file=sys.stderr)

# `tok` = one shell word fragment of a grep invocation (no `;` `)` `|` unless quoted)
tok = r"""(?:[^|);'"]|'[^']*'|"[^"]*")"""
GREP_C = re.compile(r"grep(?: +%s*)? +(?:-[A-Za-z]*c[A-Za-z]*|--count) %s*\|\| *(?:\{ *)?(?:echo|printf) +[\"']?0" % (tok, tok))
MKTEMP_CD = re.compile(r"""\bcd\s+(?:--\s+)?["']?\$\(\s*mktemp\b""")
SED_I = re.compile(r"""\bsed\s+(?:-[A-Za-z]+\s+)*(?:-i|--in-place)(?![.\w=])""")
IF_BANG = re.compile(r"^\s*(?:if|elif)\s+!\s")
PIPE_SUBST = re.compile(r"=\$\([^)]*\|")
IGNORE = "drift-check-ignore"

findings = []; unscannable = len(walk_errors) if use_all else 0

BANG_MSG = "`$?` read as the first statement of an `if !` body is the negated status (always 0); use `cmd || rc=$?` with `rc=0` before, or read it in the `else` of a positive `if cmd`"

def first_segment(text):
    return re.split(r";|&&|\|\|", text, maxsplit=1)[0]

def scan(rel, numbered):
    """numbered: list of (line number, text). Reports the original line numbers."""
    prev = ""; bang = None   # bang: None, or ("then", budget) / ("body", 0)
    for n, line in numbered:
        if line.strip().startswith("#"):
            prev = line; continue
        marked = IGNORE in line or IGNORE in prev
        def add(rule, msg):
            if not marked: findings.append(f"[bash-pitfall] {rel}:{n}: {rule}: {msg}")
        if GREP_C.search(line):
            add("grep-c-echo-fallback", "`grep -c` already prints 0 on no match; keep the fallback outside the substitution (`cnt=$(... | grep -c .) || cnt=0`) or use `|| true` with `${cnt:-0}`")
        if MKTEMP_CD.search(line):
            add("nested-mktemp-cd", "a failed mktemp turns this into `cd \"\"` (no-op); create the directory in its own step and stop on failure")
        if SED_I.search(line):
            add("sed-inplace-gnu", "`-i` without an attached suffix is accepted by only one of GNU / BSD sed (an empty-string argument is BSD-only). Write to a temp file and `mv`, or use `-i.bak`")
        before_ps = line.split("PIPESTATUS", 1)[0]
        if ("PIPESTATUS" in line and ((PIPE_SUBST.search(before_ps) and ")" in before_ps) or (PIPE_SUBST.search(prev) and "|" not in before_ps))):
            add("pipestatus-subst", "PIPESTATUS read after `$( )` holds the substitution's own status, not the pipeline stages'; capture the status inside the substitution or split the pipeline")
        # if-bang-rc: only the first statement of the then-body is judged
        if IF_BANG.match(line):
            m = re.search(r"\bthen\b(.*)$", line)
            if m and m.group(1).strip() and not m.group(1).strip().startswith("#"):
                if "$?" in first_segment(m.group(1)): add("if-bang-rc", BANG_MSG)
                bang = None
            else:
                bang = ("then", 3) if not m else ("body", 0)
        elif bang is not None and line.strip():
            body = line.strip()
            if bang[0] == "then":
                m = re.match(r"then\b(.*)$", body)
                if m:
                    rest = m.group(1).strip()
                    if rest and not rest.startswith("#"):
                        if "$?" in first_segment(rest): add("if-bang-rc", BANG_MSG)
                        bang = None
                    else:
                        bang = ("body", 0)
                else:
                    bang = ("then", bang[1] - 1) if bang[1] > 1 else None
            else:
                if "$?" in first_segment(body): add("if-bang-rc", BANG_MSG)
                bang = None
        prev = line

fence_open = re.compile(r"^(\s*)(`{3,}|~{3,})(.*)$")
for rel in targets:
    path = os.path.join(root, rel)
    if not rel.endswith((".sh", ".md")):
        print(f"WARNING: unsupported file type, not scanned: {rel}", file=sys.stderr); unscannable += 1; continue
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read().split("\n")
    except OSError as e:
        print(f"WARNING: cannot read {rel}: {e} — not scanned", file=sys.stderr); unscannable += 1; continue
    if rel.endswith(".sh"):
        scan(rel, list(enumerate(text, 1))); continue
    in_fence = False; ch = ""; ln = 0; open_indent = 0; blocks = []
    for n, line in enumerate(text, 1):
        m = fence_open.match(line)
        if m:
            run = m.group(2); indent = len(m.group(1).expandtabs(4))
            if not in_fence:
                in_fence = True; ch = run[0]; ln = len(run); open_indent = indent; blocks.append([]); continue
            # a closing fence has no info string, is at most 3 columns deeper than its opener, same character, at least as long
            if run[0] == ch and len(run) >= ln and m.group(3).strip() == "" and indent <= open_indent + 3:
                in_fence = False; continue
        if in_fence: blocks[-1].append((n, line))
    if in_fence:
        print(f"WARNING: unbalanced code fence in {rel} — file not scanned", file=sys.stderr); unscannable += 1; continue
    for block in blocks:
        scan(rel, block)

for f in findings: print(f)
if not quiet: print(f"Total bash-pitfall findings: {len(findings)}", file=sys.stderr)
if unscannable: print(f"ERROR: {unscannable} file(s) could not be scanned — this run is not a clean bill", file=sys.stderr)
sys.exit(1 if findings else (2 if unscannable else 0))
PY
