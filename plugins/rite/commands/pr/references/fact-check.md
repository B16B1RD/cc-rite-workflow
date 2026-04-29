# Fact-Check Phase Reference

> **Source**: Referenced from `review.md` Phase 5 Critic Phase (`#### Fact-Check Phase`, between Deduplication and Specification Consistency Verification). This file is the source of truth for fact-check rules.

## Overview

AI レビュアーが外部仕様（ライブラリ動作、ツール設定、バージョン互換性等）と内部実発生（call site / 頻度 / 到達経路）について行う主張を検証し、誤情報が PR コメントに永続化するリスクを排除する。

Fact-Check Phase は Critic Phase パイプラインの Deduplication と Specification Consistency Verification の間に位置する:

```
Debate → Dedup → Fact-Check (Sub-Phase A + B) → Spec Consistency → Assessment → Report
```

> **Sub-Phase 命名**: 本ファイル内の `Sub-Phase A` / `Sub-Phase B` は Fact-Check 内部の 2 段構成を示す独立 namespace であり、review.md 上位の Phase 5.1 Result Collection / Phase 5.2 Cross-Validation / Phase 5.2.1 Debate Phase とは別空間である。上位 Phase との混同を避けるため、本ファイルでは数字サブフェーズ番号（5.1 / 5.2 等）を使わず `Sub-Phase A` / `Sub-Phase B` で一貫表記する。

## Configuration

Read `review.fact_check` from `rite-config.yml`:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | boolean | `true` | ファクトチェック Phase の有効/無効 |
| `max_claims` | integer | `20` | 1レビューあたり最大 **External** claim 検証数（コスト制御）。Internal Likelihood Claim は Grep ベース検証のため枠外でカウントしない |
| `use_context7` | boolean | `true` | context7 MCP ツール（`resolve-library-id` / `query-docs`）による検証を使用。失敗時は既存 WebSearch fallback で自動回復 |
| `verify_internal_likelihood` | boolean | `true` | Internal Likelihood Claim の Grep ベース検証（Sub-Phase B）を有効化 |

**Skip conditions** (以下の (a) または (b) のいずれかが成立した場合に Phase 全体をスキップ、OR 条件):

- **(a)** `review.fact_check.enabled: false`
- **(b)** External claims = 0 **AND** (Internal Likelihood claims = 0 **OR** `verify_internal_likelihood: false`)

> **補足**: `verify_internal_likelihood: false` のとき「Internal Likelihood claim = 0」とみなされるため、External claim も 0 の場合は (b) が成立して Phase 全体スキップ。External claim が 1 件以上あれば Phase は実行され、内部的に Sub-Phase B のみスキップして Sub-Phase A のみ実行される。

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

**"要検証" マーカー**: `推奨対応` 列に "要検証" が含まれる場合は、レビュアーが外部仕様 **または Internal Likelihood** の確信度が低いことを明示的にシグナルしている。この finding は無条件で検証対象（External または Internal Likelihood）として分類する。また、max_claims 超過時の優先度ソートでは、"要検証" 付きの claim を同一 severity 内で優先する。

**統合レポートでの扱い**: External Claim / Internal Likelihood Claim の両検証結果は、統合レポート (`### 外部仕様の検証結果` セクション) の**同一テーブルに記録される**。区別が必要な情報は `種別` 列 (`External` / `Internal Likelihood`) で明示し、table parser 側が出典を識別できるようにする。

### Internal Likelihood Claims（検証必要・新規）

Finding の `内容` 列が「実発生」を主張する場合、Grep ベースで内部検証する。External Claim と直交する新カテゴリであり、`verify_internal_likelihood: true` の場合に Sub-Phase B で処理される:

| シグナル | 例 |
|---------|-----|
| 発生条件の存在主張 | 「この関数は null を渡されることがある」 |
| 頻度主張 | 「多くの場合」「通常フローで」「常に」 |
| 呼び出しパス主張 | 「X から Y が呼ばれる」 |
| 環境依存頻度 | 「Windows では」「本番環境では」 |

**検証方法**: reviewer が claim した call site / 条件を Grep + Read で検証し、下記 Sub-Phase B の 3 判定 (`DEMONSTRABLE` / `HYPOTHETICAL 降格` / `CONTRADICTED`) のいずれかに振り分ける。Grep 0 件は原則 `DEMONSTRABLE` (エントリポイント接続立証時) または `HYPOTHETICAL 降格` (立証なし時) に分類される。`CONTRADICTED` は「reviewer が明示した file:line の具体 claim が Grep + Read で **structurally 反証** できる場合のみ」の限定条件で適用される (例: reviewer が「42 行目で null を渡す」と主張したが Grep + Read で 42 行目が非 null リテラルだった)。

