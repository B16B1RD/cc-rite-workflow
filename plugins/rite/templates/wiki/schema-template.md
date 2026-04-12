# Wiki Schema -- 蓄積規約

このファイルは Wiki に何を蓄積し、どのように構造化するかの規約を定義します。
人間と LLM が共同管理し、プロジェクトの成長に合わせて更新してください。

## 蓄積規約

### 対象ドメイン

| ドメイン | 説明 | 蓄積例 |
|---------|------|--------|
| `patterns` | 繰り返し発生するコードパターン | 頻出エラーハンドリング、共通の実装パターン |
| `heuristics` | 経験から学んだ判断基準 | 「このプロジェクトでは X よりも Y が適切」 |
| `anti-patterns` | 避けるべきパターン | 過去の失敗から学んだ禁止事項 |

### ページ構造

各 Wiki ページは以下の構造に従います:

1. **YAML frontmatter** (必須): メタデータ
2. **概要**: 1-2 文での要約
3. **詳細**: 具体的な説明、コード例、根拠
4. **関連ページ**: 他の Wiki ページへのリンク
5. **ソース**: この知識の元となった Raw Source への参照

### frontmatter 規約

```yaml
---
title: "ページタイトル"
domain: patterns | heuristics | anti-patterns
created: "YYYY-MM-DDTHH:MM:SS+09:00"
updated: "YYYY-MM-DDTHH:MM:SS+09:00"
sources:
  - type: review | retrospective | fix | manual
    ref: "raw/{type}/{filename}"
tags: []
confidence: high | medium | low
---
```

| フィールド | 必須 | 説明 |
|-----------|------|------|
| `title` | yes | ページタイトル（検索・インデックスに使用） |
| `domain` | yes | 蓄積ドメイン（上記3種） |
| `created` | yes | 作成日時（ISO 8601） |
| `updated` | yes | 最終更新日時（ISO 8601） |
| `sources` | yes | 元データへの参照（空配列可） |
| `tags` | no | 自由タグ（検索補助） |
| `confidence` | no | 知見の確信度（デフォルト: medium） |

### 蓄積トリガー

| トリガー | 抽出元 | Raw Source 保存先 |
|---------|--------|-----------------|
| PR レビュー完了 | `/rite:pr:review` 結果 | `raw/reviews/` |
| Issue クローズ | `/rite:issue:close` 実行時 | `raw/retrospectives/` |
| Fix 完了 | `/rite:pr:fix` 結果 | `raw/fixes/` |
| 手動 | `/rite:wiki:ingest` コマンド | `raw/` (指定ディレクトリ) |

### 品質基準

- **具体性**: 抽象的な一般論ではなく、このプロジェクト固有の知見を蓄積する
- **根拠付き**: 必ず Raw Source（レビュー結果、Issue 振り返り等）への参照を持つ
- **更新性**: 矛盾する新しい知見が得られたらページを更新する（append-only ではない）
- **重複排除**: 同じ知見は1ページに統合する（Lint サイクルで検出）
