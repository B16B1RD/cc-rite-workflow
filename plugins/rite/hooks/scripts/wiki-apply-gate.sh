#!/bin/bash
# Commit and review gate for one work's wiki apply record.
#
# Commit mode skips unless flow-state phase is implement or fix and this
# worktree is that session's worktree. Review mode checks the record.
# WIKI_APPLY_FLOW_STATE and WIKI_APPLY_MEMORY select files for tests.
#
# Exit 0: WIKI_APPLY_GATE=allow or =skip, plus reason=
# Exit 1: WIKI_APPLY_GATE=deny plus reason=<name>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="commit"
WORKTREE=""
BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --worktree) WORKTREE="${2:-}"; shift 2 ;;
    --base) BASE="${2:-}"; shift 2 ;;
    --flow-state) WIKI_APPLY_FLOW_STATE="${2:-}"; shift 2 ;;
    --memory) WIKI_APPLY_MEMORY="${2:-}"; shift 2 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
  esac
done

_skip() { echo "WIKI_APPLY_GATE=skip"; echo "reason=$1"; exit 0; }
_deny() { echo "WIKI_APPLY_GATE=deny"; echo "reason=$1"; exit 1; }
_allow() { echo "WIKI_APPLY_GATE=allow"; echo "reason=ok"; exit 0; }

FLOW="${WIKI_APPLY_FLOW_STATE:-}"
if [ -z "$FLOW" ]; then
  FLOW=$(bash "$SCRIPT_DIR/../flow-state.sh" path 2>/dev/null) || FLOW=""
fi
if [ -z "$FLOW" ] || [ ! -f "$FLOW" ]; then
  if [ "$MODE" = "review" ]; then
    _deny "state_unreadable"
  fi
  _skip "no_session"
fi

PHASE=$(jq -r '.phase // ""' "$FLOW" 2>/dev/null) || PHASE=""
FS_WT=$(jq -r '.worktree // ""' "$FLOW" 2>/dev/null) || FS_WT=""
if [ -z "$WORKTREE" ]; then
  WORKTREE=$(git rev-parse --show-toplevel 2>/dev/null) || WORKTREE=""
fi
_canon() {
  if [ -n "${1:-}" ] && [ -d "$1" ]; then
    (CDPATH= cd -- "$1" && pwd -P)
  else
    printf '%s' "${1:-}"
  fi
}
WORKTREE=$(_canon "$WORKTREE")
FS_WT_C=$(_canon "$FS_WT")

if [ "$MODE" = "commit" ]; then
  case "$PHASE" in
    implement|fix) ;;
    *) _skip "phase" ;;
  esac
  if [ -z "$FS_WT_C" ] || [ "$FS_WT_C" != "$WORKTREE" ]; then
    _skip "worktree"
  fi
fi

MEM="${WIKI_APPLY_MEMORY:-}"
if [ -z "$MEM" ]; then
  ISSUE=$(jq -r '.issue_number // ""' "$FLOW" 2>/dev/null) || ISSUE=""
  ROOT=$(bash "$SCRIPT_DIR/../state-path-resolve.sh" 2>/dev/null) || ROOT=""
  if [ -n "$ROOT" ] && [ -n "$ISSUE" ]; then
    MEM="$ROOT/.rite/work-memory/issue-${ISSUE}.md"
  fi
fi
if [ -z "$MEM" ] || [ ! -f "$MEM" ]; then
  _deny "record_missing"
fi

if [ -z "$BASE" ] && [ -n "$WORKTREE" ] && [ -f "$WORKTREE/rite-config.yml" ]; then
  BASE=$(awk '/^branch:/{f=1;next} f&&/^[^ ]/{exit} f&&/base:/{print;exit}' "$WORKTREE/rite-config.yml" \
    | sed 's/.*base:[[:space:]]*//' | tr -d '[:space:]"'"'"'') || BASE=""
