# Internal Consistency Verification Reference

> **Source**: Referenced from `tech-writer.md` Critical (Must Fix) checklist の「文書-実装整合性」5 項目。本ファイルは**プロダクト内部事実とドキュメント記述の整合性**を検証するための "source of truth" である。

## Overview

AI レビュアーが、ドキュメントが主張する事実（機能集合、列挙数、UX フロー、順序、ビジュアル資産）をリポジトリ内のコードベースで検証し、**文書と実装の乖離を初回レビューで検出する**。`fact-check.md`（外部仕様検証）と対の関係にあり、両者で "外部仕様" と "内部事実" を網羅する。

**対象とスコープ**:

- **対象**: プロダクトのユーザー向けドキュメント (README, docs/, CHANGELOG, オンボーディングガイド, チュートリアル等) における事実主張
- **スコープ外**: 外部ライブラリ/API/ツールの仕様主張（→ `fact-check.md` に委譲）、実行時のパフォーマンス/スケーラビリティ検証、セキュリティ脆弱性検出（各 reviewer のスコープ）

**位置づけ**:

```
[tech-writer] Critical Checklist (文書-実装整合性 5 項目)
     ↓ 検証プロトコル参照
[internal-consistency.md] ← このファイル
     ↓ 分類後に外部仕様と判明
[fact-check.md] (外部仕様検証)
```

## Configuration

Read `review.doc_heavy` from `rite-config.yml`:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | boolean | `true` | Doc-Heavy PR 判定と本プロトコルの有効/無効 |
| `lines_ratio_threshold` | number | `0.6` | ドキュメント**行数比率**の閾値 (`doc_lines / total_diff_lines`、total_diff に対する doc_lines の比率) |
| `count_ratio_threshold` | number | `0.7` | ドキュメント**ファイル数比率**の閾値 (`doc_files_count / total_files_count`、total_files に対する doc_files の比率) |
| `max_diff_lines_for_count` | integer | `2000` | ファイル数比率判定を有効にする最大 diff 行数 |

**Activation 条件**: 本プロトコルは `{doc_heavy_pr=true}` フラグ (review.md Phase 1.2.7 で計算される) が set されているときのみ発動する。

> **Single source of truth**: skip/activation に関する全ての判定は [`commands/pr/review.md`](../review.md) Phase 1.2.7 の `{doc_heavy_pr}` 計算結果に**完全に委譲**される。本ファイルでは独立した skip 条件を定義しない（二重定義による drift を防ぐため）。
>
> - `review.doc_heavy.enabled: false` → Phase 1.2.7 が `{doc_heavy_pr} = false` を explicit set → 本プロトコル非発動
> - `changedFiles == 0` (空 PR) → Phase 1.2.7 が `{doc_heavy_pr} = false` を explicit set → 本プロトコル非発動
> - rite plugin 自身の `commands/**/*.md`, `skills/**/*.md`, `agents/**/*.md`, `plugins/rite/i18n/**` のみを変更 → Phase 1.2.7 の「分子から除外、分母には含める」方式で計算結果が自動的に `doc_heavy_pr = false` になる → 本プロトコル非発動
> - 変更ファイルにドキュメントが全く含まれない → `doc_lines = 0` / `doc_files_count = 0` で ratio が閾値未満になり自動的に `doc_heavy_pr = false` → 本プロトコル非発動

## Verification Protocol

本プロトコルは **5 項目** の検証カテゴリで構成される。各カテゴリは `tech-writer.md` の Critical Checklist 同名項目と 1:1 対応する。

### 1. Implementation Coverage

**何を検証するか**: ドキュメントが主張する機能集合と、実装の機能集合との間に差分がないか。

**検証ステップ**:

1. ドキュメント側の主張を抽出 — 箇条書き / テーブル / 段落から機能名・モジュール名・サービス名を列挙
2. リポジトリの主言語を判定 (`package.json`, `pyproject.toml`, `go.mod`, `Cargo.toml`, `Gemfile`, `composer.json` 等の存在から)
3. 実装側の機能集合を `Grep` で抽出 — **言語別パターン**:

   | 言語 | ルート定義パターン例 | モジュールエクスポート例 |
   |------|-------------------|------------------------|
   | Node.js / TypeScript | `router\.(get\|post\|put\|delete\|patch)\(`, `app\.(use\|route)\(` | `export (const\|function\|class\|default)`, `module\.exports` |
   | Python | `@app\.route\(`, `@router\.(get\|post\|...)\(`, `path\(`, `re_path\(` | `^def `, `^class `, `__all__` |
   | Go | `http\.HandleFunc\(`, `r\.(GET\|POST\|...)\(`, `mux\.Handle\(` | `^func `, `^type ` (exported: 大文字始まり) |
   | Rust | `#\[(get\|post\|put\|delete)\(`, `\.route\(`, `Router::new` | `^pub fn `, `^pub struct `, `^pub enum ` |
   | Ruby (Rails) | `get '`, `post '`, `resources :` (routes.rb) | `class `, `module ` |
   | PHP | `Route::(get\|post\|...)\(`, `$app->(get\|post)\(` | `class `, `function `, `interface ` |
   - パッケージディレクトリ: `Glob` で `src/{modules,services,features}/*/` (言語別に調整)
