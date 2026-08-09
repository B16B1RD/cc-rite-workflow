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
# Usage: pipefail-grep-q-check.sh --all [--repo-root DIR] [--quiet]
# Exit: 0 clean, 1 findings, 2 invocation/read error.
set -uo pipefail

python3 - "$@" <<'PY'
import os, re, shlex, sys

args=sys.argv[1:]; root=""; use_all=False; quiet=False
i=0
while i < len(args):
    a=args[i]
    if a == "--all": use_all=True; i+=1
    elif a == "--quiet": quiet=True; i+=1
    elif a == "--repo-root" and i+1 < len(args): root=args[i+1]; i+=2
    elif a in ("-h", "--help"):
        print("Usage: pipefail-grep-q-check.sh --all [--repo-root DIR] [--quiet]"); sys.exit(0)
    else: print(f"ERROR: unknown or incomplete argument: {a}", file=sys.stderr); sys.exit(2)
if not use_all:
    print("ERROR: --all is required", file=sys.stderr); sys.exit(2)
root=os.path.abspath(root or os.getcwd())

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
for base in ("plugins/rite/hooks", "plugins/rite/scripts"):
    start=os.path.join(root,base)
    if not os.path.isdir(start): continue
    for dp, dns, fns in os.walk(start):
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
            prev=""
            for n,line in logical:
                ignored="drift-check-ignore" in line or "drift-check-ignore" in prev
                ss=stages(line)
                if not ignored and len(ss)>1:
                    for j in range(1,len(ss)):
                        if grep_q(ss[j]) and not exempt(ss[j-1],len(ss)):
                            findings.append(f"[pipefail-grep-q] {rel}:{n}: immediate producer before grep -q: {ss[j-1]}")
                prev=line
for f in findings: print(f)
print(f"Total pipefail-grep-q findings: {len(findings)}", file=sys.stderr)
if errors: sys.exit(2)
sys.exit(1 if findings else 0)
PY
