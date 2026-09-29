# Non-fatal Record

共通 triage が永続化した JSON から既存の関連 Issue 記録を更新する。修正対象が 0 件でも実行し、終端 outcome の確認を終えるまで成功を返さない。失敗は `[fix:error] reason=nonblocking_record_*` を出して exit 1 で止まる。

`{triage_review_path}` / `{non_fatal_moved_count}` はステップ 1.2.2 の実際の値を使う。`{review_cycle_id}` は直前レビューの cycle ID（無い場合は今回生成した一意 ID）を使う。`{owner_repo}` は解決済みの slash 形式。

```bash
bash {plugin_root}/scripts/fix-step.sh non-fatal-record --pr {pr_number} --owner-repo {owner_repo} \
  --triage-review-path '{triage_review_path}' --non-fatal-moved-count {non_fatal_moved_count} --review-cycle-id {review_cycle_id}
```

成功後、ステップ 1.4 / 4.6 の non-blocking section と E2E 1 行に件数・今回の移送件数・同じ JSON pointer を表示する。移送指摘を破棄したり、Issue 記録を `/rite:pr-review` 任せにしたりしない。
