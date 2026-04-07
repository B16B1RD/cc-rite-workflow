# Internal Consistency Verification Reference

> **Source**: Referenced from `tech-writer.md` Critical (Must Fix) checklist の「文書-実装整合性」項目群、および `prompt-engineer.md` の skill/command 間整合性チェック。本ファイルは**プロダクト内部事実とドキュメント記述の整合性**を検証するための "source of truth" である。

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
| `file_ratio_threshold` | number | `0.6` | ドキュメント行数比率の閾値 (total_diff に対する doc_lines の比率) |
| `count_ratio_threshold` | number | `0.7` | ドキュメントファイル数比率の閾値 (total_files に対する doc_files の比率) |
| `max_diff_lines_for_count` | integer | `2000` | ファイル数比率判定を有効にする最大 diff 行数 |

**Skip conditions** (any match → skip entire protocol):

- `review.doc_heavy.enabled: false`
- 変更ファイルが rite plugin 自身の `commands/**/*.md`, `skills/**/*.md`, `agents/**/*.md` のみ（これらは prompt-engineer の専管領域）
- 変更ファイルにドキュメント (`docs/**/*.md`, `**/README.md`, `i18n/**` 等) が全く含まれない

## Verification Protocol

本プロトコルは **5 項目** の検証カテゴリで構成される。各カテゴリは `tech-writer.md` の Critical Checklist 同名項目と 1:1 対応する。

### 1. Implementation Coverage

**何を検証するか**: ドキュメントが主張する機能集合と、実装の機能集合との間に差分がないか。

**検証ステップ**:

1. ドキュメント側の主張を抽出 — 箇条書き / テーブル / 段落から機能名・モジュール名・サービス名を列挙
2. 実装側の機能集合を `Grep` で抽出:
   - ルート定義: `Grep` で `router.{get,post,put,delete,patch}\(` / `app.use\(`
   - モジュールエクスポート: `Grep` で `export (const|function|class|default)`
   - パッケージディレクトリ: `Glob` で `src/{modules,services,features}/*/`
3. 集合差分を計算:
   - ドキュメントのみにある要素 = 実装に存在しない (偽の主張)
   - 実装のみにある要素 = ドキュメントから欠落 (紹介漏れ)
4. いずれかが空でなければ **CRITICAL** として報告

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

**Grep パターン例**:

```bash
# 「3 つ」「5 個」等の主張をドキュメントから抽出
Grep: '^(\d+|三|五|十)\s*(つ|個|種類|項目|ステップ)'

# 実装側の配列長
Read: src/config/services.ts → .SERVICES 配列の要素数をカウント
```

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
3. 不一致であれば **HIGH** (戦略的意図が損なわれる) or **MEDIUM** (単純な順序ズレ) として報告

**注意**: 単純な "アルファベット順 vs カテゴリ順" のような表現差は Confidence 80 未満で除外。実装側の明確な priority (例: `priorityOrder = ['autonomous', ...]`) との乖離のみ報告。

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

- **Confidence >= 80** の指摘のみ報告する (`_reviewer-base.md` の Confidence Scoring に従う)
- "もしかしたら" "念のため" レベルの推測は**必ず除外** (sub-80)
- 証拠 (ファイルパス + 行番号 + 具体的な差分) を伴う指摘のみ Confidence 80+ とみなす

### Severity Mapping

| Verification Category | Default Severity | 昇格条件 |
|-----------------------|------------------|----------|
| Implementation Coverage | **CRITICAL** | 常に CRITICAL (機能集合の不一致は user-facing の誤情報) |
| Enumeration Completeness | **CRITICAL** | 常に CRITICAL |
| UX Flow Accuracy | **CRITICAL** | UX 手順書の矛盾はユーザーを実質的にブロックする |
| Order / Emphasis Consistency | **HIGH** | 戦略的意図が明示されている場合は CRITICAL に昇格 |
| Screenshot Presence | **CRITICAL** (missing) / **HIGH** (alt text) | パス無効は CRITICAL、alt 欠落は HIGH |

### Scope Boundary

本プロトコルは**コードベース内部**の事実検証のみを扱う。以下は**スコープ外**として `fact-check.md` に委譲する:

- 外部ライブラリ/API の動作主張 (例: 「React 18 では useEffect が...」)
- バージョン互換性の主張 (例: 「Node.js 18 以上で動作」)
- CVE / セキュリティアドバイザリへの言及
- 外部ツール (CLI, SaaS) の仕様主張

迷った場合は `fact-check.md` に委譲することで偽陰性（誤情報の見逃し）を防ぐ。

## Cross-Reference

本ファイルは以下の箇所から参照される:

- **`plugins/rite/skills/reviewers/tech-writer.md`** Critical (Must Fix) チェックリストの「文書-実装整合性」5 項目
- **`plugins/rite/skills/reviewers/tech-writer.md`** "Doc-Heavy PR Mode (Conditional)" セクション (Mandatory Implementation Cross-Reference, Screenshot Completeness Check)
- **`plugins/rite/commands/pr/review.md`** Phase 1.2.7 Doc-Heavy PR Detection および Phase 2.2.1 Doc-Heavy Reviewer Override
- **`plugins/rite/skills/reviewers/prompt-engineer.md`** (将来拡張時) — skill/command ドキュメント内の事実整合性チェック

**関連**:

- `fact-check.md` — 外部仕様検証の対応ファイル
- `assessment-rules.md` — ALL findings are blocking ルール
- `_reviewer-base.md` — Confidence Scoring 80+ ゲート