> **Rationale (検索範囲)**: 検索範囲を diff 対象ファイルのみに限定すると、新機能 PR の新規コードが既存コードへ統合される箇所が検出できず、reviewer の「実発生」主張を検証できない。よって diff 適用後のコードベース全体を検索対象とする。「コードベース全体で見つからない」ケースの判定は下記 Sub-Phase B の「擬陽性/擬陰性の扱い」表が single source of truth となる。

**External Claim との関係 (両 Sub-Phase 判定の優先順位)**: Internal Likelihood Claim は External Claim と直交する。同一 finding が両方の性質を持つ場合（例: 「ライブラリ X は常に null を返す」）は両 Sub-Phase で検証し、以下の優先順位で最終判定を決定する:

| Sub-Phase A 判定 | Sub-Phase B 判定 | 最終判定 |
|-----------------|------------------|----------|
| CONTRADICTED | （任意） | **CONTRADICTED** (除外) |
| （任意） | CONTRADICTED | **CONTRADICTED** (除外) |
| VERIFIED | DEMONSTRABLE | **VERIFIED** (採用、両立証ソースを `推奨対応` 列に付記) |
| VERIFIED | HYPOTHETICAL 降格 | **VERIFIED** 採用、External 起源で維持。`推奨対応` 列に "internal likelihood 立証なし" を注記 |
| UNVERIFIED:ソース未確認 | DEMONSTRABLE | **DEMONSTRABLE** (Internal Likelihood 側の立証を採用) |
| UNVERIFIED:ソース未確認 | HYPOTHETICAL 降格 | **HYPOTHETICAL 降格** (両方とも立証不成立) |
| それ以外の組合せ | — | A の判定を優先採用し、`推奨対応` 列に B 側の判定結果を注記 |

どちらか一方でも `CONTRADICTED` が出れば除外する。両立証が得られれば両ソースを記録、片方のみなら立証側の判定を採用し反対側は注記として残す。

---

## Verification Execution

Fact-Check Phase は以下 2 つのサブフェーズで構成される。Pipeline 順序 `Debate → Dedup → Fact-Check (Sub-Phase A + B) → Spec Consistency → Assessment` は不変:

- **Sub-Phase A**: External Claim Verification — 外部仕様の主張を公式ドキュメント（context7 / WebSearch / WebFetch）で検証
- **Sub-Phase B**: Internal Likelihood Claim Verification — 内部実発生の主張を Grep で検証（`verify_internal_likelihood: true` の場合のみ）

両サブフェーズの結果は統合レポート (`### 外部仕様の検証結果` セクション) で同一テーブルに記録される（`種別` 列で出典を明示）。`CONTRADICTED` 判定は両サブフェーズ共通で finding を除外する。

### Sub-Phase A: External Claim Verification

外部仕様の主張を権威ある公式ドキュメントで検証する。External Claim が 0 件の場合はサブフェーズ自体をスキップ。

#### Method Priority (External)

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

#### External Verification Rules

- 1つの主張に対して**最低1つの公式ソース**を確認する
- ソース優先順位: 公式ドキュメント > ブログ記事 > Stack Overflow
- 矛盾が見つかった場合、**複数ソースでクロスチェック**する
- 検証に使った URL は必ず記録する

### Sub-Phase B: Internal Likelihood Claim Verification

reviewer が主張する「実発生」を Grep ベースで内部検証する。`verify_internal_likelihood: false` または Internal Likelihood Claim が 0 件の場合はサブフェーズをスキップ。

#### Verification Steps (per Internal Likelihood claim)

**Step 1: 主張から検証可能な要素を抽出する**

Finding の `内容` 列から以下を抽出:

- **call site の主張**: 「関数 X が Y から呼ばれる」 → 検索対象: 関数 `X` の全呼び出し箇所（下記 Step 2 の 2 段階手順で検証）
- **発生条件の主張**: 「この関数は null を渡されることがある」 → 検索対象: 引数に `null` / `undefined` / 未初期化値を渡す呼び出し箇所
- **頻度主張**: 「通常フローで」「常に」「多くの場合」 → 検索対象: エントリポイント（CLI / HTTP handler / event handler 等）から当該コードへの到達経路

