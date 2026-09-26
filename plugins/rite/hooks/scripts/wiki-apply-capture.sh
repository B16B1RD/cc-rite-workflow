#!/bin/bash
# Run one wiki query for the current work and write the search half of the
# apply record into the local work memory. Body checks and decisions are
# filled in by the caller. See references/wiki-apply-contract.md.
#
# Disabled and explicit auto_query off are recorded without a search.
# A missing auto_query key is off for this automatic capture. A direct
# wiki-query-inject.sh call still searches when the key is absent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYWORDS=""
PATHS=""
CWD=""
KEEP_RECORD=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keywords) KEYWORDS="${2:-}"; shift 2 ;;
    --paths) PATHS="${2:-}"; shift 2 ;;
    --cwd) CWD="${2:-}"; shift 2 ;;
    --flow-state) WIKI_APPLY_FLOW_STATE="${2:-}"; shift 2 ;;
    --memory) WIKI_APPLY_MEMORY="${2:-}"; shift 2 ;;
    --keep-record) KEEP_RECORD=1; shift ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
  esac
done
[ -n "$KEYWORDS" ] || { echo "ERROR: --keywords is required" >&2; exit 1; }

if [ -n "$CWD" ]; then
  cd "$CWD"
fi

FLOW="${WIKI_APPLY_FLOW_STATE:-}"
if [ -z "$FLOW" ]; then
  FLOW=$(bash "$SCRIPT_DIR/../flow-state.sh" path 2>/dev/null) || FLOW=""
fi
[ -n "$FLOW" ] && [ -f "$FLOW" ] || { echo "ERROR: flow-state を読めません" >&2; exit 1; }

ISSUE=$(jq -r '.issue_number // ""' "$FLOW")
WT=$(jq -r '.worktree // ""' "$FLOW")
SESSION=$(basename "$FLOW" .flow-state)
if [ -z "$WT" ]; then
  WT=$(git rev-parse --show-toplevel)
fi
if [ -d "$WT" ]; then
  WT=$(CDPATH= cd -- "$WT" && pwd -P)
fi

MEM="${WIKI_APPLY_MEMORY:-}"
if [ -z "$MEM" ]; then
  ROOT=$(bash "$SCRIPT_DIR/../state-path-resolve.sh") || { echo "ERROR: state root を解決できません" >&2; exit 1; }
  MEM="$ROOT/.rite/work-memory/issue-${ISSUE}.md"
fi

_yaml() {
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
# cwd にファイルが無いことを設定オフと扱わない。gate と同じ worktree 根から、
# worktree 自身の config、無ければ main checkout の config を読む。
if [ -n "$WT" ]; then
  cfg=$(bash "$SCRIPT_DIR/lib/rite-config-path.sh" --or-devnull "$WT") || exit 1
  enabled=$(_yaml "$cfg" enabled)
  auto_query=$(_yaml "$cfg" auto_query)
fi
case "$enabled" in
  false|no|0) enabled="false" ;;
  *) enabled="true" ;;
esac

STATUS=""
ATTEMPTS="0"
DIAG="-"
STDOUT=""
if [ "$enabled" = "false" ]; then
  STATUS="disabled"
elif [ "$auto_query" != "true" ]; then
  STATUS="auto_query_off"
else
  err=$(mktemp)
  set +e
  STDOUT=$(bash "$SCRIPT_DIR/../wiki-query-inject.sh" --keywords "$KEYWORDS" --format compact 2>"$err")
  rc=$?
  set -e
  STATUS=$(sed -n 's/^WIKI_QUERY_STATUS=//p' "$err" | tail -1)
  ATTEMPTS=$(sed -n 's/^WIKI_QUERY_ATTEMPTS=//p' "$err" | tail -1)
  DIAG=$( { grep -E '^WARNING:' "$err" || true; } | head -3 | tr '\n' ' ' | sed 's/[[:space:]]*$//')
  rm -f "$err"
  [ -n "$STATUS" ] || STATUS="error"
  [ -n "$ATTEMPTS" ] || ATTEMPTS="1"
  [ -n "$DIAG" ] || DIAG="-"
  if [ "$rc" -ne 0 ] && [ "$STATUS" != "uninitialized" ] && [ "$STATUS" != "error" ]; then
    STATUS="error"
  fi