fi
[ -n "$BASE" ] || BASE="develop"

STAGED=$(git -C "$WORKTREE" diff --cached --name-only 2>/dev/null || true)
DIFF_NAMES=$(git -C "$WORKTREE" diff --name-only "${BASE}...HEAD" 2>/dev/null || true)
DIFF_TEXT=$(git -C "$WORKTREE" diff "${BASE}...HEAD" 2>/dev/null || true)

reason=$(
  WIKI_APPLY_FLOW="$FLOW" \
  WIKI_APPLY_MEM="$MEM" \
  WIKI_APPLY_MODE="$MODE" \
  WIKI_APPLY_WT="$WORKTREE" \
  WIKI_APPLY_STAGED="$STAGED" \
  WIKI_APPLY_DIFF_NAMES="$DIFF_NAMES" \
  WIKI_APPLY_DIFF_TEXT="$DIFF_TEXT" \
  python3 - <<'PY'
import json, os, sys
flow_path = os.environ["WIKI_APPLY_FLOW"]
mem_path = os.environ["WIKI_APPLY_MEM"]
mode = os.environ["WIKI_APPLY_MODE"]
worktree = os.environ["WIKI_APPLY_WT"]
flow = json.load(open(flow_path, encoding="utf-8"))
session = os.path.basename(flow_path)
if session.endswith(".flow-state"):
    session = session[: -len(".flow-state")]
issue = str(flow.get("issue_number") or "")
text = open(mem_path, encoding="utf-8").read()
marker = "### Wiki 適用証跡"
start = text.find(marker)
if start < 0:
    print("record_missing")
    sys.exit(0)
rest = text[start + len(marker):]
lines = []
for line in rest.splitlines():
    if line.startswith("### ") or line.startswith("## "):
        break
    lines.append(line)
fields = {}
pages = []
cur = None
for line in lines:
    if ":" not in line:
        continue
    key, val = line.split(":", 1)
    key = key.strip()
    val = val.strip()
    if key == "page":
        cur = {"page": val}
        pages.append(cur)
        continue
    if cur is not None and key in ("rev", "body", "decision", "reason", "evidence"):
        cur[key] = val
    else:
        fields[key] = val

def fail(name):
    print(name)
    sys.exit(0)

if fields.get("issue") != issue:
    fail("issue_mismatch")
if fields.get("session") != session:
    fail("session_mismatch")
if fields.get("worktree") != worktree:
    fail("worktree_mismatch")
status = fields.get("status") or ""
known = ("ok", "none", "disabled", "auto_query_off", "uninitialized", "error")
if status not in known:
    fail("record_corrupt")
if status in ("error", "uninitialized"):
    fail("status_" + status)
recorded = [p for p in (fields.get("paths") or "").split(",") if p]
staged = [p for p in os.environ.get("WIKI_APPLY_STAGED", "").splitlines() if p]
for path in staged:
    if path not in recorded:
        fail("paths")
if status == "ok":
    if not pages:
        fail("pages_missing")
    names = set(p for p in os.environ.get("WIKI_APPLY_DIFF_NAMES", "").splitlines() if p)
    blob = os.environ.get("WIKI_APPLY_DIFF_TEXT", "")
    for page in pages:
        if page.get("body") != "read":
            fail("body_missing")
        if page.get("decision") not in ("applied", "out"):
            fail("decision_missing")
        if not page.get("reason"):
            fail("reason_missing")
        if not page.get("rev"):
            fail("rev_missing")
        if page.get("decision") == "applied" and not page.get("evidence"):
            fail("evidence_missing")
        if mode == "review" and page.get("decision") == "applied":
            evidence = page.get("evidence") or ""
            if evidence not in names and evidence not in blob:
                fail("evidence_mismatch")
print("allow")
PY
)
case "$reason" in
  allow) _allow ;;
  "") _deny "record_corrupt" ;;
  *) _deny "$reason" ;;
esac
