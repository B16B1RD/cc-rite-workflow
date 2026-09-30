#!/bin/bash
# Move the wiki apply record's head to HEAD after a commit.
#
# The commit gate allowed the commit against the HEAD it was made on, so the
# record names that commit. Until head moves, the next gate refuses the record
# as stale_head. The head moves only when the record names --from, the commit
# the new one was made on. A record that names anything else was not checked
# for this commit and is left as it is; a record that already names HEAD is
# left as it is too.
#
# Usage:
#   bash wiki-apply-advance-head.sh --from REV [--worktree DIR] [--memory FILE]
#
# Without --memory the record is found as wiki-apply-gate.sh finds it:
# WIKI_APPLY_MEMORY, else <state root>/.rite/work-memory/issue-<N>.md for the
# flow-state issue. WIKI_APPLY_FLOW_STATE selects the flow-state for tests.
#
# stdout: WIKI_APPLY_HEAD=advanced or =current, plus head=<HEAD>
# Exit 0: head moved, or the record already names HEAD
# Exit 1: argument error, or the record cannot be moved (the memory is unchanged)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FROM=""
WORKTREE=""
MEM="${WIKI_APPLY_MEMORY:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --from|--worktree|--memory)
      [ $# -ge 2 ] || { echo "ERROR: $1 requires a value" >&2; exit 1; } ;;
  esac
  case "$1" in
    --from) FROM="$2"; shift 2 ;;
    --worktree) WORKTREE="$2"; shift 2 ;;
    --memory) MEM="$2"; shift 2 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
  esac
done
[ -n "$FROM" ] || { echo "ERROR: --from is required" >&2; exit 1; }

RETRY="Wiki の capture からやり直して証跡を書き直してください"
_fail() { echo "ERROR: Wiki 適用証跡の head を進められません: $1。$RETRY" >&2; exit 1; }

if [ -z "$WORKTREE" ]; then
  WORKTREE=$(git rev-parse --show-toplevel) || _fail "作業ツリーを解決できません"
fi
FROM_SHA=$(git -C "$WORKTREE" rev-parse --verify -q "${FROM}^{commit}") || _fail "--from を commit に解決できません: $FROM"
HEAD_SHA=$(git -C "$WORKTREE" rev-parse --verify -q "HEAD^{commit}") || _fail "HEAD を解決できません"

if [ -z "$MEM" ]; then
  FLOW="${WIKI_APPLY_FLOW_STATE:-}"
  if [ -z "$FLOW" ]; then
    FLOW=$(bash "$SCRIPT_DIR/../flow-state.sh" path 2>/dev/null) || FLOW=""
  fi
  [ -n "$FLOW" ] && [ -f "$FLOW" ] || _fail "flow-state を読めません"
  ISSUE=$(jq -r '.issue_number // "" | tostring' "$FLOW") || _fail "flow-state を読めません"
  [ -n "$ISSUE" ] || _fail "flow-state に issue_number がありません"
  ROOT=$(bash "$SCRIPT_DIR/../state-path-resolve.sh") || _fail "state root を解決できません"
  MEM="$ROOT/.rite/work-memory/issue-${ISSUE}.md"
fi
[ -f "$MEM" ] || _fail "作業メモリがありません: $MEM"

rc=0
WIKI_APPLY_MEM="$MEM" WIKI_APPLY_FROM="$FROM_SHA" WIKI_APPLY_HEAD="$HEAD_SHA" python3 - <<'PY' || rc=$?
import os, re, sys
path = os.environ["WIKI_APPLY_MEM"]
text = open(path, encoding="utf-8").read()
marker = "### Wiki 適用証跡"
start = text.find(marker)
if start < 0:
    sys.exit(4)
rest_start = start + len(marker)
next_h = len(text)
for match in re.finditer(r"^#{2,3} ", text[rest_start:], re.M):
    next_h = rest_start + match.start()
    break
section = text[start:next_h]
found = re.search(r"^head: ([0-9a-f]{40})$", section, re.M)
if not found:
    sys.exit(5)
recorded = found.group(1)
if recorded == os.environ["WIKI_APPLY_HEAD"]:
    sys.exit(3)
if recorded != os.environ["WIKI_APPLY_FROM"]:
    sys.exit(6)
new_section = section[:found.start(1)] + os.environ["WIKI_APPLY_HEAD"] + section[found.end(1):]
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    fh.write(text[:start] + new_section + text[next_h:])
os.replace(tmp, path)
PY
case "$rc" in
  0) echo "WIKI_APPLY_HEAD=advanced" ;;
  3) echo "WIKI_APPLY_HEAD=current" ;;
  4) _fail "作業メモリに ### Wiki 適用証跡 がありません" ;;
  5) _fail "証跡に head: 行がありません" ;;
  6) _fail "証跡の head が $FROM_SHA ではありません" ;;
  *) _fail "作業メモリを更新できません (rc=$rc)" ;;
esac
echo "head=$HEAD_SHA"
