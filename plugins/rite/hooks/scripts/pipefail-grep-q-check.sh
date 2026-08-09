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

def pipeline_edges(line):
    """Return immediate producer/consumer pairs at matching shell depth."""
    syntax=syntax_only(line); events=[]; paren=0; brace=0; i=0
    while i < len(syntax):
        c=syntax[i]; depth=(paren,brace)
        if c == "(": paren+=1; i+=1; continue
        if c == ")": paren=max(0,paren-1); i+=1; continue
        if c == "{": brace+=1; i+=1; continue
        if c == "}": brace=max(0,brace-1); i+=1; continue
        if c == "|" and not (i+1 < len(syntax) and syntax[i+1] == "|"):
            events.append(("pipe",i,i+1,depth)); i+=1; continue
        if c == ";": events.append(("sep",i,i+1,depth)); i+=1; continue
        if c in "&|" and i+1 < len(syntax) and syntax[i+1] == c:
            events.append(("sep",i,i+2,depth)); i+=2; continue
        if c == "&" and not (i and syntax[i-1] in "<>") and not (i+1 < len(syntax) and syntax[i+1] == ">"):
            events.append(("sep",i,i+1,depth)); i+=1; continue
        i+=1
    pairs=[]
    for idx,event in enumerate(events):
        if event[0] != "pipe": continue
        _,pos,end,depth=event; left=0; right=len(line)
        for prior in reversed(events[:idx]):
            if prior[3] == depth:
                left=prior[2]; break
        for later in events[idx+1:]:
            if later[3] == depth:
                right=later[1]; break
        pairs.append((line[left:pos].strip(),line[end:right].strip()))
    return pairs

def words(stage):
    try: return shlex.split(stage, comments=True, posix=True)
    except ValueError: return []

