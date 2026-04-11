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

現行スキーマバージョン: **1.0.0**

スキーマ変更時は `schema_version` を semver (`MAJOR.MINOR.PATCH`) でインクリメントする。`/rite:pr:fix` Phase 1.2.0 の **Priority 0 および Priority 2** は読取時に `jq -r '.schema_version'` でバージョンを確認し、`"1.0.0"` または legacy `"1.0"` 以外の場合、遷移先が Priority に応じて異なる:

- **Priority 0 (`--review-file`)** 失敗時: 直接 **Priority 4 (対話式 fallback)** へ遷移 (ユーザーの明示意図を尊重、Priority 1-3 には fallthrough しない)
- **Priority 2 (ローカルファイル)** 失敗時: WARNING を出して **Priority 3 (PR コメント)** へ routing (古い timestamp ファイルには fallback しない)

詳細は fix.md Phase 1.2.0 Hybrid Review Source Resolution の Priority 0 / Priority 2 selection logic bash block を参照。

### Legacy `"1.0"` エイリアス

旧形式 `"1.0"` (semver `MAJOR.MINOR` のみ) は legacy エイリアスとして v2.0 まで受理される。`"1.0.0"` と完全に等価で semantic 差は無い。受理箇所は fix.md Phase 1.2.0 Priority 0 / Priority 2 / Priority 3 の 3 case 文で同期削除が必要。新規生成は禁止 (`/rite:pr:review` Phase 6.1.a は `"1.0.0"` のみ出力)。詳細経緯は CHANGELOG を参照。

## JSON Schema

```json
{
  "schema_version": "1.0.0",
  "pr_number": 123,
  "timestamp": "2026-04-11T12:34:56+09:00",
  "commit_sha": "abc1234",
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
| `schema_version` | string | ✅ | スキーマバージョン (semver `MAJOR.MINOR.PATCH`)。現行: `"1.0.0"` (legacy `"1.0"` も `/rite:pr:fix` で受理される) |
| `pr_number` | integer | ✅ | PR 番号 |
| `timestamp` | string | ✅ | レビュー実行時刻 (ISO 8601 `YYYY-MM-DDTHH:MM:SS+TZ`) |
| `commit_sha` | string | ✅ | レビュー対象の commit SHA (verification mode 用) |
| `overall_assessment` | string | ✅ | 総合評価 (`mergeable` / `fix-needed`) |
| `findings` | array | ✅ | 指摘事項の配列 (0 件でも空配列として存在) |

### `findings[]` 要素

| フィールド | 型 | 必須 | 説明 |
|-----------|-----|------|------|
| `id` | string | ✅ | 指摘 ID (`F-NN` 形式、**最小 2 桁ゼロパディングの可変長連番**。99 件以下: `F-01`〜`F-99` (常に 2 桁固定)。100 件以上の場合: `F-100`, `F-101`, ... のように 3 桁以上に成長する。zero-padding は 2 桁を最小として保持。レビュー内ユニーク。**設計指針**: 99 件超のレビューは finding 過多のため通常は分割レビュー推奨だが、schema は数値的上限を設けない。fix.md Phase 1.2 best-effort parser や severity_map は文字列キー比較なので桁数差は問題にならない) |
| `reviewer` | string | ✅ | レビュアー種別 (例: `code-quality-reviewer`, `security-reviewer`) |
| `category` | string | ✅ | カテゴリ (例: `code_quality`, `security`, `performance`, `error_handling`) |
| `severity` | string | ✅ | 重要度 (`CRITICAL` / `HIGH` / `MEDIUM` / `LOW`) |
| `file` | string | ✅ | 対象ファイルのリポジトリルート相対パス |
| `line` | integer | ✅ | 対象行番号 (行非依存指摘は `0`) |
| `description` | string | ✅ | 指摘内容 |
| `suggestion` | string | ✅ | 推奨対応 |
| `status` | string | ✅ | 対応状態。現行実装では `"open"` 固定で `/rite:pr:review` によってセットされる。**設計意図**: 将来の state machine 拡張 (`"fixed"` / `"replied"` / `"deferred"`) のために必須フィールドとして slot を予約している。現行の `/rite:pr:fix` 読取側はこの値を参照しないが、schema を後方互換に保つため必須化している (将来の遷移ロジック追加時に optional → required の breaking change を避ける) |

## PR コメント形式 (opt-in)

`--post-comment` または `rite-config.yml` の `pr_review.post_comment: true` 指定時、PR コメントには以下の形式で投稿される (外側 4-backtick fence で内側 3-backtick fence を透過的に含む):

````markdown
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
  "schema_version": "1.0.0",
  "pr_number": 123,
  "timestamp": "2026-04-11T12:34:56+09:00",
  "commit_sha": "abc1234",
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
````

- 既存の Markdown テーブル形式は保持 (後方互換、人間可読性)
- 末尾に `### 📄 Raw JSON` セクションを追加し、code fence で JSON を埋め込む
- `/rite:pr:fix` Phase 1.2.0 Priority 3 は code fence 内の JSON を `---` separator 以降の **最後** の `### 📄 Raw JSON` section に scope 限定して抽出する (findings suggestion 列内のサンプル JSON fence 誤捕捉と、本 SoT 文書自体が `### 📄 Raw JSON` literal を含むことによる誤検出の両方を防ぐ)。POSIX awk のみで動作する 1-pass + END 逆方向スキャン実装は fix.md Phase 1.2.0 の bash block を参照

