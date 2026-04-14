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
| `max_claims` | integer | `20` | 1レビューあたり最大 **External** claim 検証数（コスト制御）。Internal Likelihood Claim は Grep ベース検証のため枠外でカウントしない |
| `use_context7` | boolean | `true` | context7 MCP ツール（`resolve-library-id` / `query-docs`）による検証を使用。失敗時は既存 WebSearch fallback で自動回復 |
| `verify_internal_likelihood` | boolean | `true` | Internal Likelihood Claim の Grep ベース検証を有効化（Phase 5.2） |

**Skip conditions** (any match → skip entire phase):
- `review.fact_check.enabled: false`
- External claims = 0 **AND** Internal Likelihood claims = 0 (すべての findings が検証対象外)

> `verify_internal_likelihood: false` の場合、Phase 5.2 (Internal Likelihood Claim Verification) のみスキップし、Phase 5.1 (External Claim Verification) は独立に実行される。

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

**"要検証" マーカー**: `推奨対応` 列に "要検証" が含まれる場合は、レビュアーが外部仕様 **または Internal Likelihood** の確信度が低いことを明示的にシグナルしている。この finding は無条件で検証対象（External または Internal Likelihood）として分類する。また、max_claims 超過時の優先度ソートでは、"要検証" 付きの claim を同一 severity 内で優先する。統合レポート (`### 外部仕様の検証結果` セクション) では External / Internal Likelihood を区別せず同一テーブルに記録する。

### Internal Likelihood Claims（検証必要・新規）

Finding の `内容` 列が「実発生」を主張する場合、Grep ベースで内部検証する。External Claim と直交する新カテゴリであり、`verify_internal_likelihood: true` の場合に Phase 5.2 で処理される:

| シグナル | 例 |
|---------|-----|
| 発生条件の存在主張 | 「この関数は null を渡されることがある」 |
| 頻度主張 | 「多くの場合」「通常フローで」「常に」 |
| 呼び出しパス主張 | 「X から Y が呼ばれる」 |
| 環境依存頻度 | 「Windows では」「本番環境では」 |

**検証方法**: reviewer が claim した call site / 条件を Grep で検索し、**diff 適用後のコードベース全体** で実在しなければ `CONTRADICTED` として findings から除外する。検索範囲を diff 対象ファイルのみに限定すると新機能 PR が全て Hypothetical 降格するため、必ず全体検索とする。

**External Claim との関係**: Internal Likelihood Claim は External Claim と直交する。同一 finding が両方の性質を持つ場合（例: 「ライブラリ X は常に null を返す」）は両 Phase で検証し、どちらかで `CONTRADICTED` 判定されれば除外する。

---

## Verification Execution

Fact-Check Phase は以下 2 つのサブフェーズで構成される。Pipeline 順序 `Debate → Dedup → Fact-Check (5.1 + 5.2) → Spec Consistency → Assessment` は不変:

- **Phase 5.1**: External Claim Verification — 外部仕様の主張を公式ドキュメント（context7 / WebSearch / WebFetch）で検証
- **Phase 5.2**: Internal Likelihood Claim Verification — 内部実発生の主張を Grep で検証（`verify_internal_likelihood: true` の場合のみ）

両サブフェーズの結果は統合レポート (`### 外部仕様の検証結果` セクション) で同一テーブルに記録される。`CONTRADICTED` 判定は両サブフェーズ共通で finding を除外する。

### 5.1 External Claim Verification

外部仕様の主張を権威ある公式ドキュメントで検証する。External Claim が 0 件の場合はサブフェーズ自体をスキップ。

#### Method Priority

**When `review.fact_check.use_context7: true` (default):**

1. **context7** (`resolve-library-id` → `query-docs`) — ライブラリ/フレームワーク仕様の検証に最適。公式ドキュメントへの直接アクセスが可能
2. **WebSearch** — ツール設定、CLI 動作、バージョン情報、CVE、ベストプラクティス → 公式ドキュメントサイトでフィルタ
3. **WebFetch** — 公式ドキュメントの URL が判明している場合 → 直接取得

**When `review.fact_check.use_context7: false`:**

1. **WebSearch** — ツール設定、CLI 動作、バージョン情報、CVE、ベストプラクティス → 公式ドキュメントサイトでフィルタ
2. **WebFetch** — 公式ドキュメントの URL が判明している場合 → 直接取得

#### Verification Steps (per External claim)

各 External claim について以下の手順を実行:

