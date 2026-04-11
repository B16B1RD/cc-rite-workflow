# Review Result JSON Schema

`/rite:pr:review` が生成し、`/rite:pr:fix` が読取するレビュー結果 JSON のスキーマ定義。Issue #443 で導入された「ローカルファイル経由の pr:review → pr:fix 連携」の Single Source of Truth。

## 保存場所

レビュー結果は以下のパスにタイムスタンプ付きで保存される:

```
.rite/review-results/{pr_number}-{timestamp}.json
```

- `{pr_number}`: PR 番号（整数）
- `{timestamp}`: `YYYYMMDDHHMMSS` 形式の JST (例: `20260411123456`)
- 同一 PR の過去レビューは **best-effort で履歴保持** する。1 秒解像度のため、同一 PR に対し同一秒以内で 2 回 `/rite:pr:review` を実行すると file path が衝突し古い方は上書きされる。review.md Phase 6.1.a は collision 検出時に `~<4桁hex>` suffix (`~$(printf '%04x' "${RANDOM:-0}")` 相当) で衝突回避を試みるが、完全な一意性保証ではない点に注意 (M-2 tradeoff)。separator に `~` (0x7E) を使う理由は `.` (0x2E) より ASCII 大で `sort -r` 時に collision-resolved 版が非 collision 版より先頭に並ぶため — cycle 8 M-2 で `-` (0x2D) から変更済み (旧 `-` 版は `-` (0x2D) < `.` (0x2E) で `sort -r` 時に古い非 collision 版が先に選ばれる silent regression を持っていた)
- **並列実行は未サポート**: 同一 PR に対する `/rite:pr:review` の同時並列実行 (複数ターミナル / sprint team-execute / CI 並列 job 等) は未サポート。`mv` の atomicity と `[ -e ]` check の TOCTOU race window により、後勝ちでファイル上書きが発生する可能性がある。`mv -n` による no-clobber 保護は採用していない — POSIX `mv` の標準オプションは `-f`/`-i` のみで、`-n` は GNU coreutils / BSD 拡張であり、bash-compat-guard.md の portable 前提 (bash 3.2 + POSIX utilities) と矛盾するため (cycle 10 external spec 検証、[mv(1p) POSIX](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/mv.html) 参照)。並列実行する場合はユーザー自身が時系列をずらす責務を持つ
- `.rite/review-results/` は `.gitignore` で除外される

## Schema Version (Single Source of Truth)

<a id="schema-version-sot"></a>

現行スキーマバージョン: **1.0.0**

**受理される値**: `"1.0.0"` (canonical) および legacy エイリアス `"1.0"` (semver `MAJOR.MINOR` のみ)。両者は semantic 差なく完全等価で、legacy `"1.0"` は v2.0 まで受理される (新規生成は禁止: `/rite:pr:review` Phase 6.1.a は `"1.0.0"` のみ出力)。詳細経緯は CHANGELOG を参照。

**検証箇所の同期義務** (verified-review cycle 8 L-4 対応で本セクションを SoT 化、cycle 10 I-E 対応で read/write 非対称を明示):

**読取側 (legacy エイリアス `"1.0"` 受理義務、3 箇所で完全同期)**:

- `fix.md` Phase 1.2.0 Priority 0 (`--review-file` case 文)
- `fix.md` Phase 1.2.0 Priority 2 (local file case 文)
- `fix.md` Phase 1.2.0 Priority 3 (PR comment Raw JSON case 文)

上記 3 箇所の `case "$schema_version" in "1.0.0"|"1.0")` は常に同じ accept list を持つ。将来 `"1.1.0"` 追加 / legacy `"1.0"` 廃止時は 3 箇所を同時更新すること。

**書込側 (canonical 値のみ出力、同期義務なし)**:

- `review.md` Phase 6.1.a — canonical `"1.0.0"` のみを出力する。case 文は存在せず、post-condition jq validation は `schema_version | type == "string" and length > 0` の型チェックのみで値の同期対象外 (読取側 accept list と独立に進化してよい)

本セクションが Single Source of Truth であり、読取側 3 箇所の accept list を本ドキュメントと同一に保つことを drift-check が enforce する。

**失敗時の遷移** (Priority 別):

- **Priority 0 (`--review-file`)** 失敗時: 直接 **Priority 4 (対話式 fallback)** へ遷移 (ユーザーの明示意図を尊重、Priority 1-3 には fallthrough しない)
- **Priority 2 (ローカルファイル)** 失敗時: WARNING を出して **Priority 3 (PR コメント)** へ routing (古い timestamp ファイルには fallback しない)
- **Priority 3 (PR コメント Raw JSON)** 失敗時: legacy Markdown parser へ fallthrough (後方互換経路)

