# Review Result JSON Schema

`/rite:pr:review` が生成し、`/rite:pr:fix` が読取するレビュー結果 JSON のスキーマ定義。Issue #443 で導入された「ローカルファイル経由の pr:review → pr:fix 連携」の Single Source of Truth。

## 保存場所

レビュー結果は以下のパスにタイムスタンプ付きで保存される:

```
.rite/review-results/{pr_number}-{timestamp}.json
```

- `{pr_number}`: PR 番号（整数）
- `{timestamp}`: `YYYYMMDDHHMMSS` 形式の JST (例: `20260411123456`)
- 同一 PR の過去レビューは **best-effort で履歴保持** する。1 秒解像度のため、同一 PR に対し同一秒以内に 2 回 `/rite:pr:review` を実行すると file path が衝突する。review.md Phase 6.1.a は collision 検出時に `~<4桁hex>` suffix (`~$(printf '%04x' "${RANDOM:-0}")` 相当) で衝突回避を試みるが、完全な一意性保証ではない (best-effort tradeoff)。separator には `~` (0x7E) を使用する。ファイル名 `{ts}~{hex}.json` と `{ts}.json` の分岐点で `.` (0x2E) < `~` (0x7E) となるため、collision-resolved 版が lexicographic 大となり `sort -r` で先頭に並ぶ
- **並列実行は未サポート**: 同一 PR に対する `/rite:pr:review` の同時並列実行 (複数ターミナル / sprint team-execute / CI 並列 job 等) は未サポート。`mv` の atomicity と `[ -e ]` check の TOCTOU race window により、後勝ちでファイル上書きが発生する可能性がある。POSIX `mv` の標準オプションは `-f`/`-i` のみで、`-n` は POSIX 非標準 (GNU coreutils / BSD 拡張) のため、POSIX 準拠の観点から採用しない ([mv(1p) POSIX](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/mv.html) 参照)。並列実行する場合はユーザー自身が時系列をずらす責務を持つ (verified-review cycle 12 I-2 対応で旧 rationale 「bash 3.2 + POSIX utilities 前提と矛盾」を削除。本 plugin は [bash-compat-guard.md](./bash-compat-guard.md) で `mapfile` builtin 必須 = bash 4.0+ 前提であり、bash 3.2 portable 前提は成立しないため)
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

本セクションが Single Source of Truth であり、読取側 3 箇所の accept list を本ドキュメントと同一に保つ義務がある。現時点では `plugins/rite/hooks/scripts/distributed-fix-drift-check.sh` / `doc-heavy-patterns-drift-check.sh` は schema_version / accept list の drift を自動検出しない (enforcement 未実装)。将来の drift-check 拡張で schema_version enum を自動検証する計画。それまでは本ドキュメントを変更した際に手動で 3 箇所を同期させること。

**失敗時の遷移** (Priority 別):

- **Priority 0 (`--review-file`)** 失敗時: 直接 **Priority 4 (対話式 fallback)** へ遷移 (ユーザーの明示意図を尊重、Priority 1-3 には fallthrough しない)
- **Priority 2 (ローカルファイル)** 失敗時: WARNING を出して **Priority 3 (PR コメント)** へ routing (古い timestamp ファイルには fallback しない)
- **Priority 3 (PR コメント Raw JSON)** 失敗時: legacy Markdown parser へ fallthrough (後方互換経路)

