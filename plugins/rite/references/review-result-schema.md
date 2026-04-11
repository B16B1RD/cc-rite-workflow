# Review Result JSON Schema

`/rite:pr:review` が生成し、`/rite:pr:fix` が読取するレビュー結果 JSON のスキーマ定義。Issue #443 で導入された「ローカルファイル経由の pr:review → pr:fix 連携」の Single Source of Truth。

## 保存場所

レビュー結果は以下のパスにタイムスタンプ付きで保存される:

```
.rite/review-results/{pr_number}-{timestamp}.json
```

- `{pr_number}`: PR 番号（整数）
- `{timestamp}`: `YYYYMMDDHHMMSS` 形式の JST (例: `20260411123456`)
- 同一 PR の過去レビューは上書きせず履歴として保持する
- `.rite/review-results/` は `.gitignore` で除外される

## Schema Version

現行スキーマバージョン: **1.0**

スキーマ変更時は `schema_version` を semver でインクリメントする。`/rite:pr:fix` は読取時にバージョンを確認し、未知のバージョンの場合は警告を出してスキップする。

## JSON Schema

```json
{
  "schema_version": "1.0",
  "pr_number": 123,
  "timestamp": "2026-04-11T12:34:56+09:00",
  "commit_sha": "abc1234567890",
  "overall_assessment": "fix-needed",
  "findings": [
    {
      "id": "F-01",
      "reviewer": "code-quality-reviewer",
      "category": "code_quality",
      "severity": "HIGH",
      "file": "path/to/file.ts",
      "line": 42,
      "description": "エラーハンドリングが不足",
      "suggestion": "try-catch を追加",
      "status": "open"
    }
  ]
}
```

## フィールド定義

### トップレベル

| フィールド | 型 | 必須 | 説明 |
|-----------|-----|------|------|
| `schema_version` | string | ✅ | スキーマバージョン (semver)。現行: `"1.0"` |
| `pr_number` | integer | ✅ | PR 番号 |
| `timestamp` | string | ✅ | レビュー実行時刻 (ISO 8601 `YYYY-MM-DDTHH:MM:SS+TZ`) |
| `commit_sha` | string | ✅ | レビュー対象の commit SHA (verification mode 用) |
| `overall_assessment` | string | ✅ | 総合評価 (`mergeable` / `fix-needed`) |
| `findings` | array | ✅ | 指摘事項の配列 (0 件でも空配列として存在) |

### `findings[]` 要素

| フィールド | 型 | 必須 | 説明 |
|-----------|-----|------|------|
| `id` | string | ✅ | 指摘 ID (`F-01` 形式、レビュー内ユニーク) |
| `reviewer` | string | ✅ | レビュアー種別 (例: `code-quality-reviewer`, `security-reviewer`) |
| `category` | string | ✅ | カテゴリ (例: `code_quality`, `security`, `performance`, `error_handling`) |
| `severity` | string | ✅ | 重要度 (`CRITICAL` / `HIGH` / `MEDIUM` / `LOW`) |
| `file` | string | ✅ | 対象ファイルのリポジトリルート相対パス |
| `line` | integer | ✅ | 対象行番号 (行非依存指摘は `0`) |
| `description` | string | ✅ | 指摘内容 |
| `suggestion` | string | ✅ | 推奨対応 |
| `status` | string | ✅ | 対応状態 (`open` / `fixed` / `replied` / `deferred`) |

## PR コメント形式 (opt-in)

`--post-comment` または `rite-config.yml` の `pr_review.post_comment: true` 指定時、PR コメントには以下の形式で投稿される:

```markdown
## 📜 rite レビュー結果

### 総合評価
- **推奨**: 修正必要

### 全指摘事項

#### code-quality-reviewer
- **評価**: 要修正

| 重要度 | ファイル:行 | 内容 | 推奨対応 |
|--------|------------|------|----------|
| HIGH | path/to/file.ts:42 | エラーハンドリングが不足 | try-catch を追加 |

---

### 📄 Raw JSON

```json
{
  "schema_version": "1.0",
  "pr_number": 123,
  ...
}
```
```

- 既存の Markdown テーブル形式は保持 (後方互換、人間可読性)
- 末尾に `### 📄 Raw JSON` セクションを追加し、code fence で JSON を埋め込む
- `/rite:pr:fix` は code fence 内の JSON を正規表現 `` ```json\n([\s\S]+?)\n``` `` で抽出可能

## 読取優先順位 (pr:fix)

`/rite:pr:fix` は以下の優先順位でレビュー結果を取得する:

1. **会話コンテキスト**: 同一セッション内で `/rite:pr:review` が直前に実行されていれば、その結果を直接利用
2. **ローカルファイル**: `.rite/review-results/{pr_number}-*.json` の中で最新 `timestamp` のファイル
3. **PR コメント (後方互換)**: PR コメントの `## 📜 rite レビュー結果` セクション
   - 新形式 (`### 📄 Raw JSON` 付き): code fence から JSON を抽出
   - 旧形式 (Markdown テーブルのみ): 既存のテーブルパースロジックで `severity_map` を構築
4. **いずれも欠落時**: 対話式 fallback (`AskUserQuestion`) で「レビュー実行 / ファイルパス指定 / 中止」を提示

## 明示的ファイル指定

`/rite:pr:fix --review-file <path>` で任意のファイルパスを直接指定可能。パスが存在しない / JSON パース失敗時はエラーを表示して対話式 fallback に誘導する。

## エラーハンドリング

| 条件 | 挙動 |
|------|------|
| `.rite/review-results/` ディレクトリ作成不可 | 警告表示し、会話コンテキストのみで続行 (`/rite:pr:review` 全体は失敗扱いにしない) |
| JSON 書き込み失敗 | 警告表示し、PR コメント投稿または会話コンテキスト経由で続行 |
| `/rite:pr:fix` 読取時の JSON パース失敗 | 該当ソースをスキップし、次の優先順位のソースを試行 |
| 複数の timestamp ファイル存在 | 最新 timestamp のファイルのみ読取、古いファイルは無視 |
| `--post-comment` と `--no-post-comment` 同時指定 | エラーメッセージを表示して終了 (レビューもコメント投稿も実行しない) |

## クリーンアップ

`/rite:pr:cleanup` は PR マージ後のブランチ削除時に、該当 PR 番号の `.rite/review-results/{pr_number}-*.json` を削除する。wildcard は PR 番号 prefix 固定とし、他 PR のファイルを誤って削除しないよう保証する。

## 関連ファイル

- `plugins/rite/commands/pr/review.md` Phase 6.1: JSON 生成と保存ロジック
- `plugins/rite/commands/pr/fix.md` Phase 1.2: ハイブリッド読取ロジック
- `plugins/rite/commands/pr/cleanup.md` Phase 2: 自動削除ロジック
- `rite-config.yml` `pr_review.post_comment`: グローバル設定
- `.gitignore`: `.rite/review-results/` 除外設定