**Step 1: 主張を1文で明確化する**

Finding の `内容` / `推奨対応` から外部仕様の主張を1文に要約する。

例: 「npm の ignore-scripts=true を設定すると、esbuild の postinstall スクリプトが実行されず、ビルドが壊れる」

**Step 2: 検証方法を選択する**

| 主張の種類 | use_context7: true | use_context7: false |
|-----------|-------------------|---------------------|
| ライブラリ/フレームワーク仕様 | context7 (`resolve-library-id` → `query-docs`) | WebSearch |
| ツール設定、CLI 動作 | WebSearch | WebSearch |
| バージョン情報、CVE | WebSearch | WebSearch |
| 公式 URL が既知 | WebFetch | WebFetch |

**context7 フォールバック**: `use_context7: true` で context7 を使用した場合、以下のケースでは WebSearch にフォールバックする:
- `resolve-library-id` でライブラリが見つからない
- `query-docs` でドキュメントが取得できない
- context7 ツール自体が利用不可（ネットワークエラー等）

**Step 3: 検証結果を判定する**

| 判定 | 条件 | 記録内容 |
|------|------|---------|
| ✅ VERIFIED | 公式ドキュメントが主張を裏付け | ソース URL |
| ❌ CONTRADICTED | 公式ドキュメントが主張と矛盾 | 正しい情報 + ソース URL |
| ⚠️ UNVERIFIED:ソース未確認 | 権威あるソースが見つからない | 注記（手動確認推奨） |
| UNVERIFIED:リソース超過 | max_claims を超過し検証未実施 | 注記（検証未実施） |

#### Verification Rules

- 1つの主張に対して**最低1つの公式ソース**を確認する
- ソース優先順位: 公式ドキュメント > ブログ記事 > Stack Overflow
- 矛盾が見つかった場合、**複数ソースでクロスチェック**する
- 検証に使った URL は必ず記録する

### 5.2 Internal Likelihood Claim Verification

reviewer が主張する「実発生」を Grep ベースで内部検証する。`verify_internal_likelihood: false` または Internal Likelihood Claim が 0 件の場合はサブフェーズをスキップ。

#### Verification Steps (per Internal Likelihood claim)

**Step 1: 主張から検証可能な要素を抽出する**

Finding の `内容` 列から以下を抽出:

- **call site の主張**: 「関数 X が Y から呼ばれる」 → 検索対象: `Y.*X\(|X\(` を呼び出し箇所で grep
- **発生条件の主張**: 「この関数は null を渡されることがある」 → 検索対象: 引数に `null` / `undefined` / 未初期化値を渡す呼び出し箇所
- **頻度主張**: 「通常フローで」「常に」「多くの場合」 → 検索対象: エントリポイント（CLI / HTTP handler / event handler 等）から当該コードへの到達経路

**Step 2: Grep で実在を検証する**

検索範囲は **diff 適用後のコードベース全体**（`git diff --name-only` で変更ファイルのみに限定しない）。新機能 PR で追加されたコードも対象とする:

```
# 例: claim = 「authMiddleware が API handler から呼ばれる」
Grep pattern: "authMiddleware\("
Glob scope:   "**/*.ts"
```

**Step 3: 検証結果を判定する**

| 判定 | 条件 | 記録内容 |
|------|------|---------|
| ✅ DEMONSTRABLE | Grep で call site / 発生条件を発見 | 発見箇所（file:line） |
| ❌ CONTRADICTED | Grep で該当パターンが皆無、かつ擬陽性/擬陰性ケースに該当しない | 検索した pattern + 結果 0 件の旨 |
| ⚠️ HYPOTHETICAL 降格 | Grep で見つからないが claim 自体は妥当（framework convention で接続など） | 注記（reviewer が接続経路を明示） |

#### 擬陽性/擬陰性の扱い

Dynamic dispatch / reflection / plugin loader 等、Grep で直接的な call site が見つからないケースの判定ルール:

| ケース | 扱い | 判定 |
|-------|------|------|
| Grep で call site 発見 | 直接的な呼び出しが実在 | ✅ DEMONSTRABLE |
| Grep で見つからない + エントリポイント接続あり (framework convention / hook / event bus / cron / webhook / CLI) | framework 規約による接続を reviewer が立証 | ✅ DEMONSTRABLE（reviewer 説明必須） |
| Grep で見つからない + エントリポイント接続なし | 実行経路が不明 | ⚠️ HYPOTHETICAL 降格 |
| Reflection / dynamic dispatch / plugin loader 経由 | reviewer が接続経路（どの registry・どの動的 import 等）を明示すれば実発生相当 | ✅ DEMONSTRABLE（reviewer 説明必須） |

