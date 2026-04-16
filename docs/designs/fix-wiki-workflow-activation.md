# Wiki 機能が実ワークフローで発火しない問題の根本修正

<!-- Section ID: SPEC-OVERVIEW -->
## 概要

rite workflow の Wiki 機能（経験則の自動蓄積）が、実際のワークフロー経路（`/rite:pr:review` → `/rite:pr:fix` → `/rite:issue:close`）から一度も発火していない問題を根本修正する。

現状、wiki branch には raw source が 7 件 commit されているが、それらは全て `fix/issue-528-wiki-raw-commit-shell-path` 作業中に Claude Code が検証用に手動で叩いた残骸であり、自然な PR ワークフローから発火した raw source は **ゼロ件**。さらにページ統合経路（`/rite:wiki:ingest`）は設計上どこからも自動発火しない状態。結果として Wiki は「動いている錯覚」だけ残して実質的に死に体になっている。

本修正では (1) raw 蓄積経路の実ワークフロー発火を保証し、(2) ページ統合経路を自動発火させ、(3) 監視 blind spot を封鎖する。

<!-- Section ID: SPEC-BACKGROUND -->
## 背景・目的

### 現状の問題

`rite-config.yml` は `wiki.enabled: true` / `wiki.auto_ingest: true` と設定済みで先制条件は満たされている。しかし実 commit 履歴を調査した結果:

- **wiki branch の 7 commits は全て 2026-04-15 に集中** し、`fix/issue-528-wiki-raw-commit-shell-path` 由来のメッセージのみ
- #526, #527, #530, #531 といった 04-16 以降に自然マージされた PR 由来の raw source は **1 件も存在しない**
- `.rite/wiki/pages/` は **0 ファイル**、`index.md`/`log.md` は初期状態から更新されていない

### 直近 fix (#526/#528/#529) の限界

- **#526 (silent skip 3 層防御)**: 「Phase が実行されたが silent skip される」ケースに対する防御。しかし **Phase そのものが実行されない** 今回のケースには効果ゼロ。
- **#528/#529 (raw commit の shell script 化)**: `wiki-ingest-commit.sh` 単体は動くが、それを呼び出す側の Phase 6.5.W.2 / 4.6.W.2 / 4.4.W.2 が実ワークフローで起動していない。shell script 単体動作テストと E2E ワークフロー発火の差を見落とした。

### 3 つの決定的な実装欠陥

| # | ファイル | 症状 |
|---|---|---|
| 1 | `plugins/rite/commands/issue/start.md` Phase 5.7.2 | `gh issue close` を直接実行し、`/rite:issue:close` skill を Skill ツールで invoke していない。結果、close.md の Phase 4.4.W.2（raw 蓄積経路）が **100% silent skip** |
| 2 | `plugins/rite/commands/pr/review.md` Phase 6.5.W.2 | Phase 実装自体は存在するが、`[review:mergeable]` 系 early return 経路で Phase 6.5.W.2 まで制御が到達していない疑い |
| 3 | `plugins/rite/commands/pr/fix.md` Phase 4.6.W.2 | 同じく `[fix:pushed]` 系 early return 経路で Phase 4.6.W.2 まで到達していない疑い |

加えて:

- **ページ統合経路の自動発火が設計上どこにも存在しない**: `/rite:wiki:ingest` を呼ぶ hook/schedule/session start 通知はゼロ。`review.md` の rationale には "deferred to `/rite:wiki:ingest`, which can be invoked later — manually, or automatically in a separate session" と書かれているが、「別セッションで自動実行」の仕組みは未実装。

### 目的

- 実ワークフローの自然な実行からの raw source 蓄積を保証する
- raw 蓄積されたものが自動でページ統合されるようにする
- raw 発火ゼロ・ページ停滞という blind spot を監視で封鎖する
- 坂口さんが「何もしなくても経験則が溜まっていく」体験を取り戻す

## 要件

