#!/usr/bin/env bash
# Detect bash forms whose failure is silent and whose shape is mechanically recognisable.
# Findings are non-blocking lint warnings; rationale and fix direction per rule:
# skills/lint/references/plugin-checks-rationale.md ("Bash pitfall check").
#
# Rules:
#   grep-c-echo-fallback  a zero-fallback (echo or printf) inside a `grep -c` substitution captures "0\n0" on no match
#   if-bang-rc            `if ! cmd; then ... $?` reads the negated status, always 0
#   nested-mktemp-cd      `cd "$(mktemp ...)"`: a failed mktemp makes it `cd ""`, a no-op
#   sed-inplace-gnu       `sed -i 'expr'` (no suffix argument) fails on BSD sed
#   pipestatus-subst      `v=$(a | b)` then `${PIPESTATUS[...]}`: the array is not set outside `$( )`
#
# Scan scope: plugins/rite/{hooks,scripts}/**/*.sh excluding tests/ (fixtures embed the
# patterns deliberately), and fenced code blocks of plugins/rite/**/*.md. Comment lines are
# skipped. Exclusion marker: `drift-check-ignore` on the finding line or the line above.
#
# Usage: bash-pitfall-check.sh --all [--repo-root DIR] [--quiet] [--skip-if-no-target]
#        bash-pitfall-check.sh --target FILE... [--repo-root DIR] [--quiet]
# Exit: 0 clean, 1 findings, 2 invocation error or a file that could not be scanned.
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
    for base in ("hooks", "scripts"):
        for d, dirs, files in os.walk(os.path.join(plugin, base)):
            dirs[:] = sorted(x for x in dirs if x != "tests")
            targets += [os.path.relpath(os.path.join(d, f), root) for f in sorted(files) if f.endswith(".sh")]
    for d, dirs, files in os.walk(plugin):
        dirs.sort()
        targets += [os.path.relpath(os.path.join(d, f), root) for f in sorted(files) if f.endswith(".md")]

# `tok` = one shell word fragment of a grep invocation (no `;` `)` `|` unless quoted)
tok = r"""(?:[^|);'"]|'[^']*'|"[^"]*")"""
GREP_C = re.compile(r"grep(?: +%s*)? +(?:-[A-Za-z]*c[A-Za-z]*|--count) %s*\|\| *(?:\{ *)?(?:echo|printf) +[\"']?0" % (tok, tok))
MKTEMP_CD = re.compile(r"""\bcd\s+(?:--\s+)?["']?\$\(\s*mktemp\b""")
SED_I = re.compile(r"""\bsed\s+(?:-[A-Za-z]+\s+)*(?:-i|--in-place)\s+(?!'')(?!"")\S""")
IF_BANG = re.compile(r"^\s*(?:if|elif)\s+!\s")
BLOCK_END = re.compile(r"^\s*(?:fi|else|elif|if)\b")
PIPE_SUBST = re.compile(r"=\$\([^)]*\|")
IGNORE = "drift-check-ignore"

findings = []; unscannable = 0

def scan(rel, lines):
    prev = ""; bang_armed = 0
    for n, line in enumerate(lines, 1):
        stripped = line.strip()
        if stripped.startswith("#"):
            prev = line; bang_armed = 0; continue
        marked = IGNORE in line or IGNORE in prev
        def add(rule, msg):
            if not marked: findings.append(f"[bash-pitfall] {rel}:{n}: {rule}: {msg}")
        if GREP_C.search(line):
            add("grep-c-echo-fallback", "`grep -c` already prints 0 on no match; keep the fallback outside the substitution (`cnt=$(... | grep -c .) || cnt=0`) or use `|| true` with `${cnt:-0}`")
        if MKTEMP_CD.search(line):
            add("nested-mktemp-cd", "a failed mktemp turns this into `cd \"\"` (no-op); create the directory in its own step and stop on failure")
        if SED_I.search(line):
            add("sed-inplace-gnu", "in-place sed without a suffix argument is GNU-only (BSD sed needs one). Write to a temp file and `mv`, or use `-i.bak`")
        if (PIPE_SUBST.search(line) and re.search(r"\)[^)]*PIPESTATUS", line)) or ("PIPESTATUS" in line and PIPE_SUBST.search(prev)):
            add("pipestatus-subst", "PIPESTATUS set inside `$( )` is not visible to the parent shell; capture status inside the substitution or split the pipeline")
        # if-bang-rc: look at the then-body of `if ! cmd; then`
        if IF_BANG.match(line):
            bang_armed = 4
            after = line.split("then", 1)[1] if re.search(r"\bthen\b", line) else ""
            if "$?" in after:
                add("if-bang-rc", "`$?` after `if !` is the negated status (always 0); use `cmd || rc=$?` with `rc=0` before, or `if cmd; then ... else rc=$?`")
        elif bang_armed:
            if BLOCK_END.match(line):
                bang_armed = 0
            else:
                bang_armed -= 1
                if "$?" in line:
                    add("if-bang-rc", "`$?` after `if !` is the negated status (always 0); use `cmd || rc=$?` with `rc=0` before, or `if cmd; then ... else rc=$?`")
        prev = line

fence_open = re.compile(r"^( {0,3})(`{3,}|~{3,})(.*)$")
for rel in targets:
    path = os.path.join(root, rel)
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read().split("\n")
    except OSError as e:
        print(f"WARNING: cannot read {rel}: {e} — not scanned", file=sys.stderr); unscannable += 1; continue
    if rel.endswith(".sh"):
        scan(rel, text); continue
    code = []; in_fence = False; ch = ""; ln = 0; blocks = []
    for n, line in enumerate(text, 1):
        m = fence_open.match(line)
        if m:
            run = m.group(2)
            if not in_fence:
                in_fence = True; ch = run[0]; ln = len(run); blocks.append([]); continue
            if run[0] == ch and len(run) >= ln and m.group(3).strip() == "":
                in_fence = False; continue
        if in_fence: blocks[-1].append((n, line))
    if in_fence:
        print(f"WARNING: unbalanced code fence in {rel} — file not scanned", file=sys.stderr); unscannable += 1; continue
    for block in blocks:
        # keep original line numbers by scanning per block and rewriting the reported number
        before = len(findings)
        scan(rel, [l for _, l in block])
        for k in range(before, len(findings)):
            m = re.match(r"(\[bash-pitfall\] [^:]+:)(\d+)(:.*)", findings[k])
            findings[k] = f"{m.group(1)}{block[int(m.group(2)) - 1][0]}{m.group(3)}"

for f in findings: print(f)
if not quiet: print(f"Total bash-pitfall findings: {len(findings)}", file=sys.stderr)
if unscannable: print(f"ERROR: {unscannable} file(s) could not be scanned — this run is not a clean bill", file=sys.stderr)
sys.exit(1 if findings else (2 if unscannable else 0))
PY
