#!/usr/bin/env bash
# Detect pipelines where grep -q can close early and SIGPIPE its immediate
# producer under `set -o pipefail`. Findings are non-blocking lint warnings.
#
# Precision rules:
# - shell quotes/comments are lexed before splitting raw `|` operators;
# - the immediate stage before grep is reported (not the pipeline head);
# - direct echo/printf -> grep and `{ ...; } -> grep` are exempt proxies for
#   bounded fixture/control output. Command name is only a proxy: an unbounded
#   printf can still SIGPIPE, so adding such a site requires removing the proxy
#   or inserting a real streaming stage; `drift-check-ignore` is the explicit
#   audited escape hatch;
# - `enable -p` is bounded by the current builtin table and is exempt.
#
# Usage: pipefail-grep-q-check.sh --all [--repo-root DIR] [--quiet] [--skip-if-no-target]
# Exit: 0 clean, 1 findings, 2 invocation/read error.
set -uo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  printf '%s\n' 'ERROR: python3 is required for pipefail-grep-q-check.sh' >&2
  exit 2
fi

python3 - "$@" <<'PY'
import os, re, shlex, sys

args=sys.argv[1:]; root=""; use_all=False; quiet=False; skip_if_no_target=False
i=0
while i < len(args):
    a=args[i]
    if a == "--all": use_all=True; i+=1
    elif a == "--quiet": quiet=True; i+=1
    elif a == "--skip-if-no-target": skip_if_no_target=True; i+=1
    elif a == "--repo-root" and i+1 < len(args): root=args[i+1]; i+=2
    elif a in ("-h", "--help"):
        print("Usage: pipefail-grep-q-check.sh --all [--repo-root DIR] [--quiet] [--skip-if-no-target]"); sys.exit(0)
    else: print(f"ERROR: unknown or incomplete argument: {a}", file=sys.stderr); sys.exit(2)
if not use_all:
    print("ERROR: --all is required", file=sys.stderr); sys.exit(2)
root=os.path.abspath(root or os.getcwd())
scan_roots=[os.path.join(root, p) for p in ("plugins/rite/hooks", "plugins/rite/scripts")]
if not os.path.isdir(root):
    print(f"ERROR: repository root is not a directory: {root}", file=sys.stderr); sys.exit(2)
if not any(os.path.isdir(p) for p in scan_roots):
    if skip_if_no_target:
        print("Total pipefail-grep-q findings: 0", file=sys.stderr); sys.exit(0)
    print(f"ERROR: no canonical scan roots under: {root}", file=sys.stderr); sys.exit(2)
missing=[os.path.relpath(p,root) for p in scan_roots if not os.path.isdir(p)]
if missing:
    print(f"ERROR: missing canonical scan root: {', '.join(missing)}", file=sys.stderr); sys.exit(2)

def stages(line):
    out=[]; buf=[]; quote=None; esc=False; i=0
    while i < len(line):
        c=line[i]
        if esc: buf.append(c); esc=False; i+=1; continue
        if c == "\\" and quote != "'": buf.append(c); esc=True; i+=1; continue
        if quote:
            buf.append(c)
            if c == quote: quote=None
            i+=1; continue
        if c in "'\"": quote=c; buf.append(c); i+=1; continue
        if c == "#" and (not buf or str(buf[-1]).isspace()): break
        if c == "|" and not (i+1 < len(line) and line[i+1] == "|"):
            out.append("".join(buf).strip()); buf=[]; i+=1; continue
        if c == "|" and i+1 < len(line) and line[i+1] == "|":
            buf.extend(["|","|"]); i+=2; continue
        buf.append(c); i+=1
    out.append("".join(buf).strip())
    return out

def words(stage):
    try: return shlex.split(stage, comments=True, posix=True)
    except ValueError: return []