4. 集合差分を計算:
   - ドキュメントのみにある要素 = 実装に存在しない (偽の主張)
   - 実装のみにある要素 = ドキュメントから欠落 (紹介漏れ)
5. いずれかが空でなければ **CRITICAL** として報告

**言語判定の fallback**: 主言語を自動判定できない場合は、変更ファイルの拡張子から推定する (`.ts/.tsx/.js/.jsx` → Node.js、`.py` → Python、`.go` → Go、`.rs` → Rust など)。それでも不明な場合は全パターンを試す。

**出力例**:

```
CRITICAL: Implementation Coverage mismatch
- Location: docs/overview.md:12-20
- Claim: 3 つのコア機能 (Flow Designer, Autonomous, Optimization)
- Reality: src/config/services.ts:5 には 5 要素 ['flow-designer', 'autonomous', 'optimization', 'compath', 'ingest']
- Missing from docs: ComPath, Ingest (2 件が紹介されていない)
```

### 2. Enumeration Completeness

**何を検証するか**: ドキュメントが主張する数値・集合が、実装の定義数と一致するか。

**検証ステップ**:

1. ドキュメント側の数値主張を抽出: 「3 つの...」「5 ステップ」「主要カテゴリは...」等
2. 実装側の該当定義を `Read` で確認:
   - 定数配列: `export const SERVICES = [...]` の要素数
   - ディレクトリ構造: `Glob` で該当ディレクトリの子数
   - 設定ファイル: yaml/json の配列長
3. 不一致なら **CRITICAL** として報告

**Grep パターン例** (Claude Code の Grep ツール (ripgrep) 専用の擬似コード、bash `grep -E` への直接適用は想定していない):

```text
# 「3 つ」「5 個」「three services」等の主張をドキュメントから抽出
# 注: `^` 制約は付けない (テーブル行・リスト子要素・段落途中の数値主張も拾うため)
# 注: すべて non-capture group `(?:...)` を使用し、キャプチャ番号のずれを防ぐ
Grep: '(?:\d+|[一二三四五六七八九十百]|three|four|five|six|seven|eight|nine|ten)\s*(?:つ|個|種類|項目|ステップ|services?|items?|steps?|categor(?:y|ies))'

# 実装側の配列長
Read: src/config/services.ts → .SERVICES 配列の要素数をカウント
```

> **Note**: 実ドキュメントで最も頻出するのはアラビア数字 (`\d+`) なので、これがマッチの主役。漢数字 (`一二三〜十百`) と英語数詞 (`three〜ten`) は補助的にカバーする。網羅性が必要な場合は AI レビュアーが文脈に応じて他の数詞 (`千`, `eleven` 以降, `dozens of` 等) を追加すること。`\d` は Claude Code の Grep ツール (ripgrep) で Unicode digit にマッチする。

### 3. UX Flow Accuracy

**何を検証するか**: ドキュメントの UX 手順書（スクリーン遷移、フォーム入力、ボタン配置）が、実装の state machine / route / form schema と矛盾しないか。

**検証ステップ**:

1. ドキュメントから手順ステップを抽出: 「1. ログイン画面でメールアドレスを入力 → 2. パスワード入力 → 3. 送信」
2. 実装側の対応を `Read` で確認:
   - フロントエンド route 定義: `router.config.ts` / `App.tsx` / `routes/`
   - Form schema: `zod.object({...})` / `yup.object({...})` / `react-hook-form` の field 定義
   - State machine: `XState` / `useReducer` / Redux store の遷移
3. ステップ数・順序・必須フィールド・遷移先が一致しているか確認
4. 矛盾があれば **CRITICAL** として報告

**検証対象ツール**:

| 検証項目 | ツール | 例 |
|---------|-------|-----|
| Route 定義 | `Read` | `router.tsx` / `app/routes/` |
| State machine | `Read` | `authMachine.ts` の `states`, `transitions` |
| Form schema | `Read` | `loginSchema.ts` の `required` フィールド |
| UI コンポーネント | `Grep` | button/input のラベル・プレースホルダ |

### 4. Order / Emphasis Consistency

**何を検証するか**: ドキュメントでの説明順序・強調点が、実装側の優先度や戦略的位置付けと乖離していないか。

