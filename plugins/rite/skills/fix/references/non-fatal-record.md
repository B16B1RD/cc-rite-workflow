# Non-fatal Record

共通 triage が永続化した JSON から既存の関連 Issue 記録を更新する。修正対象が 0 件でも実行し、終端 outcome の確認を終えるまで成功を返さない。

`{triage_review_path}` / `{non_fatal_moved_count}` はステップ 1.2.2 の実際の値を使う。`{review_cycle_id}` は直前レビューの cycle ID（無い場合は今回生成した一意 ID）を使う。`{owner_repo}` は解決済みの slash 形式。

```bash
triage_review_path="{triage_review_path}"
record_body=$(mktemp "${TMPDIR:-/tmp}/rite-fix-nbr-body-XXXXXX") || {
  echo "[fix:error] reason=nonblocking_record_tempfile_failed"
  exit 1
}
record_log=$(mktemp "${TMPDIR:-/tmp}/rite-fix-nbr-log-XXXXXX") || {
  rm -f "$record_body"
  echo "[fix:error] reason=nonblocking_record_tempfile_failed"
  exit 1
}
if ! non_blocking_count=$(jq '[.non_blocking_findings[]? | select(.scope != "nit-noted")] | length' "$triage_review_path"); then
  rm -f "$record_body" "$record_log"
  echo "[fix:error] reason=nonblocking_record_read_failed"
  exit 1
fi
# 既存 marker / count / 最終行 sentinel を維持し、pointer と降格理由を記録する（全文・証跡は永続 JSON のみに保持）。
if ! jq -r --arg pr "{pr_number}" --arg pointer "$triage_review_path" \
  --arg moved "{non_fatal_moved_count}" --arg count "$non_blocking_count" '
  "## 📜 rite 非実測指摘の記録",
  "", "PR #" + $pr, "",
  "### non-blocking (非 fatal・実測なし)",
  "今回の移送: " + $moved + "件", "記録 JSON: " + $pointer,
  "", "📎 non_blocking_count: " + $count, "",
  (.non_blocking_findings[]? | select(.scope != "nit-noted")
    | [.id, (.reviewer // ""), .severity, (.file + ":" + ((.line // "anchor") | tostring)),
       (.demotion_reason // .demotion.reason // "unmeasured")] | @tsv),
  "", "<!-- rite:nbr:v1 -->"
' "$triage_review_path" > "$record_body"; then
  rm -f "$record_body" "$record_log"
  echo "[fix:error] reason=nonblocking_record_body_failed"
  exit 1
fi
# helper は既存の記録を全文 PATCH で置き換えるので、その却下台帳を新本文へ引き継ぐ。
# 関連 Issue は helper と同じ規則（PR body の closing keyword → branch 名の issue-N）で決める。
ledger_issue=""
if ledger_pr=$(gh pr view "{pr_number}" -R "{owner_repo}" --json body,headRefName) \
  && ledger_pr_body=$(printf '%s' "$ledger_pr" | jq -r '.body // ""') \
  && ledger_head=$(printf '%s' "$ledger_pr" | jq -r '.headRefName // ""'); then
  ledger_issue=$(printf '%s' "$ledger_pr_body" | grep -ioE '(close[sd]?|fix(e[sd])?|resolve[sd]?) #[0-9]+' | head -1 | grep -oE '[0-9]+$')
  if [ -z "$ledger_issue" ] && [[ "$ledger_head" =~ issue-([0-9]+) ]]; then
    ledger_issue="${BASH_REMATCH[1]}"
  fi
fi
if [ -z "$ledger_issue" ]; then
  rm -f "$record_body" "$record_log"
  echo "[fix:error] reason=nonblocking_record_issue_unresolved"
  exit 1
fi
ledger_existing=$(mktemp "${TMPDIR:-/tmp}/rite-fix-nbr-existing-XXXXXX") \
  && ledger_file=$(mktemp "${TMPDIR:-/tmp}/rite-fix-nbr-ledger-XXXXXX") || {
  rm -f "$record_body" "$record_log" "${ledger_existing:-}"
  echo "[fix:error] reason=nonblocking_record_tempfile_failed"
  exit 1
}
if ! gh api "repos/{owner_repo}/issues/$ledger_issue/comments" --paginate \
  --jq '.[] | select(.body | startswith("## 📜 rite 非実測指摘の記録")) | .body' > "$ledger_existing"; then
  rm -f "$record_body" "$record_log" "$ledger_existing" "$ledger_file"
  echo "[fix:error] reason=nonblocking_record_ledger_fetch_failed"
  exit 1
fi
if [ -s "$ledger_existing" ] \
  && ! bash {plugin_root}/hooks/scripts/nb-sweep-ledger.sh extract --body-file "$ledger_existing" > "$ledger_file"; then
  rm -f "$record_body" "$record_log" "$ledger_existing" "$ledger_file"
  echo "[fix:error] reason=nonblocking_record_ledger_extract_failed"
  exit 1
fi
if ! bash {plugin_root}/hooks/scripts/nb-sweep-ledger.sh merge-into --body-file "$record_body" --ledger-file "$ledger_file"; then
  rm -f "$record_body" "$record_log" "$ledger_existing" "$ledger_file"
  echo "[fix:error] reason=nonblocking_record_ledger_merge_failed"
  exit 1
fi
rm -f "$ledger_existing" "$ledger_file"
echo "[CONTEXT] REJECTED_LEDGER_PRESERVE=ok" >&2
record_rc=0
bash {plugin_root}/hooks/review-nonblocking-record.sh \
  --pr "{pr_number}" --owner-repo "{owner_repo}" \
  --count "$non_blocking_count" --iteration-id "{review_cycle_id}" \
  --content-file "$record_body" 2> "$record_log" || record_rc=$?
cat "$record_log" >&2
# helper は failed でも rc=0 を返しうる。終端 outcome を必ず検査する。
record_done=$(sed -n 's/^\[CONTEXT\] NONBLOCKING_RECORD_DONE=1; .*outcome=\([^;]*\);.*/\1/p' "$record_log" | tail -1)
record_ok=0
if [ "$record_rc" -eq 0 ]; then
  case "$record_done" in
    created|updated) record_ok=1 ;;
    skipped) [ "$non_blocking_count" -eq 0 ] && record_ok=1 ;;
  esac
fi
rm -f "$record_body" "$record_log"
if [ "$record_ok" -ne 1 ]; then
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nonblocking_record_failed" >&2
  echo "[fix:error] reason=nonblocking_record_failed"
  exit 1
fi
```

成功後、ステップ 1.4 / 4.6 の non-blocking section と E2E 1 行に件数・今回の移送件数・同じ JSON pointer を表示する。移送指摘を破棄したり、Issue 記録を `/rite:pr-review` 任せにしたりしない。
