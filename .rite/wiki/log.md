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
| 2026-04-17T00:00:00+00:00 | ingest:create | pages/patterns/script-dir-canonicalize-before-cd.md | PR #550 cycle 1 review findings #2 / cycle 2 finding #5 / fix #2 統合 (_SCRIPT_DIR canonicalize pattern) |
| 2026-04-17T00:00:00+00:00 | ingest:create | pages/patterns/bash-lib-helper-contract-rigour.md | PR #550 cycle 1 finding #1 / fix #1 / cycle 3 fix #3 統合 (lib contract docstring rigour) |
| 2026-04-17T00:00:00+00:00 | ingest:update | pages/patterns/mktemp-failure-surface-warning.md | PR #550 fix cycle 1/3 で silent fallback 一般化のエビデンス追加 |
| 2026-04-17T00:00:00+00:00 | ingest:update | pages/anti-patterns/asymmetric-fix-transcription.md | PR #550 cycle 3 fix で symmetric error handling 一般化のエビデンス追加 |
| 2026-04-17T00:00:00+00:00 | ingest:update | pages/heuristics/stderr-selective-surface-over-truncate.md | PR #550 fix cycle 1 で per-step tempfile 分離のエビデンス追加 |
| 2026-04-17T00:05:00+00:00 | lint:warning | — | contradictions=0, stale=0, orphans=0, missing=13 (全て log に ingest:skip 記録済み), broken_refs=0 |
| 2026-04-17T00:49:00+00:00 | ingest:create | pages/patterns/drift-check-anchor-prose-code-sync.md | PR #553 cycle 1/2/3 review (AC anchor / reasons table / Eval-order / bash emit 順 3 重契約 + distributed-fix-drift-check.sh Pattern-2/5 実証) |
| 2026-04-17T00:49:00+00:00 | ingest:update | pages/anti-patterns/asymmetric-fix-transcription.md | PR #553 cycle 1/2 で mktemp pattern 統一事例 (Phase 内対称化) のエビデンス追加 |
| 2026-04-17T00:49:00+00:00 | ingest:skip | raw/reviews/20260417T003737Z-pr-553-cycle-3.md | cycle 3 final 0 findings 確認のみ、主要知見は cycle 1/2 と drift-check page で統合済み |
| 2026-04-17T00:50:00+00:00 | lint:warning | — | contradictions=0, stale=0, orphans=0, missing=13 (全て log に ingest:skip 記録済み), broken_refs=0 |
| 2026-04-17T04:30:00+00:00 | ingest:create | pages/anti-patterns/prose-design-without-backing-implementation.md | PR #559 review の 8 findings のうち 4 件 (shell 変数未定義 / gate 書式規約忘れ / sentinel consumer 不在 / prose-only safeguard) を集約した anti-pattern |
| 2026-04-17T04:30:00+00:00 | ingest:create | pages/patterns/bash-portable-command-fallback.md | PR #559 review finding (sha1sum macOS 非可搬) を一般化した cross-platform bash コマンド fallback chain pattern |
| 2026-04-17T08:55:00+00:00 | ingest:create | pages/heuristics/identity-reference-documentation-unification.md | PR #562 cycle 1-5 で識別した identity / reference document 用語統一の 5 sub-heuristics 統合ページ (scope drift / self-description / 表記揺れ / bullet 粒度 / enumeration drift / AC metadata) |
| 2026-04-17T08:55:00+00:00 | ingest:update | pages/anti-patterns/asymmetric-fix-transcription.md | PR #562 cycle 2-3 の用語類義語群スコープへの一般化 (文脈類義語群も asymmetric transcription 対象) |
| 2026-04-17T08:55:00+00:00 | ingest:skip | raw/reviews/20260417T082023Z-pr-562.md | cycle 1 review 主要知見は identity-reference-documentation-unification.md に統合済み |
| 2026-04-17T08:55:00+00:00 | ingest:skip | raw/reviews/20260417T084133Z-pr-562.md | cycle 4 mergeable convergence 確認のみ、独自知見なし |
| 2026-04-17T08:55:00+00:00 | ingest:skip | raw/reviews/20260417T084700Z-pr-562.md | cycle 5 final mergeable 確認のみ、独自知見なし |
| 2026-04-17T08:55:00+00:00 | ingest:skip | raw/fixes/20260417T082346Z-pr-562.md | cycle 1 fix 主要知見は identity-reference-documentation-unification.md に統合済み |
| 2026-04-17T08:55:00+00:00 | ingest:skip | raw/fixes/20260417T084423Z-pr-562.md | cycle 5 recommendation-driven fix 主要知見は identity-reference-documentation-unification.md に統合済み |
| 2026-04-17T08:55:30+00:00 | lint:warning | — | contradictions=0, stale=0, orphans=0, missing=50 (大半は ingest:skip 済み raw で sources.ref 未登録状態、log.md に skip 記録あり), broken_refs=0 |
| 2026-04-18T17:40:00+09:00 | ingest:create | pages/patterns/canonical-reference-sample-code-strict-sync.md | PR #564 11th cycle から canonical reference の sample code 逐語照合原則を抽出 |
| 2026-04-18T17:40:00+09:00 | ingest:create | pages/patterns/prompt-numbered-list-isomorphic-structure.md | PR #564 F-01 から prompt numbered list の同型構造原則を抽出 |
| 2026-04-18T17:40:00+09:00 | ingest:update | pages/heuristics/identity-reference-documentation-unification.md | PR #564 F-04 から YAML frontmatter description vs 本文階層 drift を sub-heuristic #6 として追加 |
| 2026-04-18T17:40:00+09:00 | ingest:skip | raw/reviews/20260417T111531Z-pr-564.md | cycle 1 review: 初回指摘 (CRITICAL 3 / HIGH 5 / MEDIUM x) は既存ページ (drift-check-anchor-prose-code-sync / prose-design-without-backing-implementation) でカバー済 |
| 2026-04-18T17:40:00+09:00 | ingest:skip | raw/reviews/20260417T113421Z-pr-564-rereview.md | cycle 1.5 re-review: fix 後の確認のみ、独自知見なし |
| 2026-04-18T17:40:00+09:00 | ingest:skip | raw/reviews/20260417T115035Z-pr-564-cycle3.md | cycle 3 review: 対称化修正確認、新規経験則なし |
| 2026-04-18T17:40:00+09:00 | ingest:skip | raw/reviews/20260417T125050Z-pr-564.md | cycle 4 review: 対称化微調整、既存 asymmetric-fix-transcription.md でカバー済 |
| 2026-04-18T17:40:00+09:00 | ingest:skip | raw/reviews/20260417T152650Z-pr-564.md | cycle 5 review: placeholder gate 修正、既存 bash-if-bang-rc-capture.md でカバー済 |
| 2026-04-18T17:40:00+09:00 | ingest:skip | raw/reviews/20260417T163247Z-pr-564.md | cycle 6 review: trap cleanup 修正、既存 trap-register-before-mktemp.md でカバー済 |
| 2026-04-18T17:40:00+09:00 | ingest:skip | raw/reviews/20260417T230416Z-pr-564.md | cycle 7 review: 継続的対称化、drift-check-anchor-prose-code-sync.md でカバー済 |
| 2026-04-18T17:40:00+09:00 | ingest:skip | raw/reviews/20260418T022836Z-pr-564.md | cycle 8 review: mktemp failure 対応、既存 mktemp-failure-surface-warning.md でカバー済 |
| 2026-04-18T17:40:00+09:00 | ingest:skip | raw/reviews/20260418T041157Z-pr-564.md | cycle 9 review: stderr selective surface 修正、既存 stderr-selective-surface-over-truncate.md でカバー済 |
| 2026-04-18T17:40:00+09:00 | ingest:skip | raw/reviews/20260418T045613Z-pr-564.md | cycle 9.5 re-review: 微調整確認、独自知見なし |
| 2026-04-18T17:40:00+09:00 | ingest:skip | raw/reviews/20260418T060522Z-pr-564.md | cycle 10 review: commit message drift-check anchor 追加、既存 drift-check-anchor-prose-code-sync.md でカバー済 |
| 2026-04-18T17:40:00+09:00 | ingest:skip | raw/fixes/20260417T112318Z-pr-564.md | cycle 1 fix: 初期実装、新規経験則は抽出済みの 2 ページと identity #6 に統合 |
| 2026-04-18T17:40:00+09:00 | ingest:skip | raw/fixes/20260417T114209Z-pr-564-cycle2.md | cycle 2 fix: 対称化適用、asymmetric-fix-transcription.md でカバー済 |
| 2026-04-18T17:40:00+09:00 | ingest:skip | raw/fixes/20260417T115546Z-pr-564-cycle4.md | cycle 4 fix: 対称化微調整、独自知見なし |
| 2026-04-18T17:40:00+09:00 | ingest:skip | raw/fixes/20260417T231720Z-pr-564.md | cycle 7 fix: cross-boundary-state-transfer.md 追加、canonical-reference-sample-code-strict-sync.md にその教訓を格納 |
| 2026-04-18T17:40:00+09:00 | ingest:skip | raw/fixes/20260418T020235Z-pr-564.md | cycle 8 fix: mktemp failure loud WARNING、既存 mktemp-failure-surface-warning.md でカバー済 |
| 2026-04-18T17:40:00+09:00 | ingest:skip | raw/fixes/20260418T043007Z-pr-564.md | cycle 9 fix: placeholder-residue gate 対称化、drift-check-anchor-prose-code-sync.md でカバー済 |
| 2026-04-18T17:40:00+09:00 | ingest:skip | raw/fixes/20260418T054300Z-pr-564.md | cycle 10 fix: commit message canonical 単一真実源、drift-check-anchor-prose-code-sync.md でカバー済 |
| 2026-04-18T17:45:00+09:00 | lint:warning | — | contradictions=0, stale=0, orphans=0, missing_concept=1, unregistered_raw=30, broken_refs=0 |
| 2026-04-18T19:15:00+09:00 | ingest:skip | raw/reviews/20260418T095118Z-pr-574.md | PR #574 は 0 findings の clean docs pass、一般化可能な経験則が抽出できないため skip |
| 2026-04-18T20:05:00+09:00 | ingest:skip | raw/reviews/20260418T105858Z-pr-576.md | PR #576 は 0 findings の defense-in-depth 改善、既存 asymmetric-fix-transcription.md / observed-likelihood-gate-with-evidence-anchors.md でカバー済 |
