#### 5.1.3 Doc-Heavy PR Mode Post-Condition Check

**Execution condition**: `{doc_heavy_pr} == true` かつ tech-writer が reviewer 集合にいる。
**Skip condition**: `{doc_heavy_pr} == false` または tech-writer 不在なら ステップ 5.2 へ。
**Purpose**: 5 カテゴリ verification が実際に走ったかを post-condition で見る。
rationale: design-rationale.md#doc-heavy-post-condition-notes

**Verification steps**:

##### Step 1: tech-writer finding 0 件警告 (silent non-compliance 防止)

**前提**: **`finding_count == 0` のときだけ**発火する。
**判定** (`finding_count == 0` の AND): 次の **5 variant** が 1 つも無い:
 - **(a)** `META: All 5 verification categories executed, 0 inconsistencies found. Categories: [Implementation Coverage, Enumeration Completeness, UX Flow Accuracy, Order-Emphasis Consistency, Screenshot Presence]` (finding_count == 0 の正規 META 行)
 - **(b)** `META: All 5 verification categories executed. Findings below.` (finding_count >= 1 の正規 META 行 — 本 Step 1 の前提では `finding_count == 0` だが、tech-writer が誤って variant b を出力した場合でも「META 行は出ている」とみなして false positive を防ぐ)
 - **(c)** `META: Cross-Reference partially skipped` (外部参照スキップ、Step 4 で扱う)
 - **(a + inconclusive)** `META: All 5 verification categories executed, 0 inconsistencies found, but {N} categories were inconclusive. Inconclusive: [category_1, category_2, ...]. Categories: [Implementation Coverage, Enumeration Completeness, UX Flow Accuracy, Order-Emphasis Consistency, Screenshot Presence]` ([`internal-consistency.md`](.././references/internal-consistency.md#inconclusive-集計-と-meta-行への反映) で定義された inconclusive 集計版。Step 4.5 で扱う)
 - **(b + inconclusive)** `META: All 5 verification categories executed, but {N} categories were inconclusive. Inconclusive: [category_1, category_2, ...]. Findings below.` (同上、finding_count >= 1 の inconclusive 集計版)

上記 5 種すべて非該当の場合のみ、警告を発火する。5 variant のうちどれか 1 つでも含まれていれば「META 行は存在する」とみなし、Step 1 はスキップして Step 2 (variant の正規性 check) に処理を委ねる。 <!-- variant b / inconclusive variant を判定式に含める理由: references/design-rationale.md#doc-heavy-post-condition-notes -->
- **WARNING を必ず stderr に出力** (silent fall-through 禁止):
 ```
 WARNING: Doc-Heavy PR mode active, but tech-writer returned 0 findings without META confirmation.
 Expected: Either explicit "META: All 5 verification categories executed, 0 inconsistencies found" declaration, or "META: Cross-Reference partially skipped" notice for external-repo documentation.
 Action: Verify tech-writer executed the 5-category verification protocol from internal-consistency.md. Re-run with explicit Doc-Heavy mode instructions if needed.
 ```
- レビュー結果に `doc_heavy_post_condition: warning` フラグを set
- overall assessment を `修正必要` に変更 (silent pass 防止)


##### Step 2: META 5 カテゴリ実行確認 (件数非依存、silent non-compliance 防止)

**適用条件**: `finding_count` の値に関係なく **常に実施** する (`finding_count == 0` でも `finding_count >= 1` でも同じ)。
**照合方式の厳格性宣言** (silent fall-through 防止 — variant ごとに異なる照合方式を明示):
- **variant (a) / (a + inconclusive)**: `Categories: [...]` ブロック内のカテゴリ名を **literal substring match** で検査する。「`Implementation Coverage`」「`Enumeration Completeness`」「`UX Flow Accuracy`」「`Order-Emphasis Consistency`」「`Screenshot Presence`」の **5 つすべてが literal で含まれていること**を要求する。`Order / Emphasis Consistency` (空白付きスラッシュ) や `Order/Emphasis Consistency` (空白なしスラッシュ) のような表記揺れは literal substring match で**マッチしないため Step 2 が `passed` にならず**、`doc_heavy_post_condition: warning` 強制昇格の経路に流れる。
- **variant (b)**: 「`META: All 5 verification categories executed.`」「`Findings below.`」の 2 トークンを literal substring match で検査する (Categories list は variant (b) では出現しない)。
- **variant (c)**: 「`META: Cross-Reference partially skipped`」を literal substring match で検査する。
- **variant (b + inconclusive)**: variant (b) のトークン + 「`but {N} categories were inconclusive`」「`Inconclusive: [...]`」を literal substring match で検査する (`{N}` 部分は数字 1 文字以上を許容)。

**重要**: literal substring match は「カテゴリ名の空白/記号の差異を厳格に検出する」設計選択 (canonical form からの逸脱で即発火する)。 <!-- rationale: design-rationale.md#doc-heavy-post-condition-notes -->
tech-writer の出力に以下のいずれかの META 行が含まれているかを検証する。**正規表現は必ず multiline mode (`(?m)`) で実行**: `(?m)(?:^|<br\s*/?>|[\s|>(])\s*META:` を行頭 anchor として検索する (`(?m)` 無効だと `^` がファイル先頭のみを指し、段落形式の `- META: ...` が検出漏れになる。Step 4 の正規表現も同様):
- (a) `META: All 5 verification categories executed, 0 inconsistencies found. Categories: [Implementation Coverage, Enumeration Completeness, UX Flow Accuracy, Order-Emphasis Consistency, Screenshot Presence]` (finding_count == 0 の場合)
- (b) `META: All 5 verification categories executed. Findings below.` (finding_count >= 1 の場合)
- (c) `META: Cross-Reference partially skipped` (外部参照スキップ、Step 4 で扱う)
- (a + inconclusive) `META: All 5 verification categories executed, 0 inconsistencies found, but {N} categories were inconclusive. Inconclusive: [...]. Categories: [...]` ([`internal-consistency.md`](.././references/internal-consistency.md#inconclusive-集計-と-meta-行への反映) で定義された inconclusive 集計版、Step 4.5 で扱う)
- (b + inconclusive) `META: All 5 verification categories executed, but {N} categories were inconclusive. Inconclusive: [...]. Findings below.` (同上、finding_count >= 1 の inconclusive 集計版)

上記のいずれも含まれていない場合:
- **WARNING を必ず stderr に出力** (silent bypass 防止):
 ```
 WARNING: Doc-Heavy PR mode で tech-writer が META 5 カテゴリ実行確認行を出力していません。
 finding_count={count} ですが、以下のいずれかの META 行が見つかりません:
 (a) "META: All 5 verification categories executed, 0 inconsistencies found. Categories: [Implementation Coverage, Enumeration Completeness, UX Flow Accuracy, Order-Emphasis Consistency, Screenshot Presence]" (finding_count == 0 の場合)
 (b) "META: All 5 verification categories executed. Findings below." (finding_count >= 1 の場合)
 (c) "META: Cross-Reference partially skipped" (外部参照スキップの場合)
 (a + inconclusive) "META: All 5 verification categories executed, 0 inconsistencies found, but {N} categories were inconclusive. ..." (inconclusive 集計版)
 (b + inconclusive) "META: All 5 verification categories executed, but {N} categories were inconclusive. ..." (inconclusive 集計版)
 これは「1-4 カテゴリだけ実行して finding を捏造し post-condition check を silent bypass する」
 パターン (本 Phase の根本目的に反する) の可能性があります。
 Action: tech-writer を Doc-Heavy mode 指示を明示して再実行し、上記 5 種のいずれかを含む出力を得てください。
 ```
- レビュー結果に `doc_heavy_post_condition: warning` フラグを set
- overall assessment を `修正必要` に変更 (silent pass 防止)

**tech-writer prompt への反映**: ステップ 2.2.1 step 3 の reviewer prompt 注入時に、tech-writer に対して「finding 件数に関係なく META 行を出力せよ」を strict 要件として明示する。具体的には:
- finding_count == 0 → `META: All 5 verification categories executed, 0 inconsistencies found. Categories: [...]`
- finding_count >= 1 → `META: All 5 verification categories executed. Findings below.`
- 部分スキップ → `META: Cross-Reference partially skipped` (+ 詳細ブロック)

##### Step 3: Evidence field 必須化 (厳格検査 — Markdown テーブル対応)

- tech-writer の各 finding (CRITICAL/HIGH/MEDIUM/LOW-MEDIUM/LOW すべて) について、**`内容` カラム本文中**に Evidence 記述が含まれているかを正規表現で検査する。
- **重要 — Markdown テーブル構造への配慮**: Markdown テーブルのセル本文内では物理的な改行は許容されず、各 finding 行は 1 物理行として表現される (セル内改行は `<br>` または同一行内の区切り文字で表現)。そのため、Evidence 検出の正規表現は**行頭 anchor (`^`) に依存してはならない**。代わりに「行頭または直前が空白/区切り文字/`<br>`/`|`/`>`」を許容する anchor を使用する:
 - 正規表現 (multiline mode、行頭または直前が区切り文字、すべて non-capture group)。**`(?m)` flag は literal で必須** — Step 2 / Step 4 / Step 4.5 と syntax を統一し、デコードしない経路でも `^` anchor が各行先頭にマッチするようにする:
 ```
 (?m)(?:(?:^|<br\s*/?>|[\s|>(])\s*)-?\s*Evidence:\s*tool=<?(?:Grep|Read|Glob|WebFetch)>?
 ```
 - 補助: `<br>` が使われない場合でも、セル内の `- Evidence: tool=Grep, ...` 形式はテキスト先頭 (`^`) または空白/`|`/`(` 直後に出現するためマッチする
 - **non-capture group の理由**: 本検証ロジックは「Evidence 行が存在するか」のみを判定し、ツール名 (`Grep` / `Read` / `Glob` / `WebFetch`) の値を抽出して使う必要がない。[`internal-consistency.md`](.././references/internal-consistency.md#2-enumeration-completeness) の "Enumeration Completeness" → "Grep パターン例" セクション直下の注釈「すべて non-capture group `(?:...)` を使用し、キャプチャ番号のずれを防ぐ」と一貫させるため、すべて `(?:...)` で統一する (行番号参照は drift しやすいため section anchor で参照する)。
- **山括弧メタ記法の許容**: `tool=<?(?:Grep|Read|Glob|WebFetch)>?` により、reviewer が tech-writer-reviewer.md の example を literal に解釈して `tool=<Grep>` と書いた場合でもマッチする。これにより example ドキュメントのメタ記法との乖離による false positive を防ぐ。
- **評価方法**: 各 finding テーブル行の `内容` セルを `<br>` / `\n` でデコードしてから上記正規表現を適用することを推奨する。これにより、reviewer がセル内改行を `<br>` で表現した場合・単一行にまとめた場合の両方で一貫して検出できる。
- **注意**: reviewer 標準テンプレートの `ファイル:行` カラムは指摘対象の位置情報であり、検証の evidence とは別物。位置情報の存在のみをもって evidence ありと判定してはならない。
- **Evidence が欠落している finding を発見した場合**:
 - 該当 finding を **`evidence_missing`** としてマーク
 - レビュー全体の overall assessment を `修正必要` (要修正) に変更
 - レビュー結果に `evidence_missing_count: {N}` フラグと該当 finding 一覧を set
 - stderr に以下のエラーを出力:
 ```
 ERROR: Doc-Heavy PR mode で tech-writer が evidence なしの finding を返しました。
 内訳: {N} 件の finding に evidence 欠落
 - {file:line}: {content preview}
 これらは内容の真偽を検証できないため、tech-writer の再実行 (Doc-Heavy mode 指示を明示的に再送) が必要です。
 ```

##### Step 4: META Cross-Reference partially skipped 検出

- tech-writer の出力に正規表現 `(?m)(?:^|<br\s*/?>|[\s|>(])\s*META:\s*Cross-Reference partially skipped` にマッチする行が含まれている場合:
 - レビュー結果に `cross_reference_partial_skip: true` と外部リポジトリ情報 (META ブロック本文) を set
 - ステップ 5.4 (Integrated Report) の Doc-Heavy PR Mode 検証状態セクションに表示
 - ステップ 5.3 の overall assessment 判定時、ユーザーに明示的な acknowledgement を `AskUserQuestion` で求める
 - acknowledgement なしでマージ判定を下さない (`修正必要` 扱い)

##### Step 4.5: Inconclusive variant 検出 (`internal-consistency.md` 連携)

[`internal-consistency.md`](.././references/internal-consistency.md#inconclusive-verification-handling) は、Verification Protocol の各 step で `target_not_found` / `extraction_failed` / `tool_failure` のいずれかが発生した場合、reviewer が META 行を `(a + inconclusive)` / `(b + inconclusive)` 形式で出力することを義務付けている。本 Step は、これら inconclusive variant の検出と acknowledgement プロセスを発火させる責務を持つ:

- tech-writer の出力に以下の正規表現 (multiline mode) のいずれかがマッチする場合、`inconclusive_count` を抽出する:
 - `(?m)(?:^|<br\s*/?>|[\s|>(])\s*META:\s*All 5 verification categories executed,\s*0 inconsistencies found,\s*but\s*(\d+)\s*categor(?:y|ies)\s*were inconclusive` ((a + inconclusive) variant、`{N}` を group 1 で capture)
 - `(?m)(?:^|<br\s*/?>|[\s|>(])\s*META:\s*All 5 verification categories executed,\s*but\s*(\d+)\s*categor(?:y|ies)\s*were inconclusive` ((b + inconclusive) variant、同上)
- マッチした場合の処理:
 1. レビュー結果に `inconclusive_count: {N}` と inconclusive カテゴリ一覧 (`Inconclusive: [...]` の `[ ]` 内をパースして配列化) を `inconclusive_categories` flag に set
 2. **inconclusive_count >= 1 の場合**、ステップ 5.3 の overall assessment 判定時に Step 4 (Cross-Reference partial skip) と**同じ acknowledgement プロセス**を発火する: `AskUserQuestion` で「{N} 件の verification category が inconclusive ({carriers}) ですが、続行しますか?」を確認し、ユーザーが明示的に承認しない限り `修正必要` 扱いとする
 3. acknowledgement 取得後は `inconclusive_acknowledged: true` を retained flag に set し、ステップ 5.4 Integrated Report の Doc-Heavy PR Mode 検証状態セクションに inconclusive 件数とカテゴリを表示する
- マッチしない場合 (= inconclusive 報告なし) は Step 4.5 を no-op で完了する


本 check は ステップ 5.2 の **前**に実行する。
**Retained flags** (ステップ 5.4 template 表示用):
- `numstat_availability`: `"OK"` (success path) / `"unavailable"` (failure path) — ステップ 1.2.6 でいずれの path でも explicit set される
- `numstat_fallback_reason`: success path では `""` (空文字列)、failure path では numstat 失敗時のエラー 1 行要約 — ステップ 1.2.6 でいずれの path でも explicit set される
- `doc_heavy_pr_value`: `{doc_heavy_pr}` の boolean 値 (ステップ 1.2.7 で set)
- `doc_heavy_pr_decision_summary`: Doc-Heavy 判定根拠の 1 行要約 (例: `"doc_lines_ratio=0.72 >= 0.6"` / `"rite plugin self-only, excluded"`)
- `doc_heavy_post_condition`: `passed` / `warning` / `error`
- `doc_heavy_finding_count`: tech-writer の finding count
- `evidence_missing_count`: evidence 欠落 finding の数
- `evidence_missing_list`: 欠落 finding の file:line 一覧
- `cross_reference_partial_skip`: boolean (内部判定用)
- `cross_reference_skip_status`: `"なし"` / `"あり"` (ステップ 5.4 表示用 — `cross_reference_partial_skip` の boolean を日本語ラベルに変換した文字列。template 列対応統一のため `{cross_reference_skip_status}` placeholder で参照される)
- `cross_reference_skip_details`: META ブロック本文 (外部参照情報)
- `acknowledgement_status`: `"不要"` / `"取得済み"` / `"未取得"` (ステップ 5.4 表示用 — `cross_reference_partial_skip == false` のとき `"不要"`、`true` のときはユーザー応答に基づき `"取得済み"` または `"未取得"`。ステップ 5.1.3 で必ず explicit set される)
- `inconclusive_count`: int (Step 4.5 で `(a + inconclusive)` / `(b + inconclusive)` variant から抽出した inconclusive カテゴリ数。デフォルト `0`)
- `inconclusive_categories`: list[str] (inconclusive となった category 名一覧。例: `["Implementation Coverage", "Screenshot Presence"]`)
- `inconclusive_acknowledged`: boolean (ステップ 5.3 の `AskUserQuestion` でユーザーが明示的に承認したか。`inconclusive_count == 0` の場合は `null` または未設定)
- `verification_post_condition`: `"passed"` / `"warning"` / `"error"` (ステップ 5.1.1.1 で set される。`review_mode == "full"` のときは `"passed"` とみなす。ステップ 5.4 template の Doc-Heavy PR Mode 検証状態セクションと同型に表示用)
- `verification_post_condition_retry_count`: dict `{reviewer_type: int}` (ステップ 5.1.1.1 の per-reviewer retry counter。初期値は空 dict `{}`、各 reviewer に対して retry 1 回まで許可)

`doc_heavy_pr == false` でも 5.4 は `numstat_availability` と `doc_heavy_pr_value` を表示する。