<!-- Section ID: SPEC-REQ-FUNC -->
### 機能要件

| FR | 説明 |
|---|---|
| FR-1 | 実ワークフローで `/rite:issue:close` skill が invoke されること（`start.md` Phase 5.7.2 から Skill ツール経由で呼ぶ）|
| FR-2 | `/rite:pr:review` 通常実行で Phase 6.5.W.2（raw 蓄積）まで制御が到達すること |
| FR-3 | `/rite:pr:fix` 通常実行で Phase 4.6.W.2（raw 蓄積）まで制御が到達すること |
| FR-4 | `/rite:pr:cleanup` 完了時に pending raw source を `/rite:wiki:ingest` で統合すること（Skill 経由） |
| FR-5 | `/rite:pr:cleanup` からの ingest 失敗が cleanup 本体の fail を引き起こさないこと（loss-safe continuation） |
| FR-6 | `wiki-growth-check.sh` が「直近 N 個の merged PR に対応する raw source が wiki branch に存在するか」を検知できること |
| FR-7 | `wiki-growth-check.sh` が「raw が増えているのにページ数が停滞している」blind spot を検知できること |
| FR-8 | 全ての修正後、新規 PR を自然に流しただけで wiki branch の raw source とページが共に増えること（E2E 回帰テスト）|

<!-- Section ID: SPEC-REQ-NFR -->
### 非機能要件

| NFR | 説明 |
|---|---|
| NFR-1 | #528/#529 の責務分離（raw 層 = shell script、page 層 = LLM）は維持する |
| NFR-2 | loss-safety 絶対維持: page 統合失敗時も raw source は失われない |
| NFR-3 | Issue #525 の orchestrator auto-continuation 問題の再発を避ける（同セッション Skill 呼び出しの contract を明示的に強化する） |
| NFR-4 | `start.md` の `gh issue close` 削除時に、issue close 自体が実行されなくなる regression を避ける |
| NFR-5 | ingest 実行による `cleanup` の体感速度悪化は許容範囲内（ユーザー確認済み） |
| NFR-6 | `wiki.enabled=false` のプロジェクトでは新 Phase を silent skip する |

<!-- Section ID: SPEC-TECH-DECISIONS -->
## 技術的決定事項

1. **「PR cleanup 時に同セッション実行」方式を採用**: 坂口さんの選好。別セッション起動や cron 方式は将来検討の余地あり（現時点では不採用）。
2. **Phase 0 (trace) を修正前の必須 gating として位置づけ**: 実ワークフローでの発火状況を計測しないと、どの Phase が真因かを断定できない。trace 結果に応じて Phase 1-B の具体手法が変わる。
3. **start.md の `gh issue close` は完全削除せず、close.md 側で確実に close する契約に置換**: close.md が close を行わない場合 issue が閉じなくなる regression を避ける。
4. **wiki-growth-check.sh は総合 health check に拡張**: 現状の「commit 数しか見ない」から、「PR ↔ raw 対応」「raw vs page 比」「直近 pending 数」を総合判定する health check に進化させる。
5. **Phase 3 (SKILL.md trouble-shooting 追記) は low priority**: 実装修正の副産物として整備する。

## アーキテクチャ

<!-- Section ID: SPEC-ARCH-COMPONENTS -->
### コンポーネント構成

```
実ワークフロー経路（raw 蓄積）
├── /rite:issue:start  ── Phase 5.7.2 ──→ Skill: /rite:issue:close  （FR-1, Phase 1-A）
├── /rite:pr:review    ── Phase 6.5.W.2 ─→ wiki-ingest-trigger.sh + wiki-ingest-commit.sh  （FR-2, Phase 1-B）
├── /rite:pr:fix       ── Phase 4.6.W.2 ─→ 同上                     （FR-3, Phase 1-B）
└── /rite:issue:close  ── Phase 4.4.W.2 ─→ 同上                     （FR-1 経由で起動）

ページ統合経路（新設）
└── /rite:pr:cleanup   ── 末尾新 Phase ─→ Skill: /rite:wiki:ingest  （FR-4/5, Phase 2-A）

監視経路（拡張）
└── wiki-growth-check.sh
    ├── 直近 N merged PR ↔ raw source 対応検知  （FR-6, Phase 1-C）
    └── raw vs page 停滞検知                    （FR-7, Phase 3）
```

