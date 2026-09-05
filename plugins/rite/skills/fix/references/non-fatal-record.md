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
