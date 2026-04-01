# Fact-Checking Phase Reference

> **Source**: Referenced from `review.md` Phase 5 Critic Phase (`#### Fact-Checking Phase`, between Deduplication and Specification Consistency Verification). This file is the source of truth for fact-checking rules.

## Overview

AI レビュアーが外部仕様（ライブラリ動作、ツール設定、バージョン互換性等）について行う主張を公式ドキュメントで検証し、誤情報が PR コメントに永続化するリスクを排除する。

Fact-Checking Phase は Critic Phase パイプラインの Deduplication と Specification Consistency Verification の間に位置する:

```
Debate → Dedup → Fact-Checking → Spec Consistency → Assessment → Report
```

## Configuration

Read `review.fact_check` from `rite-config.yml`:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | boolean | `true` | ファクトチェック Phase の有効/無効 |
| `max_claims` | integer | `10` | 1レビューあたり最大検証数（コスト制御） |

**Skip conditions** (any match → skip entire phase):
- `review.fact_check.enabled: false`
- External claims = 0 (all findings are internal)

---

## Claim Classification

### Internal Claims (検証不要)

コードベース内のファイルを読めば正誤を判断できる指摘。レビュアーが実コードを読んで検証済みのため追加検証不要:

- null チェック漏れ、型の不整合、命名規則違反
- テストカバレッジの不足
- コメントと実装の乖離
- エラーハンドリングの欠落
- コード構造、パフォーマンス、セキュリティ（コードベース内で完結するもの）

### External Claims (検証必要)

コードベース外の知識に依存する指摘。以下のシグナルで検出する:

| シグナル | 例 |
|---------|-----|
| ライブラリ/パッケージの動作への言及 | 「esbuild は ignore-scripts でも動作する」 |
| ツール設定の意味への言及 | 「npm の min-release-age は日数を指定する」 |
| バージョン固有の動作への言及 | 「この機能は npm v11.10.0 で導入された」 |
| API 互換性への言及 | 「React 18 ではこの API が非推奨になった」 |
| CVE/脆弱性への言及 | 「このパッケージには CVE-XXXX がある」 |
| 外部ベストプラクティスへの言及 | 「OWASP では〜を推奨している」 |
| ランタイム動作への言及 | 「Node.js の optionalDependencies は〜」 |

### Classification Principle

迷ったら「外部仕様」に分類する。

- **偽陽性のコスト** = WebSearch 1回分（低い）
- **偽陰性のコスト** = 誤情報が PR コメントに残るリスク（高い）

Findings の `内容` 列と `推奨対応` 列をスキャンし、上記シグナルテーブルに該当するキーワードを含むものを External として分類する。

**"要検証" マーカー**: `推奨対応` 列に "要検証" が含まれる場合は、レビュアーが外部仕様の確信度が低いことを明示的にシグナルしている。この finding は無条件で External として分類する。また、max_claims 超過時の優先度ソートでは、"要検証" 付きの claim を同一 severity 内で優先する。

---

## Verification Execution

### Method Priority

1. **WebSearch** — ツール設定、CLI 動作、バージョン情報、CVE、ベストプラクティス → 公式ドキュメントサイトでフィルタ
2. **WebFetch** — 公式ドキュメントの URL が判明している場合 → 直接取得

> **Note**: context7 MCP ツール（`resolve-library-id` / `query-docs`）は本フェーズのスコープ外（TODO: 別 Issue で統合予定、Issue 未作成）。

### Verification Steps (per claim)

各 External claim について以下の手順を実行:

**Step 1: 主張を1文で明確化する**

Finding の `内容` / `推奨対応` から外部仕様の主張を1文に要約する。

例: 「npm の ignore-scripts=true を設定すると、esbuild の postinstall スクリプトが実行されず、ビルドが壊れる」

**Step 2: 検証方法を選択する**

| 主張の種類 | 検証方法 |
|-----------|---------|
| ツール設定、CLI 動作 | WebSearch（公式ドキュメントサイト限定） |
| バージョン情報、CVE | WebSearch（リリースノート、CVE DB） |
| 公式 URL が既知 | WebFetch（直接取得） |

**Step 3: 検証結果を判定する**

| 判定 | 条件 | 記録内容 |
|------|------|---------|
| ✅ VERIFIED | 公式ドキュメントが主張を裏付け | ソース URL |
| ❌ CONTRADICTED | 公式ドキュメントが主張と矛盾 | 正しい情報 + ソース URL |
| ⚠️ UNVERIFIED:ソース未確認 | 権威あるソースが見つからない | 注記（手動確認推奨） |
| UNVERIFIED:リソース超過 | max_claims を超過し検証未実施 | 注記（検証未実施） |

### Verification Rules

- 1つの主張に対して**最低1つの公式ソース**を確認する
- ソース優先順位: 公式ドキュメント > ブログ記事 > Stack Overflow
- 矛盾が見つかった場合、**複数ソースでクロスチェック**する
- 検証に使った URL は必ず記録する

---

## Finding Modification Rules

Fact-Checking Phase の結果に基づき、findings を以下のルールで修正する。修正は Assessment（5.3）の**前**に完了する。

### VERIFIED (✅)

- **`全指摘事項`**: finding を維持。`推奨対応` 列末尾にソース URL を付記
  - フォーマット: `{original_recommendation} ([source](URL))`
- **`高信頼度の指摘`**: 変更なし（維持）
- **blocking**: 維持

### CONTRADICTED (❌)