詳細は fix.md Phase 1.2.0 Hybrid Review Source Resolution の Priority 0 / Priority 2 / Priority 3 selection logic bash block を参照。

> **Note**: verified-review cycle 8 以前は legacy `"1.0"` に関する記述が本文中 4 箇所 (L22 / L31 / L64 / L141) に分散しており、真実源が不明瞭だった。本 SoT セクションに統合し、他の参照箇所は「詳細は [Schema Version](#schema-version-sot) セクション参照」にリンクする。

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
      "id": "F-001",
      "reviewer": "code-quality-reviewer",
      "category": "code_quality",
      "severity": "HIGH",
      "file": "path/to/file.ts",
      "line": 42,
      "description": "エラーハンドリングが不足",
      "suggestion": "try-catch を追加",
      "status": "open"
    },
    {
      "id": "F-002",
      "reviewer": "security-reviewer",
      "category": "security",
      "severity": "MEDIUM",
      "file": "path/to/config.ts",
      "line": null,
      "description": "ファイル全体への指摘 (行非依存)",
      "suggestion": "設定ファイルヘッダにコンテキスト説明を追加",
      "status": "open"
    }
  ]
}
```

## フィールド定義

### トップレベル

| フィールド | 型 | 必須 | 説明 |
|-----------|-----|------|------|
| `schema_version` | string | ✅ | スキーマバージョン (semver `MAJOR.MINOR.PATCH`)。詳細は [Schema Version](#schema-version-sot) セクション参照 (受理値と legacy エイリアスの SoT) |
| `pr_number` | integer | ✅ | PR 番号 (>= 1) |
| `timestamp` | string | ✅ | レビュー実行時刻 (ISO 8601 `YYYY-MM-DDTHH:MM:SS+TZ`) |
| `commit_sha` | string | ✅ | レビュー対象の commit SHA (verification mode 用) |
| `overall_assessment` | **enum** (string) | ✅ | 総合評価。**受理値**: `"mergeable"` / `"fix-needed"` の 2 値のみ。未知値は read 側で WARNING emit + `[CONTEXT] REVIEW_SOURCE_ENUM_UNKNOWN=1; reason=overall_assessment_unknown_value` を stderr に出力し、legacy parser 経路に fallthrough する |
| `findings` | array | ✅ | 指摘事項の配列 (0 件でも空配列として存在) |

### `findings[]` 要素

| フィールド | 型 | 必須 | 説明 |
|-----------|-----|------|------|
| `id` | string | ✅ | 指摘 ID (`F-NNN` 形式、**3 桁固定ゼロパディング**、正規表現 `^F-[0-9]{3,}$`)。例: `F-001`, `F-042`, `F-999`, `F-1000`。レビュー内ユニーク。**設計理由**: cycle 10 S-8 対応で旧「最小 2 桁可変長」から 3 桁固定に変更。lexicographic sort で `F-100 < F-11 < F-99` となる natural sort 問題を予防 (99 件以下でも桁数固定により sort が時系列と一致)。**後方互換**: 読取側 (`fix.md`) は正規表現 `^F-[0-9]{2,}$` で 2 桁以上を許容し続けるため、既存の `F-01`〜`F-99` を持つ JSON は引き続き読取可能。新規生成 (write 側 review.md Phase 6.1.a) のみ 3 桁固定に切り替える |
| `reviewer` | string | ✅ | レビュアー種別 (例: `code-quality-reviewer`, `security-reviewer`)。**参照整合性**: 値は `plugins/rite/skills/reviewers/*/SKILL.md` の basename と一致する。新 reviewer を追加する際は本ドキュメントに追記すること (drift-check 対象) |
| `category` | string | ✅ | カテゴリ (例: `code_quality`, `security`, `performance`, `error_handling`) |
| `severity` | **enum** (string) | ✅ | 重要度。**受理値**: `"CRITICAL"` / `"HIGH"` / `"MEDIUM"` / `"LOW"` の 4 値のみ。未知値は read 側で WARNING emit + `[CONTEXT] REVIEW_SOURCE_ENUM_UNKNOWN=1; reason=severity_unknown_value; value=<val>` を stderr 出力し、該当 finding を `MEDIUM` にフォールバック (silent skip は禁止)。Phase 2.1 best-effort parser の別名マッピング (`Critical`/`Important`/絵文字等) は read 側で正規化してから本 enum に落とす |
| `file` | string | ✅ | 対象ファイルのリポジトリルート相対パス (絶対パス禁止、`..` による親ディレクトリ参照禁止) |
| `line` | integer \| null | ✅ | 対象行番号 (正の整数 >= 1)、または `null` (行非依存指摘の sentinel)。cycle 10 S-4 対応で旧「`0` を行非依存 sentinel として扱う」設計から `null` 許容に変更。severity_map 構築時は `line == null` を `"anchor"` key に正規化して同一ファイル複数指摘の key 衝突を防ぐ (fix.md Phase 1.2.0 severity_map 構築参照)。**後方互換**: 読取側は `line: 0` を引き続き legacy sentinel として受理し、`null` と同じ扱いにする |
| `description` | string | ✅ | 指摘内容 |
| `suggestion` | string | ✅ | 推奨対応 |
| `status` | **enum** (string) | ✅ | 対応状態。**受理値**: `"open"` / `"fixed"` / `"replied"` / `"deferred"` の 4 値。現行実装では `/rite:pr:review` Phase 6.1.a は常に `"open"` を出力する (将来の state machine 拡張で `/rite:pr:fix` 完了時に `"fixed"` 等を書き戻す slot を予約)。未知値は read 側で WARNING emit + `[CONTEXT] REVIEW_SOURCE_ENUM_UNKNOWN=1; reason=status_unknown_value; value=<val>` を stderr 出力する |

### Cross-field invariants (型レベルで表現しきれない制約)

以下の制約は単一フィールドの型では表現できないため、write 側 (`review.md` Phase 6.1.a) が生成時に守る義務があり、read 側 (`fix.md` Phase 1.2.0) は post-condition jq として検証する:

1. **ファイル名 ↔ JSON `pr_number` 同期**: `.rite/review-results/{pr_number}-{timestamp}.json` の `{pr_number}` prefix と JSON 内 `.pr_number` の値は必ず一致する。不一致時は read 側で WARNING + `[CONTEXT] REVIEW_SOURCE_CROSS_FIELD_INVARIANT_VIOLATED=1; reason=pr_number_mismatch` を emit して legacy parser fallthrough。手動でファイルを rename した場合のみ発火しうる。
2. **`overall_assessment == "mergeable"` ∧ CRITICAL/HIGH open finding 存在禁止**: `overall_assessment` が `"mergeable"` のとき、`findings[]` に `severity ∈ {"CRITICAL", "HIGH"}` かつ `status == "open"` の要素が含まれてはならない。違反時は read 側で WARNING + `[CONTEXT] REVIEW_SOURCE_CROSS_FIELD_INVARIANT_VIOLATED=1; reason=mergeable_has_open_blockers` を emit して legacy parser fallthrough (手書き JSON で fix ループを silent に 0 件脱出させる bypass を防ぐ)。
3. **ファイル名 timestamp ↔ JSON `timestamp` 同期**: `{timestamp}` prefix (JST `YYYYMMDDHHMMSS`) と JSON 内 `.timestamp` (ISO 8601) は同一瞬間を指す。ただし本不変条件は read 側で検証せず (ファイル rename 時にしか破綻しえないため)、write 側が Phase 6.1.a で一度に生成することで担保する。

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
| 2 | **ローカルファイル** | `.rite/review-results/{pr_number}-*.json` の中で最新 `timestamp` のファイル (lexicographic sort) | **3 種の失敗モードいずれも** WARNING を出して **Priority 3 (PR コメント) に直接 routing** する: (a) `local_file_json_parse_failure` (`jq empty` で JSON syntax invalid)、(b) `local_file_schema_required_fields_missing` (parse 可能だが `schema_version` 非空文字列 / `pr_number` 数値型 / `findings[]` 配列型のいずれかが欠落)、(c) `local_file_schema_version_unknown` (schema_version 未知)。古い timestamp ファイルには fallback しない |
| 3 | **PR コメント (後方互換)** | PR コメントの `## 📜 rite レビュー結果` セクション (新形式: `### 📄 Raw JSON` 付き → awk で Raw JSON section-scoped 抽出。旧形式: Markdown テーブル → 既存パースロジック) | 次の Priority へ |
| 4 | **対話式 fallback** | 上記すべて欠落時 | `AskUserQuestion` で「レビュー実行 / ファイルパス指定 / 中止」を提示 (ファイルパス指定 retry 上限 3 回、state file による hard gate で強制終了) |

**Priority 1 emit 義務の理由**: Priority 1 は Claude の自然言語判断に依存する経路で bash の if-else では捕捉できない。後段の Phase 4.5.3 / 4.6 で `{review_source}` を log に出すため、conversation 経由で取り込んだ場合も他の Priority と同様に provenance を残す必要がある。emit 忘れは silent provenance loss となり、fix 後のトラブルシュートが困難になる。

**Priority 0 の non-trivial 挙動**: `--review-file` 失敗時は Priority 1-3 にフォールスルーせず直接 Priority 4 (対話式 fallback) に遷移する。これはユーザーが明示的に特定のファイルを指定した意図を尊重するため — silent に別ソースから読み込むと予期しない finding が fix 対象になるリスクがある。

**Priority 2 schema_version 不明時の挙動**: lexicographic sort で選ばれた最新ファイルが未知 schema の場合、古い timestamp ファイルには fallback せず、直接 Priority 3 (PR コメント) に routing する。これは「古い schema のファイルを選ぶより、最新の通信経路 (PR コメント) を信頼する」という設計判断。

## 明示的ファイル指定

`/rite:pr:fix --review-file <path>` で任意のファイルパスを直接指定可能。パスが存在しない / JSON パース失敗時はエラーを表示して対話式 fallback に誘導する (上記 Priority 0 行参照)。fix.md Phase 1.0.1 で `$ARGUMENTS` から `--review-file` トークンを pre-strip し、Phase 1.0 Detection rules は残りの引数のみを評価する。

## エラーハンドリング

> **Priority 別の routing ルールは上記「読取優先順位 (pr:fix)」表が Single Source of Truth**。本セクションは write 側 (`/rite:pr:review`) と引数整合性のエラーのみを扱う。read 側 (`/rite:pr:fix`) の失敗経路は Priority 別に大きく挙動が異なるため、本表では要約せず Priority 表と直下の「Priority 0 の non-trivial 挙動」「Priority 2 schema_version 不明時の挙動」の注記を参照のこと。特に `--review-file` (Priority 0) の失敗は Priority 1-3 にフォールスルーせず直接 Priority 4 に遷移する点、およびローカルファイル (Priority 2) の parse/schema 失敗は古い timestamp ファイルではなく Priority 3 に直接 routing する点は、旧版の「次の優先順位のソースを試行」要約と異なる。

### Write 側 (`/rite:pr:review`) のエラー

| 条件 | 挙動 |
|------|------|
| `.rite/review-results/` ディレクトリ作成不可 | 警告表示し、会話コンテキストのみで続行 (`/rite:pr:review` 全体は失敗扱いにしない — D-04 non-blocking contract) |
| JSON 書き込み失敗 | 警告表示し、PR コメント投稿または会話コンテキスト経由で続行 (D-04 non-blocking contract、ただし `post_comment=false` ∧ save 失敗時は H-1 で WARNING に昇格し復旧手順を提示) |
| 同一秒連続実行での file path 衝突 | collision 検出時に `~<4桁hex>` suffix (`~$(printf '%04x' "${RANDOM:-0}")` 相当) で回避を試みる (best-effort、完全保証ではない — M-2 tradeoff)。separator は `~` (0x7E) を使用。`.` (0x2E) より ASCII 大で `sort -r` 時に collision-resolved 版が非 collision 版より先頭に並ぶ (cycle 8 M-2 で `-` から変更済み) |

### 引数整合性のエラー

| 条件 | 挙動 |
|------|------|
| `--post-comment` と `--no-post-comment` 同時指定 | エラーメッセージを表示して終了 (レビューもコメント投稿も実行しない — AC-8) |

## クリーンアップ

`/rite:pr:cleanup` は PR マージ後のブランチ削除時に、該当 PR 番号の以下 2 種類のローカル artifact を削除する (verified-review cycle 9 I-9 対応で AC-7 スコープに state file を明示追加):

1. **レビュー結果ファイル**: `.rite/review-results/{pr_number}-*.json` (Issue #443 で導入された opt-in PR コメント記録機能の補完)
2. **fix retry state file**: `.rite/state/fix-fallback-retry-{pr_number}.count` (Issue #450 で導入された Interactive Fallback retry hard gate の state file)

wildcard は PR 番号 prefix 固定とし、他 PR のファイルを誤って削除しないよう保証する。state file は specific path (`{pr_number}.count` 完全一致) で削除する。

## 関連ファイル

- `plugins/rite/commands/pr/review.md` Phase 6.1: JSON 生成と保存ロジック (AC-1 default stop / AC-2 opt-in posting / D-04 non-blocking contract)
- `plugins/rite/commands/pr/fix.md` Phase 1.2.0: ハイブリッド読取ロジック (AC-3/4 会話/ファイル優先 / AC-5 後方互換 / AC-6 対話式 fallback)
- `plugins/rite/commands/pr/cleanup.md` Phase 2.5: 自動削除ロジック (AC-7: review result files + fix retry state file の両方を削除)
- `rite-config.yml` `pr_review.post_comment`: グローバル設定
- `.gitignore`: `.rite/review-results/` 除外設定