fi

if [ -z "$PATHS" ]; then
  PATHS=$(git -C "$WT" status --porcelain | awk '{print $NF}' | paste -sd, -)
fi

EXECUTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
HEAD_SHA=$(git -C "$WT" rev-parse HEAD) || { echo "ERROR: HEAD を読めません" >&2; exit 1; }
BLOB_BLOCK=""
if [ -n "$PATHS" ]; then
  IFS=',' read -r -a _wiki_paths <<<"$PATHS"
  for _wiki_path in "${_wiki_paths[@]}"; do
    [ -n "$_wiki_path" ] || continue
    _wiki_oid=$(git -C "$WT" hash-object -- "$_wiki_path") || {
      echo "ERROR: blob を計算できません: $_wiki_path" >&2
      exit 1
    }
    BLOB_BLOCK="${BLOB_BLOCK}blob: ${_wiki_path}=${_wiki_oid}"$'\n'
  done
fi

PAGE_BLOCK=""
if [ "$STATUS" = "ok" ]; then
  PAGE_BLOCK=$(printf '%s\n' "$STDOUT" | awk '
    /^#### / { title=$0; sub(/^#### /, "", title); next }
    /^- \*\*パス\*\*: / { path=$0; sub(/^- \*\*パス\*\*: /, "", path); next }
    /^- \*\*版\*\*: / {
      rev=$0; sub(/^- \*\*版\*\*: /, "", rev)
      printf "page: %s\nrev: %s\nexcerpt: -\nbody: -\ndecision: -\nreason: -\nevidence: -\nresult: -\n", path, rev
    }
  ')
fi

BLOCK=$(cat <<EOF
### Wiki 適用証跡
issue: $ISSUE
session: $SESSION
worktree: $WT
query: $KEYWORDS
executed_at: $EXECUTED_AT
status: $STATUS
attempts: $ATTEMPTS
diagnostic: $DIAG
head: $HEAD_SHA
paths: $PATHS
${BLOB_BLOCK}${PAGE_BLOCK}
EOF
)

if [ "$KEEP_RECORD" -eq 1 ] && [ -f "$MEM" ] && grep -q '^### Wiki 適用証跡$' "$MEM"; then
  echo "WIKI_APPLY_CAPTURE=$STATUS"
  if [ "$STATUS" = "error" ] || [ "$STATUS" = "uninitialized" ]; then
    printf '%s\n' "$STDOUT"
    exit 2
  fi
  printf '%s\n' "$STDOUT"
  exit 0
fi

mkdir -p "$(dirname "$MEM")"
export WIKI_APPLY_MEM="$MEM"
export WIKI_APPLY_BLOCK="$BLOCK"
python3 - <<'PY'
import os, re
path = os.environ["WIKI_APPLY_MEM"]
block = os.environ["WIKI_APPLY_BLOCK"].rstrip() + "\n"
if os.path.exists(path):
    text = open(path, encoding="utf-8").read()
else:
    text = "# 📜 rite 作業メモリ\n\n## Detail\n"
pat = re.compile(r"### Wiki 適用証跡\n.*?(?=^### |^## |\Z)", re.S | re.M)
if pat.search(text):
    text = pat.sub(lambda _m: block, text, count=1)
else:
    if text and not text.endswith("\n"):
        text += "\n"
    text += "\n" + block
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    fh.write(text)
os.replace(tmp, path)
PY

echo "WIKI_APPLY_CAPTURE=$STATUS"
if [ "$STATUS" = "error" ] || [ "$STATUS" = "uninitialized" ]; then
  printf '%s\n' "$STDOUT"
  exit 2
fi
printf '%s\n' "$STDOUT"
exit 0