> **抽出契約**: 現状 reviewer 側に「Internal Likelihood claim の標準出力形式」の規約は未定義のため、Sub-Phase B Step 1 の抽出は `内容` / `推奨対応` 列からシグナル表（上記 Claim Classification の Internal Likelihood Claims 節）のキーワード全文検索により行う。reviewer 側の標準 prefix 規約（例: `Claim-Location:` / `Claim-Frequency:`）は Layer 4 以降の別 Issue で導入する想定。

**Step 2: Grep で実在を検証する（2 段階手順）**

検索範囲は **diff 適用後のコードベース全体**（`git diff --name-only` で変更ファイルのみに限定しない）。新機能 PR で追加されたコードも対象とする。

単一正規表現で「関数 X が Y の body 内で呼ばれる」のような呼び出し関係を判定しようとすると偽陽性（同一行内の別文脈での Y と X）や multi-line 跨ぎの検出漏れが発生する。そのため **Grep と Read の 2 段階手順** を使う:

- **(i)** Grep で全 call site を列挙: 対象関数名に `\(` を付けた pattern（例: `authMiddleware\(`）を `**/*.ts` 等の適切な glob で検索し、候補ファイル:行を列挙する
- **(ii)** Read で各候補の周辺コードを読み、claim の文脈（「Y から呼ばれる」「null が渡される」等）が成立しているかを判定する

```
# 例: claim = 「authMiddleware が API handler から呼ばれる」
Step (i) Grep pattern: "authMiddleware\("
         Glob scope:   "**/*.ts"
Step (ii) 各 file:line について Read で周辺コンテキストを読み、
          API handler 系ファイル (例: routes/ 配下、handler 接尾辞等) から呼ばれているかを判定
```

**Step 3: 検証結果を判定する**

Sub-Phase B の判定は以下の 3 値。Grep 0 件のケースは原則 `DEMONSTRABLE` (擬陽性/擬陰性の扱い表の DEMONSTRABLE 条件該当) または `HYPOTHETICAL 降格` (非該当) に振り分けられる。`CONTRADICTED` は **reviewer の具体 claim が structurally 反証** できる限定条件でのみ適用される:

| 判定 | 条件 | 記録内容 |
|------|------|---------|
| ✅ DEMONSTRABLE | Grep + Read で call site / 発生条件を発見、または Grep 0 件でも擬陽性/擬陰性の扱い表の DEMONSTRABLE 条件に該当 | 発見箇所（file:line） または 接続経路の立証文 |
| ❌ CONTRADICTED | reviewer が明示した file:line の具体 claim が Grep + Read で **structurally 反証** 可能な場合のみ（例: reviewer が「42 行目で null を渡す」と主張したが Grep + Read で 42 行目が非 null リテラルだった） | 反証の根拠（file:line の実内容）+ reviewer の元 claim |
| ⚠️ HYPOTHETICAL 降格 | Grep で見つからず、かつ擬陽性/擬陰性の扱い表の DEMONSTRABLE 条件にも該当しない（= エントリポイント接続が立証できない） | 注記（reviewer の接続経路説明が必須） |

> **判定順序**: (1) 先に「擬陽性/擬陰性の扱い」表を評価して `DEMONSTRABLE` / `HYPOTHETICAL 降格` を確定、(2) その後、reviewer の具体 claim が structurally 反証できるかを評価して該当すれば `CONTRADICTED` に上書き。単純な「Grep 0 件」は `CONTRADICTED` ではなく `HYPOTHETICAL 降格` に至る。これは dead-code (到達不能分岐) を防ぎ、Sub-Phase B 全体の判定網羅性を保証するため。

#### 擬陽性/擬陰性の扱い

Dynamic dispatch / reflection / plugin loader 等、Grep で直接的な call site が見つからないケースの判定ルール（Step 3 判定表より優先して適用される）:

| ケース | 扱い | 判定 |
|-------|------|------|
| Grep で call site 発見 | 直接的な呼び出しが実在 | ✅ DEMONSTRABLE |
| Grep で見つからない + エントリポイント接続あり (framework convention / hook / event bus / cron / webhook / CLI) | framework 規約による接続を reviewer が立証 | ✅ DEMONSTRABLE（reviewer 説明必須） |
| Grep で見つからない + エントリポイント接続なし | 実行経路が不明 | ⚠️ HYPOTHETICAL 降格 |
| Reflection / dynamic dispatch / plugin loader 経由 | reviewer が接続経路（どの registry・どの動的 import 等）を明示すれば実発生相当 | ✅ DEMONSTRABLE（reviewer 説明必須） |

