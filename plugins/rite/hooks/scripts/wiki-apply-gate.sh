#!/bin/bash
# Commit and review gate for one work's wiki apply record.
#
# The record's own status is not enough. This gate re-reads rite-config.yml,
# HEAD, and the blob of each recorded path, and refuses a stale or mismatched
# success. Commit mode skips unless flow-state phase is implement or fix and
# this worktree is that session's worktree. Review mode checks the record but
# not its session: review authorizes no commit, and a review resumed from
# another session reads the record the implementing session wrote.
# WIKI_APPLY_FLOW_STATE and WIKI_APPLY_MEMORY select files for tests.
#
# Exit 0: WIKI_APPLY_GATE=allow or =skip, plus reason=
# Exit 1: WIKI_APPLY_GATE=deny plus reason=<name>
# Non-zero without a WIKI_APPLY_GATE= line: argument error (exit 1, reason on
#   stderr) or internal failure, whose exit code and stderr come from the
#   failing command (for example a record that is not valid UTF-8, or python3
#   missing). Callers treat any non-zero exit as a denial.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="commit"
WORKTREE=""
BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mode|--worktree|--base|--flow-state|--memory)
      [ $# -ge 2 ] || { echo "ERROR: $1 requires a value" >&2; exit 1; } ;;
  esac
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --worktree) WORKTREE="${2:-}"; shift 2 ;;
    --base) BASE="${2:-}"; shift 2 ;;
    --flow-state) WIKI_APPLY_FLOW_STATE="${2:-}"; shift 2 ;;
    --memory) WIKI_APPLY_MEMORY="${2:-}"; shift 2 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
  esac
done
case "$MODE" in
  commit|review) ;;
  *) echo "ERROR: --mode must be commit or review (got: '$MODE')" >&2; exit 1 ;;
esac

_skip() { echo "WIKI_APPLY_GATE=skip"; echo "reason=$1"; exit 0; }
_deny() { echo "WIKI_APPLY_GATE=deny"; echo "reason=$1"; exit 1; }
_allow() {
  echo "WIKI_APPLY_GATE=allow"
  echo "reason=ok"
  if [ -n "${MEM:-}" ]; then
    echo "memory=$MEM"
  fi
  exit 0
}

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

# A present file that jq cannot read is not an empty phase. Commit mode must
# not skip that as "some other phase".
# Fields are joined on the unit separator, not a tab: a tab is IFS whitespace,
# so an empty worktree field would collapse and shift the issue number into
# FS_WT. Sessions that never record a worktree leave that field empty.
if ! _flow_row=$(jq -r '[.phase // "", .worktree // "", (.issue_number // "" | tostring)] | join("\u001f")' "$FLOW" 2>/dev/null); then
  _deny "state_unreadable"
fi
IFS=$'\x1f' read -r PHASE FS_WT ISSUE <<<"$_flow_row"
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

# Same wiki-key read as wiki-apply-capture.sh. A missing file is enabled,
# and auto_query is on only when the value is exactly true.
_yaml_at() {
  local file="$1" key="$2"
  awk -v k="$key" '
    /^wiki:/ {s=1; next}
    s && /^[^ ]/ {exit}
    s && $0 ~ "^[[:space:]]+" k ":" {print; exit}
  ' "$file" 2>/dev/null \
    | sed 's/[[:space:]]#.*//' \
    | sed "s/.*${key}:[[:space:]]*//" \
    | tr -d '[:space:]"'"'"'' \
    | tr '[:upper:]' '[:lower:]'
}
enabled="true"
auto_query=""
if [ -n "$WORKTREE" ] && [ -f "$WORKTREE/rite-config.yml" ]; then
  enabled=$(_yaml_at "$WORKTREE/rite-config.yml" enabled)
  auto_query=$(_yaml_at "$WORKTREE/rite-config.yml" auto_query)
fi
case "$enabled" in
  false|no|0) enabled="false" ;;
  *) enabled="true" ;;
esac
case "$auto_query" in
  true) auto_query="true" ;;
  *) auto_query="" ;;
esac

STAGED=$(git -C "$WORKTREE" diff --cached --name-only 2>/dev/null || true)
DIFF_NAMES=$(git -C "$WORKTREE" diff --name-only "${BASE}...HEAD" 2>/dev/null || true)
DIFF_TEXT=$(git -C "$WORKTREE" diff "${BASE}...HEAD" 2>/dev/null || true)