詳細は fix.md Phase 1.2.0 Hybrid Review Source Resolution の Priority 0 / Priority 2 / Priority 3 selection logic bash block を参照。

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
    },
    {
      "id": "F-02",
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
| `commit_sha` | string | ✅ | レビュー対象の commit SHA。用途: (a) verification mode 用の diff 起点、(b) Priority 0/2/3 の stale file detection 用の HEAD 比較キー (後述の「読取優先順位 (pr:fix)」表 failure mode 列 `*_commit_sha_mismatch` を参照)。read 側 (`fix.md` Phase 1.2.0) は各 Priority success 経路で `json_commit_sha` vs 現 HEAD を比較し、mismatch 時は WARNING + `[CONTEXT] REVIEW_SOURCE_STALE=1; reason=*_commit_sha_mismatch` emit + 次 Priority への routing を実行する (stale file protection) |
| `overall_assessment` | **enum** (string) | ✅ | 総合評価。**受理値**: `"mergeable"` / `"fix-needed"` の 2 値のみ。未知値は read 側で WARNING emit + `[CONTEXT] REVIEW_SOURCE_ENUM_UNKNOWN=1; reason=overall_assessment_unknown_value` を stderr に出力し、Priority に応じた fallback/routing を実行する (P0: fallback、P2: Priority 3 routing、P3: legacy parser fallthrough。詳細は fix.md failure reasons table `overall_assessment_unknown_value` 参照) |
| `findings` | array | ✅ | 指摘事項の配列 (0 件でも空配列として存在) |

### `findings[]` 要素

| フィールド | 型 | 必須 | 説明 |
|-----------|-----|------|------|
| `id` | string | ✅ | 指摘 ID (`F-NN` 形式、最小 2 桁ゼロパディング可変長連番、正規表現 `^F-[0-9]{2,}$`)。例: `F-01`, `F-42`, `F-99`, `F-100`, `F-999`。レビュー内ユニーク。99 件以下は 2 桁、100 件以上は 3 桁以上に自然成長する。write 側 (`review.md` Phase 6.1.a) の machine-enforced jq validation と read 側 (`fix.md`) の正規表現は同一パターンで検証される |
| `reviewer` | string | ✅ | レビュアー種別 (例: `code-quality-reviewer`, `security-reviewer`, `tech-writer-reviewer`)。**参照整合性**: 値は `plugins/rite/agents/*-reviewer.md` の basename (拡張子を除く) と一致する。`plugins/rite/skills/reviewers/*.md` はカテゴリ説明 Markdown であり reviewer 識別子としては使わない (接尾辞 `-reviewer` なし)。新 reviewer を追加する際は agents/ 側のファイル追加と合わせて本ドキュメントにも追記すること (現時点では drift-check による自動検証は未実装、手動同期)。 |
| `category` | string | ✅ | カテゴリ (例: `code_quality`, `security`, `performance`, `error_handling`) |
| `severity` | **enum** (string) | ✅ | 重要度。**受理値**: `"CRITICAL"` / `"HIGH"` / `"MEDIUM"` / `"LOW-MEDIUM"` / `"LOW"` の 5 値のみ (LOW-MEDIUM は `severity-levels.md` Severity Levels 表で正式定義された first-class severity で、`COMMENT_QUALITY` 軸の独自ジャーゴン濫用 等の bounded blast radius 違反に使う)。未知値は read 側で WARNING emit + `[CONTEXT] REVIEW_SOURCE_ENUM_UNKNOWN=1; reason=severity_unknown_value; value=<val>` を stderr 出力し、該当 finding を `MEDIUM` にフォールバック (silent skip は禁止)。外部ツール出力の別名は下記「severity 別名マッピング表」に従って read 側で正規化してから本 enum に落とす |
| `file` | string | ✅ | 対象ファイルのリポジトリルート相対パス (絶対パス禁止、`..` による親ディレクトリ参照禁止) |
| `line` | integer \| null | ✅ | 対象行番号 (正の整数 >= 1)、または `null` (行非依存指摘の sentinel)。負数は無効 (read 側での挙動は未定義)。cycle 10 S-4 対応で旧「`0` を行非依存 sentinel として扱う」設計から `null` 許容に変更。severity_map 構築時は `line == null` を `"anchor"` key に正規化して同一ファイル複数指摘の key 衝突を防ぐ (fix.md Phase 1.2.0 severity_map 構築参照)。**後方互換**: 読取側は `line: 0` を引き続き legacy sentinel として受理し、`null` と同じ扱いにする |
| `description` | string | ✅ | 指摘内容 |
| `suggestion` | string | ✅ | 推奨対応 |
| `status` | **enum** (string) | ✅ | 対応状態。**受理値**: `"open"` / `"fixed"` / `"replied"` / `"deferred"` の 4 値。現行実装では `/rite:pr:review` Phase 6.1.a は常に `"open"` を出力する (将来の state machine 拡張で `/rite:pr:fix` 完了時に `"fixed"` 等を書き戻す slot を予約)。未知値は read 側で WARNING emit + `[CONTEXT] REVIEW_SOURCE_ENUM_UNKNOWN=1; reason=status_unknown_value; value=<val>` を stderr 出力する |

### severity 別名マッピング表

外部レビューツール (`/verified-review`, `pr-review-toolkit:review-pr`, 手動コメント等) が出力する severity 表記を、本 schema の 5 値 enum (`CRITICAL`/`HIGH`/`MEDIUM`/`LOW-MEDIUM`/`LOW`) に正規化する際の受理可能な別名一覧。**比較は必ず case-insensitive で行うこと** (例: `Critical` / `critical` / `CRITICAL` はいずれも `CRITICAL` にマッチ)。

| 認識される別名 (case-insensitive) | 正規化先 enum 値 |
|-----------------------------------|------------------|
| `Critical`, `CRITICAL`, `BLOCKER`, `CRIT`, `🔴`, `重大`, `致命` | `CRITICAL` |
| `Important`, `IMPORTANT`, `MAJOR`, `HIGH`, `High`, `🟠`, `重要`, `高` | `HIGH` |
| `Minor`, `MINOR`, `MEDIUM`, `Medium`, `Normal`, `🟡`, `中` | `MEDIUM` |
| `Low-Medium`, `LOW-MEDIUM`, `LowMedium`, `low_medium`, `中低`, `軽中` | `LOW-MEDIUM` |
| `Low`, `LOW`, `INFO`, `TRIVIAL`, `Nit`, `NIT`, `🔵`, `低`, `情報` | `LOW` |

**運用ポリシーとの関係**: rite workflow の運用では reviewer agent (`plugins/rite/agents/*-reviewer.md`) は `Critical` / `Important` / `Minor` の 3 段階を使うことが多い (MEMORY.md `review-quality-principles` 参照)。これは **運用レイヤ** の分類であり、**schema レイヤ** の 5 値 enum に対しては上記マッピング表を通じて: `Critical` → `CRITICAL`、`Important` → `HIGH`、`Minor` → `MEDIUM`、`Low-Medium` → `LOW-MEDIUM` のように正規化される。write 側 (`review.md` Phase 6.1.a) は必ず schema enum 5 値で出力し、read 側 (`fix.md` Phase 1.2 best-effort parser) が外部ツール由来の別名をここで正規化する。

**絵文字エイリアスの実運用検証状況**: 絵文字 (`🔴`/`🟠`/`🟡`/`🔵`) は将来の互換性のため列挙しているが、主要な外部ツールが絵文字を出力する事例は未検証。新しい外部レビューツールへの対応として絵文字エイリアスを追加した場合は、本表の下に注記を追加すること。

**LOW-MEDIUM 日本語別名 (`中低` / `軽中`) の実運用検証状況**: これらは LOW-MEDIUM の新造語 alias であり、主要な外部ツールが出力する事例は未検証 (PR #708 / Issue #709 時点)。canonical な schema variants (`Low-Medium`, `LOW-MEDIUM`, `LowMedium`, `low_medium`) で十分な可能性があるため、運用上不要と判明した場合は本表から削除を検討すること。新しい外部ツールが日本語別名を出力する事例を確認した場合は、その出典を本表の下に追記すること。

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
- `/rite:pr:fix` Phase 1.2.0 Priority 3 は code fence 内の JSON を `---` separator 以降の **最後** の `### 📄 Raw JSON` section に scope 限定して抽出する。awk パーサの対象は PR コメント本文 (`gh pr view --json comments` で取得した文字列) のみで、リポジトリ内の本ドキュメント (schema.md) を読むことはない。scope 限定の目的は、finding の `description` / `suggestion` 列内に literal `### 📄 Raw JSON` 文字列が含まれる場合 (本 PR 自身が該当) の誤捕捉を防ぐこと。POSIX awk のみで動作する 1-pass + END 逆方向スキャン実装は fix.md Phase 1.2.0 の bash block を参照

## 読取優先順位 (pr:fix)

`/rite:pr:fix` は以下の優先順位でレビュー結果を取得する:

| Priority | ソース | 発動条件 | 失敗時の動作 |
|----------|-------|---------|-------------|
| 0 | **明示的ファイル指定** | `--review-file <path>` 指定時 | 指定パスを読取。**4 種の失敗モード** (パス不在 / JSON 不正 / schema_version 不明 / `explicit_file_commit_sha_mismatch` (json commit_sha が HEAD と不一致、stale file protection)) のいずれでも Priority 1-3 にフォールスルーせず直接 Priority 4 (対話式 fallback) へ遷移 (ユーザーの明示意図を尊重) |
| 1 | **会話コンテキスト** | 同一セッション内で `/rite:pr:review` が直前に実行されていれば、その結果を直接利用。**採用時は `[CONTEXT] REVIEW_SOURCE=conversation; pr_number={pr_number}` を stderr に emit する義務がある** (observability 義務、後段の provenance log に必要) | Claude が会話履歴に rite review 結果を見つけられなかった場合は次の Priority へ |
| 2 | **ローカルファイル** | `.rite/review-results/{pr_number}-*.json` の中で最新 `timestamp` のファイル (lexicographic sort) | **4 種の失敗モードいずれも** WARNING を出して **Priority 3 (PR コメント) に直接 routing** する: (a) `local_file_json_parse_failure` (`jq empty` で JSON syntax invalid)、(b) `local_file_schema_required_fields_missing` (parse 可能だが `schema_version` 非空文字列 / `pr_number` 数値型 / `findings[]` 配列型のいずれかが欠落)、(c) `local_file_schema_version_unknown` (schema_version 未知)、(d) `local_file_commit_sha_mismatch` (json commit_sha が現 HEAD と不一致、stale file protection)。古い timestamp ファイルには fallback しない |
| 3 | **PR コメント (後方互換)** | PR コメントの `## 📜 rite レビュー結果` セクション (新形式: `### 📄 Raw JSON` 付き → awk で Raw JSON section-scoped 抽出。旧形式: Markdown テーブル → 既存パースロジック) | 失敗モード: (a) `pr_comment_raw_json_parse_failure`、(b) `pr_comment_schema_required_fields_missing`、(c) `pr_comment_schema_version_unknown` は legacy Markdown parser へ fallthrough。(d) `pr_comment_commit_sha_mismatch` は **WARNING のみで continue** (Raw JSON の severity_map 構築を続行。PR コメントは最新 push 後に投稿される可能性が高く、legacy parser への fallthrough はむしろ情報損失になるため) |
| 4 | **対話式 fallback** | 上記すべて欠落時 | `AskUserQuestion` で「レビュー実行 / ファイルパス指定 / 中止」を提示 (ファイルパス指定 retry 上限 3 回、state file による hard gate で強制終了) |

**Priority 1 emit 義務の理由**: Priority 1 は Claude の自然言語判断に依存する経路で bash の if-else では捕捉できない。後段の Phase 4.5.3 / 4.6 で `{review_source}` を log に出すため、conversation 経由で取り込んだ場合も他の Priority と同様に provenance を残す必要がある。emit 忘れは silent provenance loss となり、fix 後のトラブルシュートが困難になる。

**Priority 0 の non-trivial 挙動**: `--review-file` 失敗時は Priority 1-3 にフォールスルーせず直接 Priority 4 (対話式 fallback) に遷移する。これはユーザーが明示的に特定のファイルを指定した意図を尊重するため — silent に別ソースから読み込むと予期しない finding が fix 対象になるリスクがある。

**Priority 2 schema_version 不明時の挙動**: lexicographic sort で選ばれた最新ファイルが未知 schema の場合、古い timestamp ファイルには fallback せず、直接 Priority 3 (PR コメント) に routing する。これは「古い schema のファイルを選ぶより、最新の通信経路 (PR コメント) を信頼する」という設計判断。

**Stale file detection (Priority 0/2/3 共通の commit_sha mismatch routing)**: `fix.md` Phase 1.2.0 は各 Priority の success 経路で `json_commit_sha` を `git rev-parse HEAD` と比較し、不一致時は以下の routing を実行する (cycle 12 I-4 で本 table に明記):

- Priority 0 mismatch → Priority 1-3 にフォールスルーせず **Priority 4 (対話式 fallback)** へ直接遷移 (ユーザー意図尊重)
- Priority 2 mismatch → **Priority 3 (PR コメント)** へ routing
- Priority 3 mismatch → **WARNING のみで continue** (Raw JSON の severity_map 構築を続行、legacy Markdown parser への fallthrough はしない)。**注意: Priority 2 も stale で Priority 3 に routing された場合、Priority 3 の stale データが WARNING のみで消費されるカスケードが発生しうる** (WARNING には P2 stale 経由であることを明示する文言を含む)

retained flag: `[CONTEXT] REVIEW_SOURCE_STALE=1; reason={explicit_file|local_file|pr_comment}_commit_sha_mismatch` を stderr に emit。これは「review した時点の commit と現 HEAD が異なる場合、findings は既に修正済み / 意味を失っている可能性がある」という invariant を守るための defense-in-depth。`fix.md` Phase 1.2.0 の bash block 内の各 Priority success 経路にある `commit_sha stale detection` コメントアンカーを参照。

## 明示的ファイル指定

`/rite:pr:fix --review-file <path>` で任意のファイルパスを直接指定可能。パスが存在しない / JSON パース失敗時はエラーを表示して対話式 fallback に誘導する (上記 Priority 0 行参照)。fix.md Phase 1.0.1 で `$ARGUMENTS` から `--review-file` トークンを pre-strip し、Phase 1.0 Detection rules は残りの引数のみを評価する。

## エラーハンドリング

> **Priority 別の routing ルールは上記「読取優先順位 (pr:fix)」表が Single Source of Truth**。本セクションは write 側 (`/rite:pr:review`) と引数整合性のエラーのみを扱う。read 側 (`/rite:pr:fix`) の失敗経路は Priority 別に大きく挙動が異なるため、本表では要約せず Priority 表と直下の「Priority 0 の non-trivial 挙動」「Priority 2 schema_version 不明時の挙動」の注記を参照のこと。特に `--review-file` (Priority 0) の失敗は Priority 1-3 にフォールスルーせず直接 Priority 4 に遷移する点、およびローカルファイル (Priority 2) の parse/schema 失敗は古い timestamp ファイルではなく Priority 3 に直接 routing する点は、旧版の「次の優先順位のソースを試行」要約と異なる。

### Write 側 (`/rite:pr:review`) のエラー

| 条件 | 挙動 |
|------|------|
| `.rite/review-results/` ディレクトリ作成不可 | 警告表示し、会話コンテキストのみで続行 (`/rite:pr:review` 全体は失敗扱いにしない — D-04 non-blocking contract) |
| JSON 書き込み失敗 | 警告表示し、PR コメント投稿または会話コンテキスト経由で続行 (D-04 non-blocking contract、ただし `post_comment=false` ∧ save 失敗時は H-1 で WARNING に昇格し復旧手順を提示) |
| 同一秒連続実行での file path 衝突 | collision 検出時に `~<4桁hex>` suffix (`~$(printf '%04x' "${RANDOM:-0}")` 相当) で回避を試みる (best-effort、完全保証ではない — M-2 tradeoff)。separator は `~` (0x7E) を使用。ファイル名分岐点で `.` (0x2E) < `~` (0x7E) のため collision-resolved 版が lexicographic 大 → `sort -r` で先頭に並ぶ (cycle 8 M-2 で `-` から変更済み) |

### 引数整合性のエラー

| 条件 | 挙動 |
|------|------|
| `--post-comment` と `--no-post-comment` 同時指定 | エラーメッセージを表示して終了 (レビューもコメント投稿も実行しない — AC-8) |

## クリーンアップ

`/rite:pr:cleanup` は PR マージ後のブランチ削除時に、該当 PR 番号の以下 3 種類のローカル artifact を削除する。Phase 2.5 の failure reason 表と eval-order enumeration は `cleanup.md` Phase 2.5 を単一の真実の源として参照する (双方向リンク):

1. **レビュー結果ファイル**: `.rite/review-results/{pr_number}-*.json`
2. **破損レビュー結果ファイル**: `.rite/review-results/{pr_number}-*.json.corrupt-*` (`fix.md` Phase 1.2.0 Priority 2 が corrupt 検出時に `.corrupt-{epoch}` suffix で rename したファイル。長期運用で累積する orphan を防ぐ)
3. **fix retry state file**: `.rite/state/fix-fallback-retry-{pr_number}.count`

wildcard は PR 番号 prefix 固定とし、他 PR のファイルを誤って削除しないよう保証する。state file は specific path (`{pr_number}.count` 完全一致) で削除する。

## 関連ファイル

- `plugins/rite/commands/pr/review.md` Phase 6.1: JSON 生成と保存ロジック (AC-1 default stop / AC-2 opt-in posting / D-04 non-blocking contract)
- `plugins/rite/commands/pr/fix.md` Phase 1.2.0: ハイブリッド読取ロジック (AC-3/4 会話/ファイル優先 / AC-5 後方互換 / AC-6 対話式 fallback)
- `plugins/rite/commands/pr/cleanup.md` Phase 2.5: 自動削除ロジック (review result files + corrupted review result files + fix retry state file の 3 種類を削除)。Phase 2.5 の failure reason 表と eval-order enumeration は cleanup.md 側を単一源とする。
- `rite-config.yml` `pr_review.post_comment`: グローバル設定
- `.gitignore`: `.rite/review-results/` 除外設定
