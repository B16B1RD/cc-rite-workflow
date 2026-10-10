---
type: Reference
---

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
type: patterns | heuristics | anti-patterns
title: "ページタイトル"
domain: patterns | heuristics | anti-patterns
description: "1-2 文の要約"
created: "YYYY-MM-DDTHH:MM:SS+09:00"
generated: { by: "rite-wiki-ingest/<model-id>", at: "YYYY-MM-DDTHH:MM:SS+09:00" }
sources:
  - type: review | retrospective | fix | manual
    resource: "raw/{type}/{filename}"
tags: []
confidence: high | medium | low
---
```

| フィールド | 必須 | 説明 |
|-----------|------|------|
| `type` | yes | **OKF v0.2 が要求する唯一のフィールド**（本表の他の `yes` 項目は rite が運用上必須とする拡張で、OKF 仕様上の必須ではない）。concept の種別。rite では `domain` と同値（例 domain=heuristics → type=heuristics）。OKF consumer が type ベースで routing/filtering できるようにするための標準キー |
| `title` | yes | ページタイトル（検索・インデックスに使用） |
| `domain` | yes | 蓄積ドメイン（上記3種）。rite 拡張キーとして温存（query/lint は引き続き domain を参照） |
| `description` | no | 1-2 文の要約（OKF 推奨。`{summary}` と同源）。page frontmatter に保持され、ingest が index.md `## ページ一覧` テーブルのサマリー列にも反映する。`/rite:wiki-query` の Pass 1 はテーブル行・箇条書き行の両形式からサマリーを読み、キーワード照合に使う |
| `created` | yes | 初出日時（ISO 8601）。rite 独自拡張。`generated.at` とは役割が異なる |
| `generated` | yes | OKF trust。`by` は `rite-wiki-ingest/<model-id>`、`at` は最終内容変更時刻 |
| `verified` | no | 補強サイクルでのみ `{by, at}` を追記。空配列は書かない。改訂・混在サイクルでは追記しない |
| `status` | no | `deprecated` のときのみ明示（ingest は、同じ PR の後の raw がページの結論全体を否定したときだけ書く。新規/追記/統合では書かない） |
| `stale_after` | no | 本文に絶対日付拘束がある経験則にのみ `YYYY-MM-DD` |
| `sources` | yes | 元データへの参照（空配列可）。各エントリの `resource` は raw ファイルパス |
| `tags` | no | 自由タグ（検索補助） |
| `confidence` | no | 知見の確信度（デフォルト: medium） |

> **`type` と `domain` の関係**: OKF v0.2 は `type` のみを必須とする。rite は既存の `domain` を機械可読キー（query スコアリング・lint カテゴリ集計）として温存しつつ、OKF 準拠のため `type` を同値で併記する。両者の統合（redundancy 解消）は別 Issue のスコープで、本規約では両併存を正とする。

### 知見の出力先

新規 Wiki ページと既存ページへの追記はプロジェクト固有の domain 知見に限る。rite workflow の挙動・スキル記述法は機械検出可否や既存ページの有無によらず raw の昇格候補へ保存し、新規 `promote: rite-plugin` ページを作らない。既存の `promote` / `reference` 付き発見ポインタは保持する。

混在 raw は知見ごとに候補と domain ページへ分ける。raw 本文の `Promotion candidates` に要約・原文本文の行範囲・条件・消費先を記録し、`ingest_status` / `skip_reason` と log の作業対応を使う。候補と domain のページ・index・log の保存確認後だけ `ingested: true` にする。この値は抽出完了で、昇格完了ではない。

消化は保守リポジトリで `/rite:batch-run --promotions`。AI が抽出済み raw と旧 detector-candidate 理由も列挙し、同責務へ集約して既存の起票・実装・レビューへ接続する。完了は同じマージ済み revision の試験中に caller と consumer の実行・読取および呼出し関係を観測し、対応試験成功を照合した場合のみ。コマンド文字列の表示や存在確認は利用証拠にならず、利用を観測できない場合は未解決とする。未解決理由と候補の出典は保持する。配布先は保存・報告までで、自動外部送信と配布物編集をしない。

### 蓄積トリガー

| トリガー | 抽出元 | Raw Source 保存先 |
|---------|--------|-----------------|
| PR レビュー完了 | `/rite:pr-review` 結果 | `raw/reviews/` |
| Issue クローズ | `/rite:issue-close` 実行時 | `raw/retrospectives/` |
| Fix 完了 | `/rite:fix` 結果 | `raw/fixes/` |
| 手動 | `/rite:wiki-ingest` コマンド | `raw/` (指定ディレクトリ) |

### 品質基準

- **具体性**: 抽象的な一般論ではなく、このプロジェクト固有の知見を蓄積する
- **根拠付き**: 必ず Raw Source（レビュー結果、Issue 振り返り等）への参照を持つ
- **更新性**: 矛盾する新しい知見が得られたらページを更新する（append-only ではない）
- **重複排除**: 同じ知見は1ページに統合する（Lint サイクルで検出）
- **番号ではなく Why 散文**: Issue/PR/commit の番号参照を Wiki に書かない。例外はない。本文（概要・詳細）だけでなく `## ソース` 節の bullet の表示テキスト、`index.md` のエントリサマリー、`log.md` のエントリも同じ規則で、番号を持てるのは frontmatter の `sources[].resource` と bullet のリンク先パス（どちらも Raw Source のファイルパス）だけである。Wiki は番号の受け皿ではなく、経験則そのものを**自己完結した Why 散文**で残す場である（Comment Best Practices SoT の[適用スコープ](../../skills/rite-workflow/references/comment-best-practices.md#適用スコープ)が Wiki ページを含む）。知見の出所はそのファイルパスでのみ辿れるようにし、読み手が読む面には番号を持ち込まない。番号で「ここで決まった」と示すのではなく「なぜそうするのか」を散文で書く。ソース bullet の表示テキストは説明だけを書き、説明が無ければ種別語（「レビュー結果」「fix 結果」「close retrospective」）にする — 日付はリンク先パスにあるので重ねない。