reason=$(
  WIKI_APPLY_FLOW="$FLOW" \
  WIKI_APPLY_MEM="$MEM" \
  WIKI_APPLY_MODE="$MODE" \
  WIKI_APPLY_WT="$WORKTREE" \
  WIKI_APPLY_ENABLED="$enabled" \
  WIKI_APPLY_AUTO="$auto_query" \
  WIKI_APPLY_STAGED="$STAGED" \
  WIKI_APPLY_DIFF_NAMES="$DIFF_NAMES" \
  WIKI_APPLY_DIFF_TEXT="$DIFF_TEXT" \
  python3 - <<'PY'
import json, os, re, subprocess, sys

flow_path = os.environ["WIKI_APPLY_FLOW"]
mem_path = os.environ["WIKI_APPLY_MEM"]
mode = os.environ["WIKI_APPLY_MODE"]
worktree = os.environ["WIKI_APPLY_WT"]
enabled = os.environ.get("WIKI_APPLY_ENABLED", "true")
auto_query = os.environ.get("WIKI_APPLY_AUTO", "")

def fail(name):
    print(name)
    sys.exit(0)

def git(*args):
    proc = subprocess.run(
        ["git", "-C", worktree, *args],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        return ""
    return proc.stdout.strip()

def blank(value):
    return value is None or value == "" or value == "-"

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
blobs = {}
cur = None
page_keys = ("rev", "excerpt", "body", "decision", "reason", "evidence", "result")
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
    if key == "blob":
        if "=" not in val:
            fail("record_corrupt")
        bpath, oid = val.split("=", 1)
        if not bpath or bpath in blobs or not re.fullmatch(r"[0-9a-f]{40}", oid):
            fail("record_corrupt")
        blobs[bpath] = oid
        continue
    if cur is not None and key in page_keys:
        cur[key] = val
    else:
        fields[key] = val

if fields.get("issue") != issue:
    fail("issue_mismatch")
if mode != "review" and fields.get("session") != session:
    fail("session_mismatch")
if fields.get("worktree") != worktree:
    fail("worktree_mismatch")
status = fields.get("status") or ""
known = ("ok", "none", "disabled", "auto_query_off", "uninitialized", "error")
if status not in known:
    fail("record_corrupt")
if status in ("error", "uninitialized"):
    fail("status_" + status)
if not fields.get("query"):
    fail("query_missing")
executed = fields.get("executed_at") or ""
if not executed:
    fail("executed_at_missing")
if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", executed):
    fail("executed_at_invalid")
attempts = fields.get("attempts")
if attempts is None or attempts == "":
    fail("attempts_missing")
if not re.fullmatch(r"[0-9]+", attempts):
    fail("attempts_invalid")
attempt_n = int(attempts)
if status in ("ok", "none") and attempt_n < 1:
    fail("attempts_invalid")
if status in ("disabled", "auto_query_off") and attempt_n != 0:
    fail("attempts_invalid")
if status == "disabled":
    if enabled != "false":
        fail("config_mismatch")
elif status == "auto_query_off":
    if enabled != "true" or auto_query == "true":
        fail("config_mismatch")
elif status in ("ok", "none"):
    if enabled != "true" or auto_query != "true":
        fail("config_mismatch")
current = git("rev-parse", "HEAD")
if not re.fullmatch(r"[0-9a-f]{40}", current):
    fail("head_unreadable")
recorded_head = fields.get("head") or ""
if not re.fullmatch(r"[0-9a-f]{40}", recorded_head):
    fail("head_missing")
if recorded_head != current:
    fail("stale_head")
recorded_paths = [p for p in (fields.get("paths") or "").split(",") if p]
staged = [p for p in os.environ.get("WIKI_APPLY_STAGED", "").splitlines() if p]
staged_set = set(staged)
for path in recorded_paths:
    parts = path.split("/")
    if path.startswith("/") or ".." in parts or path not in blobs:
        if path not in blobs:
            fail("blobs_missing")
        fail("record_corrupt")
    if path in staged_set:
        oid = git("rev-parse", ":" + path)
    else:
        oid = git("hash-object", "--", path)
    if oid != blobs[path]:
        fail("stale_content")
for path in staged:
    if path not in recorded_paths:
        fail("paths")
if status == "ok":
    if not pages:
        fail("pages_missing")
    names = set(p for p in os.environ.get("WIKI_APPLY_DIFF_NAMES", "").splitlines() if p)
    diff_text = os.environ.get("WIKI_APPLY_DIFF_TEXT", "")
    for page in pages:
        if page.get("body") != "read":
            fail("body_missing")
        if page.get("decision") not in ("applied", "out"):
            fail("decision_missing")
        if blank(page.get("reason")):
            fail("reason_missing")
        rev = page.get("rev") or ""
        if not re.fullmatch(r"[0-9a-f]{40}", rev):
            fail("rev_missing")
        excerpt = page.get("excerpt") or ""
        if blank(excerpt):
            fail("excerpt_missing")
        body = git("cat-file", "-p", rev)
        if not body:
            fail("rev_unreadable")
        if excerpt not in body:
            fail("excerpt_mismatch")
        if page.get("decision") == "applied":
            evidence = page.get("evidence") or ""
            if blank(evidence):
                fail("evidence_missing")
            if blank(page.get("result")):
                fail("result_missing")
            if mode == "review" and evidence not in names and evidence not in diff_text:
                fail("evidence_mismatch")
print("allow")
PY
)
case "$reason" in
  allow) _allow ;;
  "") _deny "record_corrupt" ;;
  *) _deny "$reason" ;;
esac