def grep_q(stage):
    ws=words(stage)
    while ws and (re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', ws[0]) or ws[0] in ("command","env")):
        ws=ws[1:]
    if not ws or os.path.basename(ws[0]) != "grep": return False
    return any(re.match(r'^-[^-]*q', w) for w in ws[1:])

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

toggle_re=re.compile(r'(?<![A-Za-z0-9_])set\s+([+-][A-Za-z]*o[A-Za-z]*|[+-]o)\s+pipefail(?=\s|;|\)|$)')

def scan_line_state(syntax, state, stack, function_activity=None, pending_function=None, function_effects=None, condition_stack=None):
    """Evaluate one line while retaining parenthesized scopes across lines."""
    function_activity=function_activity or {}
    function_effects=function_effects or {}
    condition_stack=condition_stack if condition_stack is not None else []
    declared=re.match(r'^\s*(?:function\s+([A-Za-z_][A-Za-z0-9_]*)|([A-Za-z_][A-Za-z0-9_]*)\s*\(\s*\))',syntax)
    declared_name=(declared.group(1) or declared.group(2)) if declared else None
    call_effects={}
    for name,effect in function_effects.items():
        if effect is None or name == declared_name: continue
        # Only a plainly standalone current-shell call can propagate `set`.
        # Conditional, pipeline, async and subshell calls are not definite
        # parent-shell effects and are intentionally excluded here.
        pattern=r'(?:^|;)\s*('+re.escape(name)+r')(?:\s+[^;|&]+)?\s*(?=;|$)'
        for m in re.finditer(pattern,syntax): call_effects[m.start(1)]=effect
    open_names={}
    for m in re.finditer(r'(?:^|[;&])\s*(?:function\s+([A-Za-z_][A-Za-z0-9_]*)(?:\s*\(\s*\))?|([A-Za-z_][A-Za-z0-9_]*)\s*\(\s*\))\s*\{', syntax):
        open_names[m.end()-1]=m.group(1) or m.group(2)
    if pending_function:
        m=re.match(r'^\s*\{',syntax)
        if m: open_names[m.end()-1]=pending_function; pending_function=None
    header=re.match(r'^\s*(?:function\s+([A-Za-z_][A-Za-z0-9_]*)(?:\s*\(\s*\))?|([A-Za-z_][A-Za-z0-9_]*)\s*\(\s*\))\s*$',syntax)
    if header: pending_function=header.group(1) or header.group(2)
    pipe_states=[]; segment_start_state=state; i=0
    while i < len(syntax):
        if i in call_effects: state=call_effects[i]
        cm=re.match(r'if\s+(true|false)\s*;?\s*then\b',syntax[i:])
        if cm: condition_stack.append(cm.group(1)=="true"); i+=cm.end(); continue
        cm=re.match(r'if\s+[^;|]+;\s*then\b',syntax[i:])
        if cm: condition_stack.append(None); i+=cm.end(); continue
        cm=re.match(r'else\b',syntax[i:])
        if cm:
            if condition_stack and condition_stack[-1] is not None: condition_stack[-1]=not condition_stack[-1]
            i+=cm.end(); continue
        cm=re.match(r'fi\b',syntax[i:])
        if cm:
            if condition_stack: condition_stack.pop()
            i+=cm.end(); continue
        if syntax[i] == "(": stack.append(("paren",state)); i+=1; continue
        if syntax[i] == ")":
            if stack and stack[-1][0] == "paren": state=stack.pop()[1]
            i+=1; continue
        if syntax[i] == "{" and i in open_names:
            stack.append(("function",state)); state=function_activity.get(open_names[i],False); condition_stack.clear(); i+=1; continue
        if syntax[i] == "{":
            stack.append(("brace",state)); i+=1; continue
        if syntax[i] == "}":
            if stack:
                kind,saved=stack.pop()
                if kind == "function": state=saved
            i+=1; continue
        if syntax[i] == "|" and not (i and syntax[i-1] == "|") and not (i+1 < len(syntax) and syntax[i+1] == "|"):
            pipe_states.append(state)
            i+=1; continue
        if syntax[i] == ";":
            segment_start_state=state; i+=1; continue
        if syntax[i] in "&|" and i+1 < len(syntax) and syntax[i+1] == syntax[i]:
            segment_start_state=state; i+=2; continue
        if syntax[i] == "&" and not (i and syntax[i-1] in "<>") and not (i+1 < len(syntax) and syntax[i+1] == ">"):
            state=segment_start_state; segment_start_state=state; i+=1; continue
        match=toggle_re.match(syntax, i)
        if match:
            enabled=match.group(1).startswith("-")
            if not any(value is False for value in condition_stack):
                if not any(value is None for value in condition_stack) or enabled:
                    state=enabled
            i=match.end(); continue
        i+=1
    return pipe_states,state,stack,pending_function,condition_stack

def infer_function_activity(logical):
    """Collect whether each statically named function is called under pipefail."""
    names=set()
    for _,line in logical:
        m=re.match(r'^\s*(?:function\s+([A-Za-z_][A-Za-z0-9_]*)|([A-Za-z_][A-Za-z0-9_]*)\s*\(\s*\))',syntax_only(line))
        if m: names.add(m.group(1) or m.group(2))
    activity={name:False for name in names}; edges={name:[] for name in names}
    effects={name:None for name in names}; local_state={name:None for name in names}
    effect_events={name:[] for name in names}
    state=False; in_function=None; pending=None; depth=0
    for _,line in logical:
        syntax=syntax_only(line)
        header=re.match(r'^\s*(?:function\s+[A-Za-z_][A-Za-z0-9_]*(?:\s*\(\s*\))?|[A-Za-z_][A-Za-z0-9_]*\s*\(\s*\))\s*(\{)?',syntax)
        if not in_function and header:
            declared=re.match(r'^\s*(?:function\s+([A-Za-z_][A-Za-z0-9_]*)|([A-Za-z_][A-Za-z0-9_]*)\s*\()',syntax)
            declared_name=(declared.group(1) or declared.group(2)) if declared else None
            if header.group(1):
                depth=syntax.count("{")-syntax.count("}"); in_function=declared_name if depth>0 else None
                if depth<=0 and declared_name:
                    events=[(m.start(),"toggle",m.group(1).startswith("-")) for m in toggle_re.finditer(syntax)]
                    for name in names:
                        if name != declared_name:
                            for cm in re.finditer(r'[;{]\s*'+re.escape(name)+r'(?=\s|[;|&()]|$)',syntax):
                                events.append((cm.start(),"call",name))
                    local=None
                    for _,kind,value in sorted(events):
                        effect_events[declared_name].append((kind,value))
                        if kind == "toggle": local=value
                        else: edges[declared_name].append((value,local))
            else: pending=declared_name
            continue
        if pending:
            if re.match(r'^\s*\{',syntax): in_function=pending; pending=None; depth=syntax.count("{")-syntax.count("}")
            continue
        if in_function:
            line_events=[(m.start(),"toggle",m.group(1).startswith("-")) for m in toggle_re.finditer(syntax)]
            for name in names:
                for cm in re.finditer(r'(?:^|[;|&]\s*|\b(?:if|then|command)\s+|!\s*|\$\(\s*)'+re.escape(name)+r'(?=\s|[;|&()]|$)',syntax):
                    line_events.append((cm.start(),"call",name))
            for _,kind,value in sorted(line_events):
                if kind == "toggle": local_state[in_function]=value
                else: edges[in_function].append((value,local_state[in_function]))
                effect_events[in_function].append((kind,value))
            depth+=syntax.count("{")-syntax.count("}")
            if depth<=0: in_function=None
            continue
        for name in names:
            if re.search(r'(?:^|[;|&]\s*|\b(?:if|then|command)\s+|!\s*|\$\(\s*)'+re.escape(name)+r'(?=\s|[;|&()]|$)',syntax):
                activity[name]=activity[name] or state
        _,state,_,_,_=scan_line_state(syntax,state,[],{},None,{},[])
    changed=True
    while changed:
        changed=False
        for caller,events in effect_events.items():
            summary=None
            for kind,value in events:
                if kind == "toggle": summary=value
                elif effects[value] is not None: summary=effects[value]
            if effects[caller] != summary: effects[caller]=summary; changed=True
        for caller,callees in edges.items():
            for callee,override in callees:
                active=activity[caller] if override is None else override
                if active and not activity[callee]: activity[callee]=True; changed=True
    return activity,effects

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
            function_activity,function_effects=infer_function_activity(logical)
            prev=""; pipefail=False; scope_stack=[]; pending_function=None; condition_stack=[]
            for n,line in logical:
                pipe_states,pipefail,scope_stack,pending_function,condition_stack=scan_line_state(syntax_only(line),pipefail,scope_stack,function_activity,pending_function,function_effects,condition_stack)
                ignored="drift-check-ignore" in line or "drift-check-ignore" in prev
                edges=pipeline_edges(line)
                if not ignored:
                    for j,(producer,consumer) in enumerate(edges):
                        active=pipe_states[j] if j < len(pipe_states) else False
                        if active and grep_q(consumer) and not exempt(producer,len(edges)+1):
                            findings.append(f"[pipefail-grep-q] {rel}:{n}: immediate producer before grep -q: {producer}")
                prev=line
for f in findings: print(f)
print(f"Total pipefail-grep-q findings: {len(findings)}", file=sys.stderr)
if errors: sys.exit(2)
sys.exit(1 if findings else 0)
PY