> **Rationale**: 「call site 実在」の判定を Grep 完全一致のみに限定すると、Express の router registration、React の hooks、CLI framework の command dispatch 等、framework convention ベースの接続が全て Hypothetical に降格する。reviewer が接続経路を 1 文で説明できる場合は DEMONSTRABLE として扱う。説明がない場合は HYPOTHETICAL 降格。

#### Verification Rules

- Internal Likelihood Claim は `max_claims` 枠外でカウントする（Grep ベースのためコストが低い）
- reviewer が claim した call site / 条件を Grep で検索し、結果が 0 件なら `CONTRADICTED`（findings から除外）
- Grep で見つからない場合でも、擬陽性/擬陰性ケース表の DEMONSTRABLE 条件に該当すれば維持
- 該当しない場合は HYPOTHETICAL 降格（reviewer の確信度が低い旨を Report に記録）

---

## Finding Modification Rules

Fact-Checking Phase (5.1 + 5.2) の結果に基づき、findings を以下のルールで修正する。修正は Assessment（5.3）の**前**に完了する。External Claim (5.1) と Internal Likelihood Claim (5.2) は同一の Modification Rule に従う:

### VERIFIED (✅) / DEMONSTRABLE (✅)

- **`全指摘事項`**: finding を維持
  - External (5.1): `推奨対応` 列末尾にソース URL を付記（フォーマット: `{original_recommendation} ([source](URL))`）
  - Internal Likelihood (5.2): `推奨対応` 列末尾に発見箇所を付記（フォーマット: `{original_recommendation} (call site: {file:line})`）
- **`高信頼度の指摘`**: 変更なし（維持）
- **blocking**: 維持

### CONTRADICTED (❌)

- **`全指摘事項`**: finding を**除外**
- **`高信頼度の指摘`**: finding を**除外**
- **Report**: 専用セクション `### 矛盾により除外された指摘` に移動
  - External (5.1): 元の主張、公式ドキュメントの正しい情報、ソース URL
  - Internal Likelihood (5.2): 元の主張、検索した Grep pattern、結果 0 件の旨
- **blocking**: 解除（カウント対象外）

### UNVERIFIED:ソース未確認 (⚠️) / HYPOTHETICAL 降格 (⚠️)

- **`全指摘事項`**: finding を**除外**（blocking 解除）
- **`高信頼度の指摘`**: finding を**除外**
- **Report**: `### 外部仕様の検証結果` セクションに status ⚠️ で記録
  - External (5.1): 「手動確認推奨」
  - Internal Likelihood (5.2): 「call site 未立証。reviewer が接続経路を明示する必要あり」
- **blocking**: 解除（カウント対象外）

### UNVERIFIED:リソース超過（External のみ）

- **`全指摘事項`**: finding を**維持**（blocking 維持）
- **`高信頼度の指摘`**: 変更なし（維持）
- **Annotation**: `内容` 列に `[未検証:リソース超過]` プレフィックスを付加
- **blocking**: 維持

> **Note**: このケースは Phase 5.1 (External) のみで発生する。Phase 5.2 (Internal Likelihood) は `max_claims` 枠外であるためリソース超過は発生しない。

> **MUST NOT**: `max_claims` 超過を理由に正当な finding の blocking を解除してはならない。

---

## max_claims Handling

`max_claims` は **Phase 5.1 (External Claim) のみ** に適用される。Phase 5.2 (Internal Likelihood Claim) は Grep ベースで低コストのため枠外。

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

**Phase 5.1 (External Claim Verification):**

| エラー条件 | 動作 |
|-----------|------|
| context7 `resolve-library-id` でライブラリ未検出 | WebSearch にフォールバック |
| context7 `query-docs` でドキュメント未取得 | WebSearch にフォールバック |
| context7 ツールが利用不可 | WebSearch にフォールバック（警告なし） |
| WebSearch がタイムアウトまたはエラー | 該当 claim を `UNVERIFIED:ソース未確認` として扱い続行 |
| WebFetch がタイムアウトまたはエラー | WebSearch にフォールバック。それも失敗 → `UNVERIFIED:ソース未確認` |
| 全検証ツール利用不可（ネットワーク障害等） | Phase 5.1 全体をスキップし findings をそのまま維持（blocking 維持）。Phase 5.2 は独立に実行可能 |
| External claim 0件検出 | Phase 5.1 スキップ、Phase 5.2 へ進む |

