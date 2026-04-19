---
name: wiki
description: |
  rite Wiki layer — project-specific experiential knowledge persistence based on the
  LLM Wiki pattern (Karpathy). Use when the user asks to ingest review/fix/issue
  outcomes into Wiki pages, query accumulated experiential knowledge by keyword,
  lint the Wiki for contradictions, stale pages, orphans, missing concepts,
  unregistered raw sources, and broken references, or initialize the Wiki structure.
  Activates on "wiki", "ingest", "query", "lint", "経験則", "知識ページ",
  "Wiki 蓄積", "経験則を残す", "経験則を参照", "Wiki 検索", "Wiki Lint",
  "Wiki 品質", "矛盾チェック", "陳腐化", "孤児ページ",
  "欠落概念", "missing_concept", "壊れた相互参照", "broken_refs",
  "未登録 raw", "unregistered_raw",
  "wiki:init", "wiki:ingest", "wiki:query", "wiki:lint",
  "/rite:wiki:".
---

# Wiki Skill

`rite-workflow` の経験則 Wiki 層に対する操作スキル。プロジェクト固有の経験則（実装パターン・レビュー指摘・修正パターン）を `.rite/wiki/` 配下に Markdown ページとして蓄積・参照・メンテナンスします。

## Auto-Activation Keywords

- wiki, Wiki, 経験則, 知識ページ
- ingest, 蓄積, 経験則を残す
- query, 経験則を参照, Wiki 検索
- lint, Wiki Lint, Wiki 品質, 矛盾チェック, 陳腐化, 孤児ページ, 欠落概念, missing_concept, 壊れた相互参照, broken_refs, 未登録 raw, unregistered_raw
- `/rite:wiki:init`, `/rite:wiki:ingest`, `/rite:wiki:query`, `/rite:wiki:lint`

## アーキテクチャ概要

`.rite/wiki/` 配下に3層構造で経験則を管理します:

| 層 | 場所 | 所有者 | 性質 |
|---|---|---|---|
| **Raw Sources** | `.rite/wiki/raw/{reviews,retrospectives,fixes}/` | rite ワークフロー（自動生成） | 不変の一次データ |
| **Wiki Pages** | `.rite/wiki/pages/{patterns,heuristics,anti-patterns}/` | LLM（自動生成・更新） | 統合された加工済み知識 |
| **Schema** | `.rite/wiki/SCHEMA.md` | 人間 + LLM | 蓄積規約 |

詳細は [docs/designs/experience-heuristics-persistence-layer.md](../../../../docs/designs/experience-heuristics-persistence-layer.md) を参照。

## 提供コマンド