> **Rationale**: 「call site 実在」の判定を Grep 完全一致のみに限定すると、Express の router registration、React の hooks、CLI framework の command dispatch 等、framework convention ベースの接続が全て Hypothetical に降格する。reviewer が接続経路を 1 文で説明できる場合は DEMONSTRABLE として扱う。説明がない場合は HYPOTHETICAL 降格。

#### Internal Likelihood Verification Rules

- Internal Likelihood Claim は `max_claims` 枠外でカウントする（Grep ベースのためコストが低い）
- Grep 0 件のケースは **CONTRADICTED ではなく** `DEMONSTRABLE` (擬陽性/擬陰性ケース表の DEMONSTRABLE 条件該当時) または `HYPOTHETICAL 降格` (非該当時) に分類される (Step 3 判定順序に従う)
- `CONTRADICTED` は **reviewer の具体 claim が Grep + Read で structurally 反証可能な場合のみ** 適用する (例: reviewer が「file:line で null を渡す」と主張したが Grep + Read で非 null リテラルだった)
- `HYPOTHETICAL 降格` は後述 Finding Modification Rules に従い「推奨事項」セクションへ移動する

---

## Finding Modification Rules

Fact-Check Phase (Sub-Phase A + B) の結果に基づき、findings を以下のルールで修正する。修正は Assessment（5.3）の**前**に完了する。External Claim (Sub-Phase A) と Internal Likelihood Claim (Sub-Phase B) は同一の Modification Rule に従う:

### VERIFIED (✅) / DEMONSTRABLE (✅)

- **`全指摘事項`**: finding を維持
  - External (Sub-Phase A): `推奨対応` 列末尾にソース URL を付記（フォーマット: `{original_recommendation} ([source](URL))`）
  - Internal Likelihood (Sub-Phase B): `推奨対応` 列末尾に発見箇所を付記（フォーマット: `{original_recommendation} (call site: {file:line})`）
- **`高信頼度の指摘`**: 変更なし（維持）
- **blocking**: 維持

### CONTRADICTED (❌)

- **`全指摘事項`**: finding を**除外**
- **`高信頼度の指摘`**: finding を**除外**
- **Report**: 専用セクション `### 矛盾により除外された指摘` に移動
  - External (Sub-Phase A): 元の主張、公式ドキュメントの正しい情報、ソース URL
  - Internal Likelihood (Sub-Phase B): 元の主張、structurally 反証した file:line の実内容、反証の根拠 (Grep + Read で確認した具体事実)
- **blocking**: 解除（カウント対象外）

### UNVERIFIED:ソース未確認 (⚠️)（External のみ）

- **`全指摘事項`**: finding を**除外**（blocking 解除）
- **`高信頼度の指摘`**: finding を**除外**
- **Report**: `### 外部仕様の検証結果` セクションに status ⚠️ で記録（注記「手動確認推奨」）
- **blocking**: 解除（カウント対象外）

### HYPOTHETICAL 降格 (⚠️)（Internal Likelihood のみ）

- **`全指摘事項`**: finding を**除外**（blocking 解除）
- **`推奨事項`**: finding を**推奨事項セクションへ移動**（`assessment-rules.md` の 5.3.0 Observed Likelihood Gate と同じ semantics）
  - `推奨対応` 列に注記「call site 未立証。reviewer が接続経路を明示する必要あり」を付記
- **Report**: `### 外部仕様の検証結果` セクションに status ⚠️ で記録（同上の注記）
- **blocking**: 解除（カウント対象外）

> **5.3.0 Observed Likelihood Gate との統一**: 本 Sub-Phase B の `HYPOTHETICAL 降格` は `assessment-rules.md` の 5.3.0 Observed Likelihood Gate と同じ「推奨事項セクションへ移動、blocking 解除」semantics を採用する。両層で `全指摘事項` から除外された finding が**完全消失するのを防ぎ**、reviewer の立証責任が果たされた後に再評価できるよう「推奨事項」として保持する。

### UNVERIFIED:リソース超過（External のみ）