**Phase 5.2 (Internal Likelihood Claim Verification):**

| エラー条件 | 動作 |
|-----------|------|
| Grep 実行エラー（検索対象ファイル不在等） | 該当 claim を `HYPOTHETICAL 降格` として扱い続行 |
| Internal Likelihood claim 0件検出 | Phase 5.2 スキップ、Spec Consistency に進む |
| `verify_internal_likelihood: false` | Phase 5.2 全体をスキップ、Phase 5.1 の結果のみで Spec Consistency に進む |

---

## Fact-Check Metrics

Phase 5.1 + 5.2 の完了後、Spec Consistency に進む前にインラインサマリーを出力する。このサマリーは Phase 間遷移時の中間確認用。Assessment Decision Time の最終出力は `assessment-rules.md` の `【外部仕様検証】` セクションを参照。

```
ファクトチェック完了:
[Phase 5.1] External Claim Verification
- 外部仕様の主張: {total_external} 件
- 検証済み (✅): {verified} 件
- 矛盾 (❌): {contradicted} 件
- 未検証:ソース未確認 (⚠️): {unverified_source} 件
- 未検証:リソース超過: {unverified_limit} 件

[Phase 5.2] Internal Likelihood Claim Verification
- 実発生の主張: {total_likelihood} 件
- 立証 (✅): {demonstrable} 件
- 矛盾 (❌): {likelihood_contradicted} 件
- HYPOTHETICAL 降格 (⚠️): {hypothetical} 件
```

**E2E output suffix** (fact-check が実行された場合のみ付加):

```
| fact-check: 5.1 {verified}✅ {contradicted}❌ {unverified}⚠️ | 5.2 {demonstrable}✅ {likelihood_contradicted}❌ {hypothetical}⚠️
```

ここで `{unverified}` = `{unverified_source}` + `{unverified_limit}` の合計。Phase 5.2 がスキップされた場合は 5.2 の部分を省略する。

---

## Report Sections

### `### 外部仕様の検証結果` セクション

External Claim (5.1) または Internal Likelihood Claim (5.2) のいずれかが 1件以上検出された場合に表示。両方とも 0件の場合はセクション自体を省略。**両サブフェーズの結果を同一テーブルに統合して記録する**（`種別` 列で識別）:

```markdown
### 外部仕様の検証結果

| 指摘 | 種別 | 主張 | 検証結果 | ソース／call site |
|------|------|------|---------|---------------------|
| {file:line} ({reviewer}) | External | {claim_summary} | ✅ 検証済み / ⚠️ 未検証 | [source](URL) |
| {file:line} ({reviewer}) | Internal Likelihood | {claim_summary} | ✅ 立証 / ⚠️ 降格 | {found_file:line} or "(未発見)" |

**ファクトチェック**: 5.1 {verified}✅ {contradicted}❌ {unverified}⚠️ / 5.2 {demonstrable}✅ {likelihood_contradicted}❌ {hypothetical}⚠️
```

**Note**: `UNVERIFIED:リソース超過` finding はこのテーブルに含めない。リソース超過 finding は `全指摘事項` に `[未検証:リソース超過]` アノテーション付きで残る（blocking 維持）。このテーブルは検証を実施した claim のみを記録する。Phase 5.2 がスキップされた場合は `種別` 列に External のみ記録される。

### `### 矛盾により除外された指摘` セクション

CONTRADICTED 指摘（Phase 5.1 または 5.2 由来）が 1件以上ある場合に表示。0件の場合はセクション自体を省略。**両サブフェーズの CONTRADICTED を同一テーブルで記録**:

```markdown
### 矛盾により除外された指摘

> このセクションの指摘は、公式ドキュメント（Phase 5.1）または Grep 検証（Phase 5.2）と矛盾しているため指摘事項から除外されました。

| 重要度 | ファイル:行 | 種別 | 当初の主張 | 矛盾の根拠 | ソース／Grep pattern |
|--------|------------|------|-----------|-----------|---------------------|
| {severity} | {file:line} | External | {original_claim} | {correct_info} | [source](URL) |
| {severity} | {file:line} | Internal Likelihood | {original_claim} | "Grep 結果 0 件" | `{grep_pattern}` |
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