| コマンド | 説明 | 状態 |
|---------|------|------|
| `/rite:wiki:init` | Wiki 初期化（ディレクトリ・テンプレート・ブランチ） | 実装済み (#468) |
| `/rite:wiki:ingest` | Raw Source から経験則を抽出・統合 | 実装済み (#469) |
| `/rite:wiki:query` | 経験則の参照・コンテキスト注入 | 実装済み (#470) |
| `/rite:wiki:lint` | Wiki の品質チェック（5 ブロッキング: 矛盾・陳腐化・孤児・欠落概念・壊れた相互参照 + 1 informational: 未登録 raw） | 実装済み (#471) |

## 関連ファイル

- [Wiki Patterns](../../references/wiki-patterns.md) — ディレクトリ構造・ブランチ操作・テンプレート展開の共通パターン
- [page-template.md](../../templates/wiki/page-template.md) — Wiki ページの YAML frontmatter
- [SCHEMA テンプレート](../../templates/wiki/schema-template.md) — 蓄積規約の初期テンプレート

## 設定

`rite-config.yml` の `wiki` セクションで制御:

> **opt-out ポリシー**: `wiki:` セクション自体を省略しても、Wiki 機能はデフォルトで有効として扱われます (`wiki.enabled: true` 相当)。明示的に無効化したい場合のみ `enabled: false` を設定してください。本ポリシーは `wiki.enabled` のみに適用され、`auto_query` / `auto_ingest` 等の他のキーは省略時に各キー個別のデフォルト (下記参照) が適用されます。

```yaml
wiki:
  enabled: true                        # opt-out (default true、セクション未指定時も有効扱い)
  branch_strategy: "separate_branch"   # separate_branch (推奨) or same_branch
  branch_name: "wiki"                  # separate_branch 時のブランチ名
  auto_ingest: true                    # Auto-ingest on review/fix/close
  auto_query: true                     # Auto-query on start/review/fix/implement
  auto_lint: true                      # Ingest 完了時の自動品質チェック (default true)
```

## トリガースクリプト

`/rite:wiki:ingest` の実行前に Raw Source を `.rite/wiki/raw/{type}/` にステージングするヘルパー:

```bash
bash plugins/rite/hooks/wiki-ingest-trigger.sh \
  --type reviews \
  --source-ref pr-123 \
  --content-file /tmp/review-result.md \
  --pr-number 123 \
  --title "Code review for PR #123"
```

詳細は `wiki-ingest-trigger.sh --help` を参照。

## Query 注入スクリプト

`/rite:wiki:query` の検索ロジック本体。他コマンドから直接呼び出して経験則をコンテキストに注入できます:

```bash
# --max-pages / --min-score はデフォルト値と同一の場合は省略可 (下記は最小呼び出し例)
bash plugins/rite/hooks/wiki-query-inject.sh \
  --keywords "database,migration" \
  --format compact
```

- `wiki.enabled: false` や Wiki 未初期化のとき stdout を空にして exit 0（非ブロッキング）
- `index.md` をキーワードで検索し、タイトル・ドメイン・サマリーのマッチ数を集計
- 確信度（high/medium/low）で重み付けし、スコア降順で上位 N 件を Markdown ブロックとして出力
- `--format full` でページ本文（YAML frontmatter 除く）まで含めて出力

詳細は `wiki-query-inject.sh --help` を参照。

## トラブルシューティング

Wiki 機能が期待通りに動作しない場合の診断手順。

### raw source が増えていない場合

raw source は `/rite:pr:review`（Phase 6.5.W.2）、`/rite:pr:fix`（Phase 4.6.W.2）、`/rite:issue:close`（Phase 4.4.W.2）で自動生成されます。raw が増えていない場合:

1. **wiki.enabled を確認**: `rite-config.yml` で `wiki.enabled: true` になっているか
2. **wiki.auto_ingest を確認**: `wiki.auto_ingest: true` になっているか（`false` だと raw 蓄積のトリガーが無効化される）
3. **wiki branch の存在を確認**: `git branch -a | grep wiki` で wiki branch が存在するか。存在しない場合は `/rite:wiki:init` を実行するか `git fetch origin wiki:wiki` を実行
4. **Phase X.X.W の sentinel を確認**: 完了レポートの `### 📚 Wiki ingest 状況` セクションで `SKIPPED` や `FAILED` のカウントを確認
5. **workflow incident を確認**: `[CONTEXT] WIKI_INGEST_SKIPPED=1` や `WIKI_INGEST_FAILED=1` が Phase 5.4.4.1 で検出・報告されているか

### raw は増えているがページが増えない場合

raw source は蓄積されているが `.rite/wiki/pages/` にページが生成されていない場合:

1. **`/rite:wiki:ingest` を手動実行**: ページ統合は `/rite:wiki:ingest` で実行されます。自動発火は `/rite:pr:cleanup` の末尾 Phase で行われるため、cleanup を実行していない場合はページが生成されません
2. **pending raw を確認**: `wiki-growth-check.sh` の出力で `pending` 数を確認。`ingested: false` のまま残っている raw source が多い場合は ingest が実行されていません
3. **ingest のエラーログを確認**: `/rite:wiki:ingest` 実行時に LLM 解析エラーが発生していないか確認
4. **SCHEMA.md の整合性を確認**: `.rite/wiki/SCHEMA.md` が正しくセットアップされているか。`/rite:wiki:lint` で品質チェックを実行

### 手動 `/rite:wiki:ingest` の実行タイミング

以下のタイミングで手動実行を推奨:

- **PR cleanup 後に自動発火しなかった場合**: cleanup.md の末尾 Phase で ingest が skip された場合
- **`wiki-growth-check.sh` が page stall を検出した場合**: `==> Page stall detected` の出力があった場合
- **大量の pending raw source がある場合**: `pending` 数が raw 総数の 50% を超えている場合
- **Wiki を初めて使い始める場合**: `/rite:wiki:init` 実行後、既存の raw source をページ化するため

実行方法: `/rite:wiki:ingest` を Claude Code で呼び出す。

### `wiki-growth-check.sh` の alarm の読み方

`wiki-growth-check.sh` は `/rite:lint` から呼び出される総合 health check です。以下の alarm を出力します:

| alarm | 意味 | 対処 |
|-------|------|------|
| `Wiki growth stall detected` | wiki branch の最終 commit 以降に N 件以上の PR がマージされたが、raw source が追加されていない | Phase X.X.W が silent skip されている。review.md / fix.md / close.md の Wiki Phase 到達を確認 |
| `PR↔raw correspondence gap` | 直近の merged PR に対応する raw source ファイル（`pr-{number}` 名）が wiki branch に存在しない | 個別 PR の Phase X.X.W 実行を確認。`wiki-ingest-trigger.sh` / `wiki-ingest-commit.sh` のログを確認 |
| `Page stall detected` | raw source は存在するがページ数がゼロ、または pending raw が多い | `/rite:wiki:ingest` を手動実行。cleanup 経路での自動発火が機能しているか確認 |

閾値の調整は `rite-config.yml` の `wiki.growth_check` セクションで可能:

```yaml
wiki:
  growth_check:
    threshold_prs: 5          # growth stall の閾値（デフォルト: 5）
    pr_raw_threshold: 3       # PR↔raw 対応の閾値（デフォルト: 3）
```
