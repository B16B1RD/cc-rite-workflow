#!/bin/bash
# rite workflow - Projects Items Fetch
# GitHub Projects (V2) の全 item を GraphQL cursor pagination で取得し、
# {items: [{content: {number}, status}]} 形式に正規化した JSON tempfile の path を stdout に出力する。
# 固定 `--limit` による 100/500 件超 Project の silent truncation を防ぐ (旧 inline 実装の動機を継承)。
#
# Called from:
#   - skills/issue-list/SKILL.md Phase 4.2 (Status Map 構築。旧 ~44 行 inline block を委譲)
#
# Usage:
#   bash projects-items-fetch.sh --project-number N --owner OWNER
#
# Output (stdout):
#   成功: 正規化 JSON tempfile の絶対 path 1 行 (caller が Read tool で読む。削除責務は caller)
#   失敗: "[projects:fetch-failed] <reason>" 1 行 (tempfile path は出力しない)
#
# Exit codes:
#   常に 0 (non-blocking 契約 — 旧 issue/list.md Phase 4.2 inline block と同一。
#   caller は stdout が path か `[projects:fetch-failed]` かで成否を判定し、
#   失敗時は Status 列なしの一覧表示に fallback する)
set -u

# --- 失敗 sentinel helper (全失敗経路で共通: stdout 1 行 + exit 0) ---
fetch_failed() {
  echo "[projects:fetch-failed] $1"
  exit 0
}

# --- 引数解析 (shift; shift — 値なしフラグによる無限ループ素因を回避) ---
project_number=""
owner=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project-number) project_number="${2:-}"; shift; shift ;;
    --owner)          owner="${2:-}";          shift; shift ;;
    *) fetch_failed "unknown argument: $1" ;;
  esac
done

# placeholder 残留 ({project_number} 等の substitute 忘れ) も非数値としてここで catch する
case "$project_number" in
  ''|*[!0-9]*) fetch_failed "invalid --project-number: '${project_number:-<empty>}' (must be numeric)" ;;
esac
[ -n "$owner" ] || fetch_failed "missing --owner"

command -v jq >/dev/null 2>&1 || fetch_failed "jq not found"

# --- tempfile 準備 + cleanup trap ---
# tmpfile は成功時に caller へ hand-off するため trap 対象から外す (handed_off で制御)。
# pages / err は中間ファイルのため全経路で削除する。
# 明示的な `${TMPDIR:-/tmp}/rite-…-XXXXXX` テンプレートを使う (リポジトリ共通慣習)。bare `mktemp`
# は BSD/macOS で $TMPDIR を GNU と同じには尊重せず既定 location に着地するため、caller が
# $TMPDIR で隔離を張っても外れる 。
tmpfile=$(mktemp "${TMPDIR:-/tmp}/rite-projects-items-result-XXXXXX") || fetch_failed "mktemp failed for result tempfile"
pages=$(mktemp "${TMPDIR:-/tmp}/rite-projects-items-pages-XXXXXX") || { rm -f "$tmpfile"; fetch_failed "mktemp failed for pages tempfile"; }
err=$(mktemp "${TMPDIR:-/tmp}/rite-projects-items-err-XXXXXX") || { rm -f "$tmpfile" "$pages"; fetch_failed "mktemp failed for stderr tempfile"; }
handed_off=0
_cleanup() {
  rm -f "$pages" "$err"
  [ "$handed_off" = "1" ] || rm -f "$tmpfile"
  return 0
}
trap 'rc=$?; _cleanup; exit $rc' EXIT
trap '_cleanup; exit 130' INT
trap '_cleanup; exit 143' TERM
trap '_cleanup; exit 129' HUP

# --- Project node ID 解決 (owner-type agnostic: user / organization 両対応) ---
# 旧 inline 実装と同じく pipeline の exit code は jq 側を採用し、
# gh 失敗は pid 空 → fetch-failed 経路に合流する。
pid=$(gh project view "$project_number" --owner "$owner" --format json 2>"$err" | jq -r '.id')
if [ -z "$pid" ] || [ "$pid" = "null" ]; then
  fetch_failed "could not resolve project id: $(tr '\n' ' ' < "$err")"
fi

# --- 全 item を cursor pagination で収集 ---
cursor=""; : > "$pages"; ok=1; fail_reason=""
QUERY='
query($pid: ID!, $cursor: String) {
  node(id: $pid) {
    ... on ProjectV2 {
      items(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          content { ... on Issue { number } ... on PullRequest { number } }
          fieldValues(first: 20) {
            nodes {
              ... on ProjectV2ItemFieldSingleSelectValue {
                name
                field { ... on ProjectV2SingleSelectField { name } }
              }
            }
          }
        }
      }
    }
  }
}'
while : ; do
  if [ -n "$cursor" ]; then
    page=$(gh api graphql -f query="$QUERY" -f pid="$pid" -f cursor="$cursor" 2>"$err") || { ok=0; fail_reason="gh api graphql failed: $(tr '\n' ' ' < "$err")"; break; }
  else
    page=$(gh api graphql -f query="$QUERY" -f pid="$pid" 2>"$err") || { ok=0; fail_reason="gh api graphql failed: $(tr '\n' ' ' < "$err")"; break; }
  fi
  gqe=$(echo "$page" | jq -r '.errors // [] | map(.message) | join("; ")' 2>/dev/null)
  if [ -n "$gqe" ]; then ok=0; fail_reason="graphql errors: $gqe"; break; fi
  echo "$page" | jq -e '.data.node.items' >/dev/null 2>&1 || { ok=0; fail_reason="missing .data.node.items (possible partial response)"; break; }
  echo "$page" | jq -c '.data.node.items.nodes[]?' >> "$pages"
  hn=$(echo "$page" | jq -r '.data.node.items.pageInfo.hasNextPage')
  cursor=$(echo "$page" | jq -r '.data.node.items.pageInfo.endCursor')
  [ "$hn" = "true" ] && [ -n "$cursor" ] && [ "$cursor" != "null" ] || break
done
if [ "$ok" != "1" ]; then
  fetch_failed "${fail_reason:-graphql paging error}"
fi

# --- {items: [{content: {number}, status}]} へ正規化 (number null の draft item は除外) ---
if ! jq -s '{items: ([ .[] | { content: { number: (.content.number // null) }, status: ([ .fieldValues.nodes[]? | select(.field.name? == "Status") | .name ] | first // null) } ] | map(select(.content.number == null | not)))}' "$pages" > "$tmpfile" 2>"$err"; then
  fetch_failed "jq normalization failed: $(tr '\n' ' ' < "$err")"
fi

handed_off=1
echo "$tmpfile"
exit 0
