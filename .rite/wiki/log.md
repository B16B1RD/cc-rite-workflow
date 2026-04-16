# Wiki 活動ログ

このファイルは Wiki の活動を時系列で記録します（append-only）。

## 活動ログ

| 日時 | アクション | 対象 | 詳細 |
|------|-----------|------|------|
| 2026-04-14T00:02:30+00:00 | init | — | Wiki を初期化しました |
| 2026-04-17T00:15:00+00:00 | ingest:create | pages/heuristics/fix-verification-requires-natural-workflow-firing.md | issue-532 retrospective (manual sample ingest for Issue 調査) |
| 2026-04-16T19:37:16+00:00 | ingest:create | pages/anti-patterns/asymmetric-fix-transcription.md | PR #548 cycle 3-6 の dominant pattern (pr-548 fix/review cycles 3-6) |
| 2026-04-16T19:37:16+00:00 | ingest:create | pages/anti-patterns/bash-if-bang-rc-capture.md | `if ! cmd; then rc=$?` 常に 0 を捕捉する gotcha (pr-529/548) |
| 2026-04-16T19:37:16+00:00 | ingest:create | pages/heuristics/stderr-selective-surface-over-truncate.md | pr-529 cycle 3 で検出された silent regression pattern |
| 2026-04-16T19:37:16+00:00 | ingest:create | pages/patterns/trap-register-before-mktemp.md | tempfile lifecycle race (pr-529 cycle 3 / pr-548 cycles 1, 4) |
| 2026-04-16T19:37:16+00:00 | ingest:create | pages/patterns/exit-code-semantic-preservation.md | pr-529 の exit 2 = legitimate skip semantic mismatch |
| 2026-04-16T19:37:16+00:00 | ingest:create | pages/patterns/mktemp-failure-surface-warning.md | pr-548 cycle 1 で mktemp silent 握り潰し禁止を明文化 |
| 2026-04-16T19:37:16+00:00 | ingest:create | pages/patterns/jq-create-mode-preserve-existing.md | pr-545 CRITICAL: parent_issue_number リセット問題 |
| 2026-04-16T19:37:16+00:00 | ingest:create | pages/heuristics/shell-script-shared-lib-extraction.md | pr-544 DRY refactor + pr-548 F-05/F-06 の root cause |
| 2026-04-16T19:37:16+00:00 | ingest:create | pages/heuristics/phase-number-structural-symmetry.md | pr-541 orphan sub-phase + enforcement note drift |
| 2026-04-16T19:37:16+00:00 | ingest:create | pages/patterns/worktree-based-separate-branch-write.md | Issue #547 worktree 設計 (pr-548 全 cycle) |
| 2026-04-16T19:37:16+00:00 | ingest:create | pages/heuristics/observed-likelihood-gate-with-evidence-anchors.md | pr-540/548 で適用された severity gate |
| 2026-04-16T19:37:16+00:00 | ingest:batch | raw/fixes/*.md + raw/reviews/*.md | 34 raw sources ingested → 10 new pages + 0 updates + 24 sources referenced across pages |
| 2026-04-16T19:37:16+00:00 | ingest:skip | raw/fixes/20260415T101120Z-pr-529-fix-cycle-2.md | cycle 2 完了のみ記述、extractable lesson なし |
| 2026-04-16T19:37:16+00:00 | ingest:skip | raw/reviews/20260415T095532Z-pr-529-fix.md | smoke test 記述のみ |
| 2026-04-16T19:37:16+00:00 | ingest:skip | raw/reviews/20260415T124053Z-pr-529-cycle-4-smoke.md | smoke test 記述のみ |
| 2026-04-16T19:37:16+00:00 | ingest:skip | raw/reviews/20260416T041138Z-pr-541-re.md | 再レビュー 0 件の確認のみ |
| 2026-04-16T19:37:16+00:00 | ingest:skip | raw/reviews/20260416T075144Z-pr-542.md | 他ページで既出パターン（stderr/docs sync） |
| 2026-04-16T19:37:16+00:00 | ingest:skip | raw/reviews/20260416T080032Z-pr-542.md | マージ可能確認のみ |
| 2026-04-16T19:37:16+00:00 | ingest:skip | raw/reviews/20260416T083552Z-pr-543.md | cleanup Phase 4.W 実装固有の findings（本 PR #548 でスコープ完了） |
| 2026-04-16T19:37:16+00:00 | ingest:skip | raw/reviews/20260416T084148Z-pr-543-cycle2.md | 再レビュー 0 件の確認のみ |
| 2026-04-16T19:37:16+00:00 | ingest:skip | raw/reviews/20260416T092655Z-pr-544.md | 再レビュー 0 件の確認のみ |
| 2026-04-16T19:37:16+00:00 | ingest:skip | raw/reviews/20260416T123322Z-pr-545.md | i18n ハードコード (本 repo 固有 doc scope) |
| 2026-04-16T19:37:16+00:00 | ingest:skip | raw/reviews/20260416T124118Z-pr-545.md | 収束確認のみ |
| 2026-04-16T19:37:16+00:00 | ingest:skip | raw/reviews/20260416T131535Z-pr-546.md | 0 findings whitelist 追加 PR |
| 2026-04-16T19:45:00+00:00 | lint:warning | — | contradictions=0, stale=0, orphans=0, missing=13 (全て log に ingest:skip 記録済み), broken_refs=0 |