<!-- Section ID: SPEC-ARCH-DATAFLOW -->
### データフロー

1. **現状の dead flow**: PR merge → cleanup → **何も起きない** → wiki 空のまま
2. **修正後の live flow**: PR merge → review の Phase 6.5.W.2 で raw commit → fix cycle の Phase 4.6.W.2 で raw commit → close の Phase 4.4.W.2 で raw commit → cleanup 末尾の新 Phase で `/rite:wiki:ingest` 自動実行 → ページ生成

## 実装ガイドライン

<!-- Section ID: SPEC-IMPL-FILES -->
### 変更が必要なファイル/領域

| ファイル | Phase | 変更内容 |
|---|---|---|
| `plugins/rite/commands/issue/start.md` | 1-A | Phase 5.7.2 の `gh issue close` 直接実行を `Skill: rite:issue:close` に置換 |
| `plugins/rite/commands/pr/review.md` | 1-B | Phase 6.5.W.2 の到達経路確保（Phase 0 trace 結果次第）|
| `plugins/rite/commands/pr/fix.md` | 1-B | Phase 4.6.W.2 の到達経路確保（同上） |
| `plugins/rite/commands/pr/cleanup.md` | 2-A | 末尾に ingest 自動発火 Phase を追加 |
| `plugins/rite/hooks/scripts/wiki-growth-check.sh` | 1-C + 3 | PR ↔ raw 対応検知 + raw vs page 停滞検知を追加 |
| `plugins/rite/commands/wiki/ingest.md` | 2-B (条件付き) | Phase 0 で failure が見つかった場合のみ debug |
| `plugins/rite/skills/wiki/SKILL.md` | 3 | trouble-shooting 節を追加 |

<!-- Section ID: SPEC-IMPL-CONSIDERATIONS -->
### 考慮事項

- **Phase 0 (trace) の必須性**: Phase 1-B の具体的修正手法は trace 結果なしでは確定できない。trace を飛ばして修正すると盲目的な修正になり、再び regression を生む危険がある。
- **start.md の `gh issue close` 置換の安全性**: close.md 側で確実に close されることを事前精査してから置換する。置換後は手動 E2E で issue が実際に closed 状態になることを確認する。
- **cleanup の重量化**: ingest には LLM 解析が含まれ時間がかかる。ユーザーは了承済みだが、進捗表示やキャンセル可能性を考慮する。
- **sentinel 契約**: ingest 失敗時は必ず sentinel を書き出し、次回の `wiki-growth-check.sh` で検出可能にする。silent skip は絶対に許さない。
- **wiki 無効プロジェクトでの副作用**: 新 Phase は `rite-config.yml` の `wiki.enabled` を先制チェックし、無効なら silent skip（警告なしで通過）する。
- **教訓の永続化**: 今回の診断ミス（shell script 単体動作を E2E と誤認）は feedback memory に記録し、今後同じ失敗を繰り返さないようにする。

<!-- Section ID: SPEC-OUT-OF-SCOPE -->
## スコープ外

- **cron / schedule ベースの別セッション自動発火**: 将来検討。現時点では不採用。
- **SessionStart hook でのダッシュボード通知**: 将来検討。
- **`/rite:wiki:status` コマンドの新設**: 現行 wiki-growth-check.sh の拡張で代替。
- **wiki branch 戦略の変更**: `separate_branch` のまま維持。
- **経験則ページの内容品質改善（ingest.md の LLM prompt 調整）**: Phase 0 で ingest.md が壊れていると判明した場合のみ debug、それ以外はスコープ外。