## 読取優先順位 (pr:fix)

`/rite:pr:fix` は以下の優先順位でレビュー結果を取得する:

| Priority | ソース | 発動条件 | 失敗時の動作 |
|----------|-------|---------|-------------|
| 0 | **明示的ファイル指定** | `--review-file <path>` 指定時 | 指定パスを読取。**パス不在 / JSON 不正 / schema_version 不明** のいずれでも Priority 1-3 にフォールスルーせず直接 Priority 4 (対話式 fallback) へ遷移 (ユーザーの明示意図を尊重) |
| 1 | **会話コンテキスト** | 同一セッション内で `/rite:pr:review` が直前に実行されていれば、その結果を直接利用。**採用時は `[CONTEXT] REVIEW_SOURCE=conversation; pr_number={pr_number}` を stderr に emit する義務がある** (observability 義務、後段の provenance log に必要) | Claude が会話履歴に rite review 結果を見つけられなかった場合は次の Priority へ |
| 2 | **ローカルファイル** | `.rite/review-results/{pr_number}-*.json` の中で最新 `timestamp` のファイル (lexicographic sort) | schema_version 不明時は WARNING を出して **Priority 3 (PR コメント) に直接 routing** |
| 3 | **PR コメント (後方互換)** | PR コメントの `## 📜 rite レビュー結果` セクション (新形式: `### 📄 Raw JSON` 付き → awk で Raw JSON section-scoped 抽出。旧形式: Markdown テーブル → 既存パースロジック) | 次の Priority へ |
| 4 | **対話式 fallback** | 上記すべて欠落時 | `AskUserQuestion` で「レビュー実行 / ファイルパス指定 / 中止」を提示 (ファイルパス指定 retry 上限 3 回、state file による hard gate で強制終了) |

**Priority 1 emit 義務の理由**: Priority 1 は Claude の自然言語判断に依存する経路で bash の if-else では捕捉できない。後段の Phase 4.5.3 / 4.6 で `{review_source}` を log に出すため、conversation 経由で取り込んだ場合も他の Priority と同様に provenance を残す必要がある。emit 忘れは silent provenance loss となり、fix 後のトラブルシュートが困難になる。

**Priority 0 の non-trivial 挙動**: `--review-file` 失敗時は Priority 1-3 にフォールスルーせず直接 Priority 4 (対話式 fallback) に遷移する。これはユーザーが明示的に特定のファイルを指定した意図を尊重するため — silent に別ソースから読み込むと予期しない finding が fix 対象になるリスクがある。

**Priority 2 schema_version 不明時の挙動**: lexicographic sort で選ばれた最新ファイルが未知 schema の場合、古い timestamp ファイルには fallback せず、直接 Priority 3 (PR コメント) に routing する。これは「古い schema のファイルを選ぶより、最新の通信経路 (PR コメント) を信頼する」という設計判断。

## 明示的ファイル指定

`/rite:pr:fix --review-file <path>` で任意のファイルパスを直接指定可能。パスが存在しない / JSON パース失敗時はエラーを表示して対話式 fallback に誘導する (上記 Priority 0 行参照)。fix.md Phase 1.0.1 で `$ARGUMENTS` から `--review-file` トークンを pre-strip し、Phase 1.0 Detection rules は残りの引数のみを評価する。

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
- `plugins/rite/commands/pr/cleanup.md` Phase 2.5: 自動削除ロジック
- `rite-config.yml` `pr_review.post_comment`: グローバル設定
- `.gitignore`: `.rite/review-results/` 除外設定