- **`全指摘事項`**: finding を**除外**
- **`高信頼度の指摘`**: finding を**除外**
- **Report**: 専用セクション `### 矛盾により除外された指摘` に移動
  - 記録内容: 元の主張、公式ドキュメントの正しい情報、ソース URL
- **blocking**: 解除（カウント対象外）

### UNVERIFIED:ソース未確認 (⚠️)

- **`全指摘事項`**: finding を**除外**（blocking 解除）
- **`高信頼度の指摘`**: finding を**除外**
- **Report**: `### 外部仕様の検証結果` セクションに status ⚠️ で記録
  - 注記: 「手動確認推奨」
- **blocking**: 解除（カウント対象外）

### UNVERIFIED:リソース超過

- **`全指摘事項`**: finding を**維持**（blocking 維持）
- **`高信頼度の指摘`**: 変更なし（維持）
- **Annotation**: `内容` 列に `[未検証:リソース超過]` プレフィックスを付加
- **blocking**: 維持

> **MUST NOT**: `max_claims` 超過を理由に正当な finding の blocking を解除してはならない。

---

## max_claims Handling

外部 claim が `max_claims` を超過した場合:

1. 全 External claims を severity 順にソート（CRITICAL > HIGH > MEDIUM > LOW）
2. 同一 severity 内の tiebreak: "要検証" マーカー付きを優先、その後は findings テーブル上の出現順
3. 上位 `max_claims` 件を検証対象として選択
4. 残りは `UNVERIFIED:リソース超過` として `全指摘事項` に残す（blocking 維持）

---

## Verification Mode Handling

`review_mode == "verification"` の場合:

### 前回 VERIFIED 済み finding の再検証スキップ

1. 前回のレビューコメント（`📜 rite レビュー結果`）から `### 外部仕様の検証結果` セクションを検索
2. 前回 `✅ 検証済み` と判定された finding を `file:line` + reviewer で照合
3. **照合成功**: 再検証をスキップし、前回のソース URL を引き継ぐ
4. **照合失敗**（前回コメントにセクションなし、または finding が新規）: 通常どおり検証を実行

### REGRESSION finding

新規検出された finding（verification mode で NOT_FIXED/REGRESSION として分類されたもの）は、前回の検証結果に関わらず通常どおりファクトチェックを実行する。

---

## Error Handling

| エラー条件 | 動作 |
|-----------|------|
| WebSearch がタイムアウトまたはエラー | 該当 claim を `UNVERIFIED:ソース未確認` として扱い続行 |
| WebFetch がタイムアウトまたはエラー | WebSearch にフォールバック。それも失敗 → `UNVERIFIED:ソース未確認` |
| 全検証ツール利用不可（ネットワーク障害等） | Phase 全体をスキップし findings をそのまま維持（blocking 維持） |
| External claim 0件検出 | 検証スキップ、Spec Consistency に進む。レポートに検証セクション非表示 |

---

## Fact-Check Metrics

Phase 完了後、Spec Consistency に進む前にインラインサマリーを出力する。このサマリーは Phase 間遷移時の中間確認用。Assessment Decision Time の最終出力は `assessment-rules.md` の `【外部仕様検証】` セクションを参照。

```
ファクトチェック完了:
- 外部仕様の主張: {total_external} 件
- 検証済み (✅): {verified} 件
- 矛盾 (❌): {contradicted} 件
- 未検証:ソース未確認 (⚠️): {unverified_source} 件
- 未検証:リソース超過: {unverified_limit} 件
```

**E2E output suffix** (fact-check が実行された場合のみ付加):

```
| fact-check: {verified}✅ {contradicted}❌ {unverified}⚠️
```

ここで `{unverified}` = `{unverified_source}` + `{unverified_limit}` の合計。

---

## Report Sections

### `### 外部仕様の検証結果` セクション

外部仕様の主張が 1件以上検出された場合に表示。0件の場合はセクション自体を省略。

```markdown
### 外部仕様の検証結果

| 指摘 | 主張 | 検証結果 | ソース |
|------|------|---------|--------|
| {file:line} ({reviewer}) | {claim_summary} | ✅ 検証済み / ⚠️ 未検証 | [source](URL) |

**ファクトチェック**: {verified}✅ {contradicted}❌ {unverified}⚠️
```

**Note**: `UNVERIFIED:リソース超過` finding はこのテーブルに含めない。リソース超過 finding は `全指摘事項` に `[未検証:リソース超過]` アノテーション付きで残る（blocking 維持）。このテーブルは検証を実施した claim のみを記録する。

### `### 矛盾により除外された指摘` セクション

CONTRADICTED 指摘が 1件以上ある場合に表示。0件の場合はセクション自体を省略。

```markdown
### 矛盾により除外された指摘

> このセクションの指摘は、公式ドキュメントと矛盾しているため指摘事項から除外されました。

| 重要度 | ファイル:行 | 当初の主張 | 公式ドキュメントの記述 | ソース |
|--------|------------|-----------|----------------------|--------|
| {severity} | {file:line} | {original_claim} | {correct_info} | [source](URL) |
```

### Section Ordering in Report

両テンプレート（Full / Verification）共通:

```
### 高信頼度の指摘（複数レビュアー合意）
### 外部仕様の検証結果（該当がある場合のみ）    ← NEW
### 矛盾により除外された指摘（該当がある場合のみ）  ← NEW
### 全指摘事項
```

> **fix.md 互換性**: 新セクションは `### 全指摘事項` の**前**に配置。fix.md Phase 1.2.1 は `### 全指摘事項` を起点にパースするため影響なし。VERIFIED findings の `推奨対応` 列へのソース URL 付記は column 4 のテキストとして無害にパースされる。