def grep_q(stage):
    ws=words(stage)
    while ws and (re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', ws[0]) or ws[0] in ("command","env")):
        ws=ws[1:]
    if not ws or os.path.basename(ws[0]) != "grep": return False
    return any(re.match(r'^-[^-]*q', w) for w in ws[1:])

def pipefail_change(line):
    """Return True/False for a standalone set activation, else None."""
    ws=words(line.rstrip(";"))
    if not ws or ws[0] != "set": return None
    for pos, token in enumerate(ws[1:], 1):
        if token in ("-o", "+o") and ws[pos+1:pos+2] == ["pipefail"]:
            return token == "-o"
        if token.startswith(("-", "+")) and not token.startswith("--") and "o" in token[1:]:
            if ws[pos+1:pos+2] == ["pipefail"]:
                return token[0] == "-"
    return None

def syntax_only(line):
    """Preserve unquoted shell syntax while blanking quoted/comment data."""
    out=[]; quote=None; esc=False
    for c in line:
        if esc:
            out.append(" "); esc=False; continue
        if c == "\\" and quote != "'":
            out.append(" "); esc=True; continue
        if quote:
            out.append(" ")
            if c == quote: quote=None
            continue
        if c in "'\"": quote=c; out.append(" "); continue
        if c == "#" and (not out or out[-1].isspace()): break
        out.append(c)
    return "".join(out)

def line_pipefail_state(line, inherited):
    """Apply the last pipefail toggle in this command list for this line."""
    state=inherited
    pattern=r'(?<![A-Za-z0-9_])set\s+([+-][A-Za-z]*o[A-Za-z]*|[+-]o)\s+pipefail(?=\s|;|\)|$)'
    syntax=syntax_only(line)
    # A toggle after the pipeline cannot affect the pipeline retroactively.
    raw_pipes=[m.start() for m in re.finditer(r'(?<!\|)\|(?!\|)', syntax)]
    before_pipeline=syntax[:raw_pipes[0]] if raw_pipes else syntax
    for match in re.finditer(pattern, before_pipeline):
        state=match.group(1).startswith("-")
    return state

def exempt(prod, pipeline_len):
    p=prod.strip()
    if p.startswith("{") and p.endswith("}"): return True
    ws=words(p)
    if "enable" in ws and "-p" in ws: return True
    if "docker" in ws and ws[ws.index("docker")+1:ws.index("docker")+2] == ["ps"]: return True
    # Static format containing a literal pipe is the quoted-pipe false-positive
    # fixture, not an unbounded repository-derived payload.
    if "printf" in ws and any("|" in w for w in ws[ws.index("printf")+1:ws.index("printf")+2]): return True
    while ws and re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', ws[0]): ws=ws[1:]
    while ws and ws[0] in ("if","then","command","env"): ws=ws[1:]
    if not ws: return True
    cmd=os.path.basename(ws[0])
    if cmd == "echo": return True
    # `%s` (without newline/repetition) is retained as a bounded-output proxy
    # for small status probes. `%s\n` repository lists are deliberately not.
    if "printf" in ws:
        pi=ws.index("printf")
        if ws[pi+1:pi+2] == ["%s"]: return True
    return False

findings=[]; errors=0
def walk_error(err):
    global errors
    print(f"WARNING: cannot traverse {err.filename}: {err}", file=sys.stderr)
    errors += 1

for base in ("plugins/rite/hooks", "plugins/rite/scripts"):
    start=os.path.join(root,base)
    for dp, dns, fns in os.walk(start, onerror=walk_error):
        dns[:] = [d for d in dns if d != "tests"]
        for fn in fns:
            if not fn.endswith(".sh") or fn == "pipefail-grep-q-check.sh": continue
            path=os.path.join(dp,fn); rel=os.path.relpath(path,root)
            try:
                lines=open(path,encoding="utf-8",errors="replace").read().splitlines()
            except OSError as e:
                print(f"WARNING: cannot read {rel}: {e}",file=sys.stderr); errors+=1; continue
            logical=[]; acc=""; start_n=1
            for n,physical in enumerate(lines,1):
                if not acc: start_n=n
                part=physical.strip()
                continued=part.endswith("\\")
                if continued: part=part[:-1].rstrip()
                acc += (" " if acc else "") + part
                if continued or physical.rstrip().endswith("|"):
                    continue
                logical.append((start_n,acc)); acc=""
            if acc: logical.append((start_n,acc))
            prev=""; pipefail=False
            for n,line in logical:
                changed=pipefail_change(line)
                if changed is not None:
                    pipefail=changed
                effective_pipefail=line_pipefail_state(line, pipefail)
                ignored="drift-check-ignore" in line or "drift-check-ignore" in prev
                ss=stages(line)
                if effective_pipefail and not ignored and len(ss)>1:
                    for j in range(1,len(ss)):
                        if grep_q(ss[j]) and not exempt(ss[j-1],len(ss)):
                            findings.append(f"[pipefail-grep-q] {rel}:{n}: immediate producer before grep -q: {ss[j-1]}")
                prev=line
for f in findings: print(f)
print(f"Total pipefail-grep-q findings: {len(findings)}", file=sys.stderr)
if errors: sys.exit(2)
sys.exit(1 if findings else 0)
PY
