---
name: wiki
description: |
  rite Wiki layer — project-specific experiential knowledge persistence based on the
  LLM Wiki pattern (Karpathy). Use when the user asks to ingest review/fix/issue
  outcomes into Wiki pages, query accumulated experiential knowledge by keyword,
  or initialize the Wiki structure.
  Activates on "wiki", "ingest", "query", "経験則", "知識ページ", "Wiki 蓄積",
  "経験則を残す", "経験則を参照", "Wiki 検索", "wiki:init", "wiki:ingest",
  "wiki:query", "/rite:wiki:".
  Note: lint command is tracked in a follow-up Issue and not yet implemented.
---

# Wiki Skill

`rite-workflow` の経験則 Wiki 層に対する操作スキル。プロジェクト固有の経験則（実装パターン・レビュー指摘・修正パターン）を `.rite/wiki/` 配下に Markdown ページとして蓄積・参照・メンテナンスします。

## Auto-Activation Keywords

- wiki, Wiki, 経験則, 知識ページ
- ingest, 蓄積, 経験則を残す
- query, 経験則を参照, Wiki 検索
- `/rite:wiki:init`, `/rite:wiki:ingest`, `/rite:wiki:query`

> **Note**: `lint` キーワードは現時点で未実装です。`/rite:wiki:lint` は後続 Issue で実装予定のため、本 SKILL の auto-activation キーワードからは意図的に除外しています。

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
| `/rite:wiki:lint` | Wiki の品質チェック（矛盾・陳腐化・孤児） | 後続 Issue |

## 関連ファイル

- [Wiki Patterns](../../references/wiki-patterns.md) — ディレクトリ構造・ブランチ操作・テンプレート展開の共通パターン
- [page-template.md](../../templates/wiki/page-template.md) — Wiki ページの YAML frontmatter
- [SCHEMA テンプレート](../../templates/wiki/schema-template.md) — 蓄積規約の初期テンプレート

## 設定

`rite-config.yml` の `wiki` セクションで制御:

```yaml
wiki:
  enabled: false                       # opt-in (default false)
  branch_strategy: "separate_branch"   # separate_branch (推奨) or same_branch
  branch_name: "wiki"                  # separate_branch 時のブランチ名
  auto_ingest: true                    # 後続 Issue で実装予定
  auto_query: true                     # 後続 Issue で実装予定
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
