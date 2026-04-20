---
title: cleanup-wiki-ingest-turn-boundary
domain: anti-patterns
confidence: high
source_issues: [621, 604, 618, 561]
last_updated: 2026-04-20T19:45:00+09:00
---

# `/rite:pr:cleanup` の Wiki ingest sub-skill return 後に implicit stop が発生する regression

## 背景

`/rite:pr:cleanup` Phase 4.W.2 で `rite:wiki:ingest` を Skill 経由で invoke する。ingest.md Phase 9.1 は三点セット（完了レポート本体 / caller 継続 HTML コメント / `<!-- [ingest:completed] -->` sentinel）を返し、caller である `cleanup.md` は直後に 🚨 Mandatory After Wiki Ingest → Phase 5 完了レポート → `<!-- [cleanup:completed] -->` sentinel を出力する契約になっている。

しかし Issue #604 の対策（5 層 defense-in-depth）を導入した後にも、sub-skill return 後に LLM が implicit stop を起こし、ユーザーが手動で `continue` 入力しなければ Phase 5 に進まない regression が観測されている（Issue #621）。

## 再現手順（PR #619 cleanup 実行時の実観測）

1. `/rite:pr:cleanup #619` を実行
2. cleanup.md Phase 1-4（branch delete / Projects Status update / Issue close / 作業メモリ削除）完了
3. cleanup.md Phase 4.W.2 が `Skill: rite:wiki:ingest` を invoke
4. ingest.md が pending raw source (1 件) を処理し、Phase 8 で `Skill: rite:wiki:lint --auto` を invoke
5. lint Skill が `Lint: contradictions=0, ...` を return
6. ingest.md Phase 9 が三点セットを emit:
   - `Wiki Lint が完了しました ...`（完了レポート本体）
   - `<!-- continuation: caller MUST proceed ... -->`
   - `<!-- [ingest:completed] -->`
7. **`✻ Cooked for 6m 23s` で turn 終了 (implicit stop)** ← bug
8. user が `continue` を入力
9. cleanup.md の 🚨 Mandatory After Wiki Ingest Step 1（`cleanup_post_ingest` patch）+ Phase 5 完了レポート + `<!-- [cleanup:completed] -->` sentinel emit

## 期待動作

手順 6 と手順 9 が**同 turn 内で連続実行される**こと。`Cooked for ...` の turn 境界が形成されてはならない。

## 既存の防御層（5 層 defense-in-depth）

| 層 | 配置 | 期待動作 |
|---|---|---|
| anti-pattern / correct-pattern 契約 | `cleanup.md` 冒頭 | sub-skill return = continuation trigger である旨を明示 |
| Pre-check list Item 0-3 | `cleanup.md` | LLM の self-check で routing dispatcher + state check |
| 🚨 Mandatory After Wiki Ingest Step 1 | `cleanup.md` Phase 4.W 末尾 | `cleanup_post_ingest` patch を即時実行 |
| `stop-guard.sh` の phase block | `hooks/stop-guard.sh` | `cleanup_pre_ingest` / `cleanup_post_ingest` phase で `end_turn` を block し `manual_fallback_adopted` sentinel emit |
| `workflow_incident` 検出 | Phase 5.4.4.1 (start.md 配下) | post-hoc で Issue 自動登録 |

## 根本原因 evidence（Issue #621 S1 Decision Log）

diag log (`.rite-stop-guard-diag.log`) の 2026-04-20 window 集計:

| Phase | Block 発火数 | 備考 |
|-------|-------------|------|
| `cleanup_pre_ingest` | 1（+1 sentinel emit）| Issue #611 cleanup 実行時, 2026-04-20T01:48:58Z[^611-ref] |
| `cleanup_post_ingest` | 0 | 本 phase での block 記録なし |

[^611-ref]: `.rite-stop-guard-diag.log` の `issue=#611` タグ由来。cleanup.md が PR/Issue どちらの番号で invoke されても diag log には Issue number が記録されるため、本表の `#611` は **Issue 番号**（PR ではない）。下記 H2 行の参照も同様に Issue 番号として扱う。

**H1-H4 絞り込み**:

| ID | 仮説 | 結論 |
|---|---|---|
| H1 | ingest.md Phase 9.1 の三点セットが turn-boundary heuristic を強化 | **Likely (primary)** |
| H2 | `stop-guard.sh` の block が発火していない | **部分否定**（Issue #611 cleanup 実行時に block 観測[^611-ref]） |
| H3 | Pre-check list が LLM self-introspection に依存 | **Likely (co-primary)** |
| H4 | sub-skill stack の depth が深く「最深 = 全体完了」誤認 | **Possibly (H1 複合)** |

**primary root cause: H1 + H3 の複合**。stop-guard 自体は機能するが、Pre-check list の self-check 依存が silent 失敗経路を温存する。

## 対策（Issue #621 で実施）

1. **cleanup.md Pre-check list Item 0 の機械化**: `[routing-check] ingest=matched|unmatched` / `[routing-check] cleanup=matched|unmatched` の 1 行出力義務化で LLM の silent skip を検出可能にする
2. **ingest.md Phase 9.1 の三点セット #2/#3 間 recap 挿入禁止**: MUST NOT 行を追加し、caller 継続 HTML コメント直後に即 sentinel を出力する規約を reinforce
3. **unit test fixture** (`plugins/rite/hooks/tests/stop-guard-cleanup.test.sh`、4 tests / 14 assertions、実行: `bash plugins/rite/hooks/tests/run-tests.sh` で既存 hook test suite と共に自動実行): stop-guard.sh を `cleanup_pre_ingest` / `cleanup_post_ingest` / `cleanup` phase で invoke、exit 2 + stderr に Phase 情報 + HINT-specific 文言が出力されることを assert (Test 4 は active:false 時の正常終了を negative assertion で検証)。既存 `stop-guard.test.sh` TC-608-A〜H とは役割分担: 本 fixture は **fixture ベースで独立実行可能** (同テストを異なる環境でスタンドアロン起動する用途)、TC-608-A〜H は **HINT-specific 文言 pin** (regression 検知性能優先)。両者は同一 HINT 文言を pin するため相補関係を形成する (片方の regression でもう片方が catch)

## 関連 Issue

- **#621** — 本 regression の追跡 Issue
- **#604** — 原 Issue (CLOSED)、5 層 defense-in-depth の導入元
- **#618** — 対称問題 (OPEN)、ingest.md Phase 8 auto-lint return 後の implicit stop
- **#561** — bare-sentinel 禁止規約の原点（create.md での同型問題解決）

## 関連参考パターン

Wiki 内部ページ (`.rite/wiki/pages/` 配下、`wiki` ブランチ) の経験則ページへの参照:

- `.rite/wiki/pages/patterns/state-machine-dual-location-sync.md` — defense-in-depth 設計
- `.rite/wiki/pages/anti-patterns/test-false-positive-early-exit.md` — self-check 信頼性

これらのページは `separate_branch` 戦略 (`rite-config.yml` の `wiki.branch_strategy: separate_branch`) により dev ブランチ上では直接閲覧できない。Wiki 内容を参照するには `git worktree add .rite/wiki-worktree wiki` で worktree を展開するか、`/rite:wiki:query state-machine-dual-location-sync` 等で内容を取り込む (slash command は positional argument のみ受理、`--keywords` 形式は `wiki-query-inject.sh` 起動時の内部 bash 呼び出し専用)。