- **`全指摘事項`**: finding を**維持**（blocking 維持）
- **`高信頼度の指摘`**: 変更なし（維持）
- **Annotation**: `内容` 列に `[未検証:リソース超過]` プレフィックスを付加
- **blocking**: 維持

> **Note**: このケースは Sub-Phase A (External) のみで発生する。Sub-Phase B (Internal Likelihood) は `max_claims` 枠外であるためリソース超過は発生しない。

> **MUST NOT**: `max_claims` 超過を理由に正当な finding の blocking を解除してはならない。

---

## max_claims Handling

`max_claims` は **Sub-Phase A (External Claim) のみ** に適用される。Sub-Phase B (Internal Likelihood Claim) は Grep ベースで低コストのため枠外。

外部 claim が `max_claims` を超過した場合:

1. 全 External claims を severity 順にソート（CRITICAL > HIGH > MEDIUM > LOW-MEDIUM > LOW）
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

**Sub-Phase A (External Claim Verification):**

| エラー条件 | 動作 |
|-----------|------|
| context7 `resolve-library-id` でライブラリ未検出 | WebSearch にフォールバック |
| context7 `query-docs` でドキュメント未取得 | WebSearch にフォールバック |
| context7 ツールが利用不可 | WebSearch にフォールバック（警告なし） |
| WebSearch がタイムアウトまたはエラー | 該当 claim を `UNVERIFIED:ソース未確認` として扱い続行 |
| WebFetch がタイムアウトまたはエラー | WebSearch にフォールバック。それも失敗 → `UNVERIFIED:ソース未確認` |
| 全検証ツール利用不可（ネットワーク障害等） | Sub-Phase A 全体をスキップし findings をそのまま維持（blocking 維持）。Sub-Phase B は独立に実行可能 |
| External claim 0件検出 | Sub-Phase A スキップ、Sub-Phase B へ進む |

**Sub-Phase B (Internal Likelihood Claim Verification):**

| エラー条件 | 動作 |
|-----------|------|
| Grep 実行エラー（検索対象ファイル不在等） | 該当 claim を `HYPOTHETICAL 降格` として扱い続行 |
| Internal Likelihood claim 0件検出 | Sub-Phase B スキップ、Spec Consistency に進む |
| `verify_internal_likelihood: false` | Sub-Phase B 全体をスキップ、Sub-Phase A の結果のみで Spec Consistency に進む |

---

## Fact-Check Metrics

Sub-Phase A + B の完了後、Spec Consistency に進む前にインラインサマリーを出力する。このサマリーは Phase 間遷移時の中間確認用。Assessment Decision Time の最終出力は `assessment-rules.md` の `【外部仕様検証】` セクションを参照。

```
ファクトチェック完了:
[Sub-Phase A] External Claim Verification
- 外部仕様の主張: {total_external} 件
- 検証済み (✅): {verified} 件
- 矛盾 (❌): {contradicted} 件
- 未検証:ソース未確認 (⚠️): {unverified_source} 件
- 未検証:リソース超過: {unverified_limit} 件

[Sub-Phase B] Internal Likelihood Claim Verification
- 実発生の主張: {total_likelihood} 件
- 立証 (✅): {demonstrable} 件
- 矛盾 (❌): {likelihood_contradicted} 件
- HYPOTHETICAL 降格 (⚠️): {hypothetical} 件
```

**E2E output suffix** (fact-check が実行された場合のみ付加):

```
| fact-check: A {verified}✅ {contradicted}❌ {unverified}⚠️ / B {demonstrable}✅ {likelihood_contradicted}❌ {hypothetical}⚠️
```

ここで `{unverified}` = `{unverified_source}` + `{unverified_limit}` の合計。Sub-Phase B がスキップされた場合は `/ B ...` の部分を省略する。Sub-Phase A / B の区切りは `/` を採用（上位 E2E output line が `|` を field separator として使うため衝突を回避）。

---

## Report Sections

### `### 外部仕様の検証結果` セクション

External Claim (Sub-Phase A) または Internal Likelihood Claim (Sub-Phase B) のいずれかが 1件以上検出された場合に表示。両方とも 0件の場合はセクション自体を省略。