**検証ステップ**:

1. ドキュメントから紹介順序を抽出 (h2/h3 見出し、リスト順、テーブル行順)
2. 実装側の優先度を `Read`:
   - エントリーポイント: `src/index.ts` / `app/page.tsx` のレンダリング順
   - メインメニュー: nav / sidebar の項目順
   - 設定ファイル: `rite-config.yml` の記述順 (自己記述的な場合)
3. 不一致であれば本ファイル下部の [Severity Mapping](#severity-mapping) に従い報告

**注意**: 単純な "アルファベット順 vs カテゴリ順" のような表現差は Confidence 80 未満で除外。実装側の明確な priority (例: `priorityOrder = ['autonomous', ...]`) との乖離のみ報告。

> **Severity**: 本項目の重要度は常に CRITICAL。一次根拠は本ファイル下部の [Severity Mapping](#severity-mapping) を参照（`tech-writer.md` 側の Critical Checklist は本ファイルへの単方向参照であり循環しない）。

### 5. Screenshot Presence

**何を検証するか**: ドキュメントの番号付き手順・状態記述に対応する画像参照が存在し、かつリンク先の画像ファイルが実在するか。

**検証ステップ**:

1. ドキュメント内の手順ステップを `Grep` で抽出:
   - パターン: `^\d+\.\s` (番号付き手順)
   - パターン: `初回表示|起動時|エラー時|完了時|成功|失敗` (状態記述)
2. ドキュメント内の画像参照を `Grep` で抽出:
   - パターン: `!\[[^\]]*\]\([^)]+\)`
3. ステップ数 vs 画像数を比較:
   - 画像数 < ステップ数 → **CRITICAL** (`Screenshot Presence mismatch: N steps but only M images`)
   - 各状態記述に対応画像があるか → なければ **CRITICAL**
4. 各画像参照のパスを `Glob` で確認:
   - パスが存在しない → **CRITICAL** (broken image link)
   - alt テキストが空 → **HIGH** (アクセシビリティ)

**出力例**:

```
CRITICAL: Screenshot Presence mismatch
- Location: docs/quickstart.md
- Steps detected: 5 (lines 12, 18, 25, 33, 42)
- Image references: 2 (`![step2](...)`, `![step4](...)`)
- Missing screenshots for: Step 1, Step 3, Step 5
```

## Reporting Rules

本プロトコルで検出した指摘は、以下のルールに従って報告する。

### Confidence Gate

- **Confidence >= 80** の指摘のみ報告する (`plugins/rite/agents/_reviewer-base.md` の Confidence Scoring に従う)
- "もしかしたら" "念のため" レベルの推測は**必ず除外** (sub-80)
- 証拠 (ファイルパス + 行番号 + 具体的な差分) を伴う指摘のみ Confidence 80+ とみなす

### Severity Mapping

> **One-way reference**: 本テーブルが文書-実装整合性 5 項目の severity に関する**一次根拠**である。`tech-writer.md` の Critical (Must Fix) チェックリストは本テーブルを単方向参照しており、循環参照は存在しない。

| Verification Category | Default Severity | 根拠 |
|-----------------------|------------------|------|
| Implementation Coverage | **CRITICAL** | 機能集合の不一致は user-facing の誤情報。読者がドキュメントを信じて存在しない機能を期待する/紹介漏れの機能を見落とすため、常に CRITICAL |
| Enumeration Completeness | **CRITICAL** | 「N つの〜」のような数値主張の不一致は読者の認識モデルを直接破壊する。常に CRITICAL |
| UX Flow Accuracy | **CRITICAL** | UX 手順書の矛盾はユーザーがドキュメント通りに操作してもゴールに到達できないことを意味し、実質的なブロック障害となる。常に CRITICAL |
| Order / Emphasis Consistency | **CRITICAL** | 戦略的位置付け (priority / emphasis) の乖離はドキュメントの信頼性を根本から損なう。実装側の明確な priority 定義との乖離のみを対象とし、Confidence Gate (>= 80) で表現差は除外される。常に CRITICAL |
| Screenshot Presence | **CRITICAL** (missing / broken) / **HIGH** (alt text) | パス無効・画像欠落は CRITICAL（手順書として機能しない）、alt text 欠落はアクセシビリティ問題で HIGH |

### Scope Boundary

本プロトコルは**コードベース内部**の事実検証のみを扱う。以下は**スコープ外**として `fact-check.md` に委譲する:

- 外部ライブラリ/API の動作主張 (例: 「React 18 では useEffect が...」)
- バージョン互換性の主張 (例: 「Node.js 18 以上で動作」)
- CVE / セキュリティアドバイザリへの言及
- 外部ツール (CLI, SaaS) の仕様主張

迷った場合は `fact-check.md` に委譲することで偽陰性（誤情報の見逃し）を防ぐ。

### Implementation source not in this repository (silent skip 禁止)

ドキュメント PR が**別リポジトリ**の製品について書かれている場合 (例: monorepo の別 package、ドキュメント専用 repo)、cross-reference 検証を**silent に skip してはならない**。次のフォールバック順序を採用する:

1. **外部リポジトリへの直接アクセスを試みる**:
   - 公開リポジトリ → `gh api repos/{other_owner}/{other_repo}/contents/...` または `WebFetch`
   - プライベートリポジトリで認証可能 → `gh api` で取得
2. **「外部参照不可能」の判定条件** (silent skip を防ぐための厳格定義 — 以下のいずれかに該当する場合のみ「不可能」と扱う):

   | 判定条件 | 具体的なシグナル |
   |----------|------------------|
   | **404 (リポジトリ非存在)** | `gh api` が exit code 404、または `WebFetch` が HTTP 404 |
   | **401 / 403 (認証・権限不足)** | `gh api` が exit code 401 または 403。1 回のみリトライ (`gh auth refresh` の要否は判定しない)。リトライ後も同じエラーなら「不可能」 |
   | **2xx 以外 (HTTP エラー全般)** | `WebFetch` が 500, 502, 503, 504 等。1 回リトライして同じなら「不可能」 |
   | **タイムアウト** | `gh api` または `WebFetch` が 2 回連続タイムアウト (デフォルト Claude Code タイムアウトに準拠) |
   | **空レスポンス** | exit code 0 だが stdout が空または `null` (gh API のコーナーケース) |
   | **リポジトリ名が特定できない** | doc-only repo で cross-reference 対象の external repo owner/name を推定する情報が PR 本文・diff・config のどこにも存在しない |

   **リトライしない判定条件**: 429 (rate limit) は一時的障害であり「不可能」とは判定しない — 指数バックオフで待機後に再試行する (上記テーブルに含めない)。

3. **「外部参照不可能」と判定した場合**、以下のメタ情報を finding 出力の冒頭に**必ず含める** (silent skip 禁止):

   ```
   META: Cross-Reference partially skipped
   - Reason: Implementation source not found in this repository
   - Failure signal: <404 / 401 / timeout / empty / name-unresolved のいずれか>
   - Verified externally against: [list of sources, or "none — manual verification required"]
   - Affected categories: [Implementation Coverage / UX Flow Accuracy / etc.]
   ```

4. レビュー呼び出し側 (review.md Phase 5.1.3 Doc-Heavy Post-Condition Check) はこのメタ情報を検出し、ユーザーに明示的な確認を求める。メタ情報なしで cross-reference を skip した finding は post-condition check で reject される。

## Cross-Reference

本ファイルは以下の箇所から参照される (本ファイルからの相対パスで記載):

- [`../../../skills/reviewers/tech-writer.md`](../../../skills/reviewers/tech-writer.md) — Critical (Must Fix) チェックリストの「文書-実装整合性」5 項目および "Doc-Heavy PR Mode (Conditional)" セクション (Quick Reference テーブル + Verification skip handling)
- [`../review.md`](../review.md) — Phase 1.2.7 Doc-Heavy PR Detection、Phase 2.2.1 Doc-Heavy Reviewer Override、Phase 5.1.3 Doc-Heavy Post-Condition Check
- [`../../../skills/reviewers/SKILL.md`](../../../skills/reviewers/SKILL.md) — Reviewers 一覧テーブルの tech-writer 行 (representative file patterns)。本ファイル・tech-writer.md・review.md の 3 者と等価な doc_file_patterns を保持する (drift 監視対象)

**drift 検出の invariant** (3 ファイル等価性):

tech-writer Activation patterns は以下 3 ファイルで**等価な集合**を参照する必要がある (syntax は異なってよいが、マッチするファイル集合が同一であること):

1. `plugins/rite/skills/reviewers/tech-writer.md` Activation セクション (source of truth)
2. `plugins/rite/commands/pr/review.md` Phase 1.2.7 `doc_file_patterns` (疑似コード形式)
3. `plugins/rite/skills/reviewers/SKILL.md` Reviewers テーブル tech-writer 行 (representative)

drift 検出の自動 lint は Issue #353 で追跡中。

**関連ファイル** (本ファイルからの相対パスを明示):

- [`./fact-check.md`](./fact-check.md) (同ディレクトリ) — 外部仕様検証の対応ファイル
- [`./assessment-rules.md`](./assessment-rules.md) (同ディレクトリ) — ALL findings are blocking ルール
- [`../../../agents/_reviewer-base.md`](../../../agents/_reviewer-base.md) — Confidence Scoring 80+ ゲートの定義