> **セクション名について**: 歴史的経緯により名称は「外部仕様の検証結果」のままだが、本セクションは **両 Sub-Phase の検証結果** を統合して記録する (Internal Likelihood Claim の立証/降格も含む)。名称変更は caller 側 (review.md / assessment-rules.md) の同期が必要なため Layer 4 (親 Issue #502 の #4) で対応予定。本ファイルでは `種別` 列で sub-phase 出典を明示することで名称と内容の乖離を補う。

**両サブフェーズの結果を同一テーブルに統合して記録する**（`種別` 列で sub-phase 出典を明示）:

```markdown
### 外部仕様の検証結果

| 指摘 | 種別 | 主張 | 検証結果 | ソース／call site |
|------|------|------|---------|---------------------|
| {file:line} ({reviewer}) | External | {claim_summary} | ✅ 検証済み / ⚠️ 未検証 | [source](URL) |
| {file:line} ({reviewer}) | Internal Likelihood | {claim_summary} | ✅ 立証 / ⚠️ 降格 | {found_file:line} or "(未発見)" |

**ファクトチェック**: A {verified}✅ {contradicted}❌ {unverified}⚠️ / B {demonstrable}✅ {likelihood_contradicted}❌ {hypothetical}⚠️
```

**テーブルに含めるもの / 含めないもの**:
- **含める**: `VERIFIED` / `DEMONSTRABLE` / `UNVERIFIED:ソース未確認` / `HYPOTHETICAL 降格` のみ（検証を実施した claim）
- **含めない**: `CONTRADICTED` は別セクション `### 矛盾により除外された指摘` に移動するため本テーブルに含めない
- **含めない**: `UNVERIFIED:リソース超過` は `全指摘事項` に `[未検証:リソース超過]` アノテーション付きで残る（blocking 維持）。本テーブルには含めない

Sub-Phase B がスキップされた場合は `種別` 列に `External` のみ記録される。

### `### 矛盾により除外された指摘` セクション

CONTRADICTED 指摘（Sub-Phase A または B 由来）が 1件以上ある場合に表示。0件の場合はセクション自体を省略。**両サブフェーズの CONTRADICTED を同一テーブルで記録**:

```markdown
### 矛盾により除外された指摘

> このセクションの指摘は、公式ドキュメント（Sub-Phase A）または Grep 検証（Sub-Phase B）と矛盾しているため指摘事項から除外されました。

| 重要度 | ファイル:行 | 種別 | 当初の主張 | 矛盾の根拠 | ソース／Grep pattern |
|--------|------------|------|-----------|-----------|---------------------|
| {severity} | {file:line} | External | {original_claim} | {correct_info} | [source](URL) |
| {severity} | {file:line} | Internal Likelihood | {original_claim} | structurally 反証した file:line の実内容 | `{grep_pattern}` |
```

### Section Ordering in Report

両テンプレート（Full / Verification）共通:

```
### 高信頼度の指摘（複数レビュアー合意）
### 外部仕様の検証結果（該当がある場合のみ）    ← NEW
### 矛盾により除外された指摘（該当がある場合のみ）  ← NEW
### 全指摘事項
### 推奨事項                                  ← HYPOTHETICAL 降格 finding の destination
```

> **HYPOTHETICAL 降格 finding の 2 箇所記録**: Sub-Phase B で `HYPOTHETICAL 降格` と判定された finding は以下 **2 箇所に同時記録**される (5.3.0 Observed Likelihood Gate の destination + audit trail パターンを踏襲):
> 1. **`### 推奨事項` セクション** — destination (reviewer が接続経路を立証できれば後日再評価可能にするため保持)
> 2. **`### 外部仕様の検証結果` セクション** — audit trail (当該 finding が HYPOTHETICAL 降格判定を経由したことを検証履歴として記録、status ⚠️ で表示)

> **fix.md 互換性**: 新セクションは `### 全指摘事項` の**前**に配置。fix.md Phase 1.2.1 は `### 全指摘事項` を起点にパースするため影響なし。VERIFIED findings の `推奨対応` 列へのソース URL 付記は column 4 のテキストとして無害にパースされる。

> **caller 側 (review.md / assessment-rules.md) との同期**: 本ファイルは Fact-Check Phase の仕様書 (source of truth) であり、review.md `#### Fact-Check Phase` の実行手順および assessment-rules.md の `Fact-Check exclusion` / `【外部仕様検証】` 出力フォーマットは本ファイルの内容に追従する必要がある。caller 側の更新は Layer 4 (親 Issue #502 の #4) の対象であり、本ファイル (Layer 3) と意図的に PR を分離している。
