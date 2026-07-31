# Assessment Rules (Phase 5.3)

> **Charter**: Subject to [Simplification Charter](../../../skills/rite-workflow/references/simplification-charter.md). Runtime に効かない経緯記述は書かない。

> **Source**: Extracted from `pr-review.md` ステップ 5.3.1-5.3.7. This file is the source of truth for assessment rules.

## 5.3.0 Observed Likelihood Gate (Post-Reviewer Safety Net)

Before 5.3.1 Red blocking rule, apply the following **mechanical** demotion as a **safety net** for findings that escaped the reviewer-side Observed Likelihood Gate defined in [`_reviewer-base.md`](../../../agents/_reviewer-base.md#observed-likelihood-gate). This is a deterministic rule — AI judgment is NOT involved and is explicitly prohibited (see 5.3.7).

**Position in the gate chain**:

1. **Reviewer-side Gate** (primary): Each reviewer applies the [Impact × Observed Likelihood Matrix](../../../references/severity-levels.md#impact--observed-likelihood-matrix) at finding-emission time. Hypothetical findings are moved to the **推奨事項** section (not the 指摘事項 table) with a single, mechanical destination, and the reviewer records a `Likelihood-Evidence:` marker for every Demonstrable/Observed finding.
2. **Phase 5.3.0 safety net** (secondary): If a finding slipped into `全指摘事項` without a `Likelihood-Evidence:` marker (reviewer-side Gate was skipped or the reviewer forgot the marker), this Phase demotes the finding to **推奨事項** to match the matrix destination.

**Mechanical detection + demotion**:

```
For each finding in 全指摘事項:
  if reviewer_type in Hypothetical Exception Categories
     (= {security, devops, dependencies}; see severity-levels.md#hypothetical-exception-categories)
     or (reviewer_type == application
         and finding's 内容 column contains `Likelihood: Hypothetical (例外カテゴリ: database migration)`
         — application は Database migration 例外を migration 関連 finding に限り継承する):
    skip (severity 維持、例外カテゴリ)
  else:
    if finding's 内容 column lacks a `Likelihood-Evidence:` prefix line
       (machine-detectable anchor defined in _reviewer-base.md):
      if severity == LOW:
        remove from 全指摘事項
        (matrix rule: LOW × Hypothetical は報告禁止)
      else:
        move to 推奨事項 section
        (matrix rule: CRITICAL/HIGH/MEDIUM/LOW-MEDIUM × Hypothetical → 推奨事項へ 1 ステップ降格)
```

**"Missing `Likelihood-Evidence:` anchor"** means the finding's `内容` column does NOT contain a match for the following regex (per `_reviewer-base.md` "Demonstrable: proof of burden"):

```
(?m)(?:^|<br\s*/?>|[\s|>(])[-[:space:]]*Likelihood-Evidence:[[:space:]]*(existing_call_site|new_call_site|entrypoint_connection|runtime_observation)
```

**Anchor boundary semantics** (drift prevention vs `_reviewer-base.md` L127 placement rules):

- `(?m)` — multiline mode is **required**. Without it, `^` matches only at string start and the regex misses anchors placed after the WHAT/WHY narrative (which is the common case in `内容` columns).
- `(?:^|<br\s*/?>|[\s|>(])` — accepts four boundary variants: (a) physical line start `^`, (b) HTML `<br>` / `<br/>` / `<br />` separator (per `_reviewer-base.md` L127 "For Markdown table cells where physical newlines are not supported, use `<br>` as the separator"), (c) whitespace/tab (same-line continuation after WHAT+WHY narrative per `_reviewer-base.md` L127), (d) Markdown table cell boundary `|` / `>` / `(` (defense-in-depth).

This boundary set matches the canonical pattern used in `pr-review.md` ステップ 5.1.1.1 (`(?m)^### 修正検証結果\s*$`) and ステップ 5.1.3 Step 2 (`(?m)(?:^|<br\s*/?>|[\s|>(])\s*META:`). Updates to `_reviewer-base.md` L127 placement rules MUST be synchronized with this regex — the two are the single source of truth for anchor placement (authoring) and anchor detection (safety net).

Absence of any of these matches is the reviewer-side contract violation that Phase 5.3.0 corrects as safety net.

**Excluded reviewer types** (demotion skipped, severity preserved):

| Reviewer | Rationale |
|----------|-----------|
| `security` | Attack surface must be evaluated pre-exploitation; waiting for observed exploit is wrong |
| `application` (migration 関連 finding に限る — `Likelihood: Hypothetical (例外カテゴリ: database migration)` 表記を伴うもの) | Destructive DDL/DML cannot be "wait and see"。旧 `database` reviewer の Database migration 例外を統合先の `application` が migration finding に限り継承する |
| `devops` | Infra rollback/deploy paths failure leaves production broken |
| `dependencies` | Known CVEs and supply-chain risks are inherently "could happen any time" |

These categories inherit [Hypothetical Exception Categories](../../../references/severity-levels.md#hypothetical-exception-categories) (severity-levels.md の表は Database migration 例外の参照先を `application-reviewer.md` に更新済み)。Updates to the exception list MUST be synchronized across this section and `pr-review.md` ステップ 5.1 (Demoted findings collection)。

**Relation to 5.3.7 (AI independent judgment prohibition)**: The mechanical demotion in 5.3.0 is **explicitly permitted** because it follows a deterministic algorithm (regex match on `Likelihood-Evidence:` anchor + destination fixed by matrix) with no AI discretion. In contrast, 5.3.7 prohibits AI from applying severity exceptions based on its own judgment (e.g., "this CRITICAL is actually minor"). Mechanical rule = allowed; AI judgment = forbidden.

**Recording demoted findings**: Record each demoted finding in an `### Observed Likelihood 降格結果` section of the integrated report (ステップ 5.4) so the demotion is auditable. The full table schema is defined by the ステップ 5.4 template in `pr-review.md`; this section only specifies the columns:

```markdown
### Observed Likelihood 降格結果

| 元重要度 | 降格後 | ファイル:行 | 内容 | 降格理由 |
|---------|-------|------------|------|---------|
| HIGH | 推奨事項 | {file:line} | {description} | Likelihood-Evidence marker 未提示 (reviewer-side Gate skip) |
| LOW | （削除） | {file:line} | {description} | LOW × Hypothetical は報告禁止 |
```

**Expected firing frequency**: When reviewers correctly apply the reviewer-side Gate, Phase 5.3.0 SHOULD fire zero times (all findings carry `Likelihood-Evidence:` markers). Non-zero firings indicate reviewer-side contract violations that warrant investigation via Wiki Ingest or reviewer training.

## 5.3.0.M 実測必須ゲート (Measured CONFIRMED Gate)

5.3.0 の後・5.3.1 の前に適用する **mechanical** な分類ゲート (Issue #2024)。ゲート定義の SoT は [severity-levels.md §実測必須ゲート](../../../references/severity-levels.md#実測必須ゲート-measured-confirmed-gate)。5.3.0 と同じく deterministic rule であり、AI judgment は関与しない (5.3.7 の禁止対象外 — mechanical rule = allowed)。

**実行主体は `scripts/review-measured-gate.sh`** (Issue #2072)。本節の疑似コード・regex・WARNING 発火条件は helper の実装契約を定義する SoT であり、**LLM が手で適用する手順ではない**。`/rite:pr-review` ステップ 5.3.0.M は helper を 1 回呼び、その `[CONTEXT] MEASURED_GATE=` marker と書き換え後 JSON を 5.3.1 以降の入力にする。helper が非ゼロ終了した場合、caller は LLM 分類へ fallback せず `[review:error]` で停止する — fallback は本ゲートが閉じた不発 (PR #2070 で 9 サイクル分類が一度も実行されなかった事象) の再生産になる。

**Mechanical detection + demotion**:

```
For each finding in 全指摘事項 (post-5.3.0) where scope ∈ {current-pr, follow-up}:
  # verification.measured が boolean で既に入っている場合は既存値を正とし、description の
  # アンカー判定で上書きしない (矛盾は WARNING で surface する)。`verification: {}` /
  # `measured: null` は read 側型ガードが受理する「未判定」形であり、既存値とはみなさず算出する。
  # 本則は再実行の冪等性のためにあり、write 側が verification を先に書くことを許す趣旨ではない
  # (pr-review ステップ 5.3.0.M step 1 の生成規約が「verification は書かない」を課している)。
  # match subject は当該 finding の **内容セルの文字列単体** (行全体でも表全体でもない)。
  # 後続セル・次行・次 finding の文字は subject に含めない。
  if finding's 内容 column matches the full Anchor detection regex below
     (`Verification: repro|failing_test <LHS> => <RHS>`、_reviewer-base.md §Verification: runtime 実測の添付 で定義。
      LHS/RHS とも cell separator `|` と `<br>` を跨がず、RHS は非空):
    keep (measured=true、blocking 候補として 5.3.1 以降へ)
  else:
    move to non_blocking_findings
    (severity / scope は維持したまま blocking 集合から除外。破棄しない)
```

> 疑似コードのループ条件に `where scope ∈ {current-pr, follow-up}` を明示するのは、本節が
> `pr-review/SKILL.md` ステップ 5.3 実行順 step 2 から「集合演算の SoT」として参照されるため。
> nit-noted 除外は散文 (下記「scope=nit-noted との関係」) と helper `scripts/review-measured-gate.sh`
> の `gated` 述語 (`scope_effective` が `current-pr` / `follow-up` のときだけ真) にも現れるが、
> SoT の疑似コード単独で三者整合が読み取れる状態を保つ。

**WARNING emit (AC-5 主経路)**: **gate 対象 scope (`current-pr` / `follow-up`) の finding のうち、`Verification:` アンカー文字列は存在するのに full regex が no-match だったもの全て**を、正常系 (アンカー文字列そのものが無い = 非実測指摘) とは区別して stderr に WARNING で報告する。発火条件を「`=>` 右辺空」だけに絞ってはならない — **raw `|` を含む repro も、アンカー直前の境界を欠いた repro も no-match で降格される**ため、絞ると「実測済みの指摘が無音で non-blocking に落ちる」という silent failure が検出層自身に残る (本リポジトリは bash/jq 中心で repro にパイプが入るのが常態)。

母集団を gate 対象 scope に限るのは、`nit-noted` が `gated` 偽で**降格され得ない**ため。含めると「降格していないものを降格と申告する」ことになり、WARNING の件数が実際の降格件数と食い違う。

**集約的な hard fail は持たない**: 「blocking 候補が全件形式崩れなら停止する」形の hard fail は一度導入したが撤去した。判定に使える量 (`anchor_unparseable`) は stage 1 の意図的に緩い存在判定に由来し、上記トレードオフのとおり散文中の `Verification:` を拾う。その件数を停止条件へ昇格させると、(a) 正常な指摘集合で停止する誤発火と、(b) 形式崩れ以外の降格が混ざったときに素通りする見逃しを同時に持ち、条件をどちらへ寄せても片方が残る。**本筋の是正は「形式崩れアンカーを `measured=false` ではなく未判定 (= blocking のまま) として扱う」という per-finding の変更**だが、これは 3 値モデル (severity-levels.md §適用範囲) への設計変更なので別 Issue で扱う。現状は WARNING + `MEASURED_DEMOTED_ON_ANCHOR` marker による可視化に留める。

判定は 2 段で機械的に書ける:

1. `(?i)verification[*_`[:space:]]*[:：]` の**存在**判定 — **marker を正規化して拾う**。種別キーワード (`repro` / `failing_test`) を条件に含めず、colon 直後の空白も要求せず、**装飾文字 (`*` / `_` / バッククォート) と全角コロン `：` を吸収する**
2. 上記 **Anchor detection regex** の full match 判定

(1) が真かつ (2) が偽の finding が対象。

> **stage 1 は「列挙」ではなく「正規化」で書く**: `Verification:[[:space:]]*(repro|failing_test)` のようにラベル値まで一致を要求したり、`\*{0,2}` のように**特定の装飾だけを列挙**すると、列挙から漏れた形 (バッククォート `` `Verification`: ``、全角コロン `Verification：`、三重アスタリスク `***Verification***:`、underscore `_Verification_:`、種別欠落 `Verification: bash x.sh => ERROR`、ラベル取り違え `Verification: runtime_observation ...` — 隣接する `Likelihood-Evidence:` の正規ラベルとの混線で構造的に起きる) が stage 1 と stage 2 の**両方**から外れ、**WARNING ゼロで non-blocking に落ちる**。これは本節が閉じたと宣言している silent failure そのもの。装飾を 1 つ足すたびに regex を直す設計にせず、装飾文字クラスと全角コロンを吸収する形にする。トレードオフは「散文中の `verification :` 等を拾う無害な false-positive WARNING が増える」対「silent false-negative が残る」で、検出層としては前者を選ぶ。対象が 1 件以上なら `review-measured-gate.sh` が以下を emit する (helper の実装契約であり、省略は許されない):

```bash
echo "WARNING: Verification: アンカーはあるが検出 regex に match しない finding {n} 件を検出しました (raw pipe / 改行タグ / => 右辺空 / 種別ラベル誤記 (repro|failing_test 以外) / アンカー直前の境界欠落)。アンカーの直前は行頭・改行タグ・空白のいずれかにし、パイプを含むコマンドは ¦ で代替表記してください" >&2
echo "[CONTEXT] MEASURED_DEMOTED_ON_ANCHOR=1; count={n}; cause=anchor_unparseable" >&2
```

アンカー文字列がそもそも存在しない finding (非実測指摘の正常系) は WARNING を出さない — 全 non-blocking 降格で WARNING を出すと形式違反と正常系が区別できなくなるため。`MEASURED_DEMOTED_ON_ANCHOR` は `pr-review/SKILL.md` ステップ 6 の **Retained flag mapping に登録済み** (1 箇所)。同節の reason 表 / Eval-order enumeration は `*_FAILED` reason 専用の列挙であり、observability marker である本 flag は登録対象ではない。

> **降格を緩めない**: no-match を許容して keep する / regex を greedy に戻す方向の修正は採らない。降格自体は fail-safe として正しく (誤って blocking を落とすより安全)、問題は**無音であること**のみ。
>
> **この permissive 例外は上記 WARNING emit と記録先 4 経路が機能していることが前提**: 本ゲートは rite 全体で唯一「判定不能を permissive 側 (non-blocking) に倒す」箇所で、それが許されるのは (a) 降格が必ず WARNING で報告され、(b) 降格した指摘が **永続 JSON (`non_blocking_findings[]`) に必ず残り、ステップ 6.1.d の PR 記録コメントに best-effort で残る**ため (後者は非ブロッキング契約により gh 失敗 / 本文不備で落ちうる。落ちた場合は WARNING と `outcome=failed` が出る)。5.4 section と E2E output line suffix は補助経路で、実行モード (standalone は ステップ 8 を実行しない) と件数 (0 件なら省略) に依存する。後続の変更で (a) か (b) を緩めるなら、本例外の前提が崩れるので同時に見直すこと。blocking 側に倒す修正は AC-2 の収束性を壊す (`/rite:fix` はコードを直す機構でありレビュアー出力の形式崩れは直せず、`max_review_cycles` まで空転する) ため採らない。

**Anchor detection regex** (5.3.0 の `Likelihood-Evidence:` regex と同じ boundary semantics):

```
(?m)(?:^|<br\s*/?>|[\s|>(])[-[:space:]]*Verification:[[:space:]]*(repro|failing_test)[[:space:]]+(?:(?!=>|<br)[^|])+=>[ \t]*(?!<br)[^|[:space:]]
```

**match subject は疑似コードと同じく `内容` セルの文字列単体**であり、後続セル・次行を含めない (subject 定義がずれると同じアンカーが配置次第で逆判定になる)。LHS (`=>` 左辺のコマンド) と RHS (右辺の結果) はいずれも**アンカー自身の最初の `=>` に束縛**され、cell separator `|` と `<br>` を跨いでマッチしない — greedy `.*` 形だと markdown テーブル行内 (アンカーの標準配置 = `内容` セル末尾) で `=>` 右辺空アンカーが後続セルの文字に `\S` マッチして false-pass し、右辺空検出 (本 regex 層の単独責務) が dead 化するため。`=>` 直後を `[ \t]*` (水平空白のみ) に狭めているのも同じ理由で、subject を誤って行/レポート単位に取った場合でも RHS 検査が改行を跨がず、`=>` 右辺空アンカーが次行の文字を RHS と誤認して false-pass することを防ぐ (二重の防御)。この束縛の帰結として、アンカーの LHS/RHS には raw `|` を含めない (テーブルセル内ではどのみち表構造を壊す。パイプを含むコマンドは `¦` 等で代替表記する)。**この制約は authoring 側 SoT (`_reviewer-base.md` §Verification の Rules / `reviewer-prompt-generator.md` の記入例) にも明記済み** — detection 側にだけ書くと、reviewer が最も自然に書くパイプ入り repro が no-match で降格する。マッチしない場合は安全側 (non-blocking 降格) に倒れるが、**無音では倒れない** — アンカー文字列があるのに no-match だったケースは上記 **WARNING emit** 節の 2 段判定で必ず報告される (正常系 = アンカー文字列なし のみが無音)。

**non_blocking_findings の扱い**:

- `total_findings` にカウントしない (mergeable countdown から除外)
- finding の `id` (`F-NN`) は降格時に**振り直さず元の値を維持する** — `findings[]` と `non_blocking_findings[]` の**和集合で一意**になり、永続 JSON 単体を読む人間が 2 配列を跨いで finding を一意に参照できる (5.4 統合レポートのテーブルは `id` 列を持たないため、JSON ↔ レポート間の相互参照を目的とした規則ではない)。強制層は `hooks/review-result-save.sh` の id 検証 (本配列側の違反は非ブロッキング marker `NON_BLOCKING_FINDINGS_ID_UNION_VIOLATION` で報告され、保存は続行する)
- 記録先は 4 経路すべてで、破棄経路は存在しない:
  1. **永続 JSON** (`.rite/review-results/*.json` の トップレベル `non_blocking_findings[]`、`pr-review/SKILL.md` ステップ 6.1.a) — 既定構成 (`pr_review.post_comment: false`) におけるローカル側の永続チャネル
  2. **ステップ 6.1.d の PR 記録コメント** (`## 📜 rite 非実測指摘の記録`、`pr_review.post_comment` に**依存しない**。通常は cycle ごとに同じコメントを update-in-place するが、helper が自分の過去投稿を特定できない場合は縮退する — 本 cycle の指摘が 1 件以上なら新規作成となり 2 件目が並び、0 件なら投稿自体を省くため前 cycle の記録が stale で残る) — `.rite/review-results/` は gitignore 対象のため、レビュアーと共有できる永続チャネルはこちらのみ。両者あわせてマージ後に人間が拾い直せる状態を担保する
  3. **ステップ 5.4 統合レポート** の `### 実測なし指摘 (non-blocking)` section (severity 明示) — E2E でも省略禁止 (`pr-review/SKILL.md` E2E Output Minimization 表の例外)
  4. **E2E output line** の `| non-blocking: {n}` suffix (件数のみ、`n > 0` のとき)
- fix サイクルは起動しない (fix.md 側の除外分岐は [fix-relaxation-rules.md](./fix-relaxation-rules.md) §Fix Target Classification 参照)

**scope=nit-noted との関係**: nit-noted は従来どおり §5.3.1 の nit-noted exclusion で扱い、本ゲートの対象にしない (二重計上防止)。本ゲートの対象は `scope ∈ {current-pr, follow-up}` の finding のみ。

**指摘ゼロの場合**: `全指摘事項` が空なら本ゲートは no-op であり、mergeable 判定は現行と同一 (AC-3 非退行)。

## 5.3.1 Assessment Rules

**Red blocking rule: If even 1 finding with `scope ∈ {current-pr, follow-up}` and measured=true exists (after 5.3.0 / 5.3.0.M demotion), it MUST NOT be assessed as "Merge OK"**

All findings (CRITICAL/HIGH/MEDIUM/LOW-MEDIUM/LOW) with `scope ∈ {current-pr, follow-up}` remaining in `全指摘事項` after 5.3.0 **and 5.3.0.M (実測必須ゲート)** demotion are always blocking regardless of loop count. There is no gradual relaxation — every remaining blocking finding must be resolved before merge. 実測 (repro / failing_test) を伴わない finding は 5.3.0.M で `non_blocking_findings` に分類済みのため本 rule の対象に残らない — blocking = 「runtime 実測を伴う CONFIRMED 指摘」のみであり、「指摘ゼロ」は到達可能な終了条件になる (Issue #2024)。

**scope=nit-noted exclusion**: Findings with `scope == "nit-noted"` (`acknowledged` トラックの informational 情報共有) are **excluded from `overall_assessment`** and **excluded from the mergeable countdown**. They are surfaced via two separate paths: (a) `/rite:pr-review` ステップ 5.4 「指摘事項」表の **scope 列** (pr-review.md ステップ 5.4 Integrated Report の `全指摘事項` 表で scope=nit-noted 行として可視化)、および (b) `/rite:fix` ステップ 1.4 display の独立した「nit (認知のみ) ({nit_noted_count}件)」セクション (fix.md 内のサブセクション、修正対象外と明示)。両者は表示先が異なるが scope=nit-noted という意味は共通で、いずれも merge を block しない。 The `/rite:fix` ステップ 2.4 `nit-noted-reply` サブステップで「nit、認知済」reply を投稿することで decay-track され、ステップ 4.6 サマリでは `acknowledged_nit_count` として独立カウントされる。これは fix commit 対象からも完全除外される。schema invariant #4 (CRITICAL/HIGH × nit-noted FAIL) により blocker 級の指摘を nit に降格する経路は禁止されているため、本除外は安全に運用できる。詳細な fix loop 経路は [`fix-relaxation-rules.md`](./fix-relaxation-rules.md) §Fix Target Classification を参照。

**Fact-Check exclusion**: When `review.fact_check.enabled: true`, CONTRADICTED (❌) findings and UNVERIFIED:ソース未確認 (⚠️) findings are removed from `全指摘事項` by the Fact-Checking Phase before assessment. Only findings remaining in `全指摘事項` after fact-checking are counted in `total_findings`. UNVERIFIED:リソース超過 findings remain in `全指摘事項` with `[未検証:リソース超過]` annotation and are counted (blocking maintained).

**Pre-existing issue handling**: Pre-existing issues (problems that existed before the current PR's changes, confirmed via revert test) are excluded from findings entirely by the reviewer's scope judgment rule. They are NOT collected as a separate report section and NOT auto-Issue-ified. If a reviewer wants to surface a pre-existing concern, it goes into the "調査推奨" section of the integrated report (Phase 5) — the user may optionally run `/rite:investigate {file}` separately (non-blocking, not counted in `total_findings`).

When executed standalone (outside a loop), the same rules apply: scope ∈ {current-pr, follow-up} findings are blocking, scope=nit-noted findings are excluded from blocking countdown.

## 5.3.3 Assessment Logic

Use **only findings remaining in the post-5.3.0.M `全指摘事項` with `scope ∈ {current-pr, follow-up}`** for determination (nit-noted findings are excluded per §5.3.1 nit-noted exclusion; non-measured findings are excluded per §5.3.0.M 実測必須ゲート)。Priority: CRITICAL findings → Requires fixes | HIGH/MEDIUM/LOW-MEDIUM/LOW findings → Cannot merge (blocking findings exist) | 0 blocking findings (nit-noted / non-measured のみ残存可) → Merge OK.

**`total_findings` definition**: `total_findings = |post-5.3.0.M の 全指摘事項 ∩ {scope ∈ {current-pr, follow-up}}|` — すなわち §5.3.0.M の `Verification:` アンカー検出で measured=true と判定され `全指摘事項` に残った finding の件数。

> **判定媒体に注意**: `/rite:pr-review` ステップ 5.3.0.M step 1 でレビュー結果 JSON が生成され、step 2 の `review-measured-gate.sh` が `findings[].verification.measured` を設定する (Issue #2072 で配線。ステップ 6.1.a はこのファイルを**保存するだけ**で再生成しない)。したがって 5.3.3 が評価する集合は「helper がゲート適用後の JSON に残した `findings[]` ∩ `scope ∈ {current-pr, follow-up}`」であり、その件数は helper の `[CONTEXT] MEASURED_GATE=...; blocking=` が報告する。**Claude が `内容` 列やアンカーを読み直して数え直すことは禁止** — 分類を機械層に閉じた意味が失われる。`/rite:fix` ステップ 1.3 の measured lookup は同じフィールドを次サイクルで読む read 側であり、両者は同一の JSON 表現を共有する。

`acknowledged_nit_count = count(findings where scope == "nit-noted")` は独立 metric で `overall_assessment` 評価には使われない (Phase 4.6 サマリ表示のみ)。`non_blocking_count = count(non_blocking_findings)` (5.3.0.M で分類) も独立 metric で、5.3.5 サマリと 5.4 統合レポートの `### 実測なし指摘 (non-blocking)` section に使う (`overall_assessment` 評価には使われない)。**本定義は `/rite:pr-review` 側の変数**であり、`/rite:fix` ステップ 4.6 の同名 placeholder は母集団も値も異なる別定義 (`measured_map` の false のうち nit-noted を除く件数 — fix/SKILL.md ステップ 1.2.1 step 6 が SoT。JSON 経路では常に 0)。`total_findings` と同じく **pr-review 側と fix 側で別概念**として扱うこと。

## 5.3.5 Output Format at Assessment Decision Time

When determining the assessment, explicitly output the finding count in the following format:

本ブロックの **severity 別件数は post-5.3.0.M の blocking 集合**を数える (非実測指摘は下段の【実測必須ゲート】ブロック側で数えるため、severity 別の総和 = `合計` = `実測あり (blocking)` が常に成立する)。

```
【指摘件数サマリー】
- CRITICAL: {count} 件
- HIGH: {count} 件
- MEDIUM: {count} 件
- LOW-MEDIUM: {count} 件
- LOW: {count} 件
- 合計: {total} 件（すべて blocking = 実測あり）

【実測必須ゲート】
- 実測あり (blocking): {total} 件
- 実測なし (non-blocking、ステップ 5.4 に記録): {non_blocking_count} 件

【評価判定】
- 指摘件数: {total} 件
- 優先度 {n} に該当: {条件の説明}
- 総合評価: {マージ可 / マージ不可（指摘あり） / 修正必要}
```

**【実測必須ゲート】の省略規則**: `non_blocking_count == 0` かつ `total == 0` (指摘ゼロ) の場合は【実測必須ゲート】ブロック自体を**省略する** (MUST — permissive な裁量を残さない。AC-3: 指摘ゼロ経路の出力を現行と同一に保つ)。いずれかが 1 件以上なら必ず出力する。

**Additional output when fact-check was executed:**

When `review.fact_check.enabled: true` and external claims > 0, output the following in addition to the above:

```
【外部仕様検証】
- 外部仕様の主張: {total_external} 件
- 検証済み (✅): {verified} 件
- 矛盾 (❌): {contradicted} 件（指摘から除外済み）
- 未検証:ソース未確認 (⚠️): {unverified_source} 件（指摘から除外済み）
- 未検証:リソース超過: {unverified_limit} 件（blocking 維持）
```

**Additional output for verification mode:**

When `review_mode == "verification"`, output the following in addition to the above:

```
【検証モード情報】
- レビューモード: 検証 (verification)
- 前回レビュー commit: {last_reviewed_commit}
- 修正検証: FIXED {fixed} / NOT_FIXED {not_fixed} / PARTIAL {partial}
- リグレッション: {regression_count} 件
```

**Important**: Any **blocking** findings (§5.3.0.M のアンカー検出で measured=true と判定され `全指摘事項` に残ったもの × `scope ∈ {current-pr, follow-up}`) → cannot merge → `/rite:iterate` loop continues. "Merge OK" = 0 blocking findings (nit-noted / non-measured のみの残存は許容 — §5.3.3 と同一定義)。

## 5.3.6 Return Values to Caller (Important)

Return: total_findings (if >0, `/rite:fix` required), evaluation, review_mode.

**Red important constraint:**

The caller (`/rite:iterate` review-fix loop) **mechanically** invokes `/rite:fix` when `total_findings > 0` (= sentinel `[review:fix-needed:{n}]`), **regardless of AI judgment**. `evaluation` は人間可読ラベルであり caller の起動条件ではない — 両者が乖離するケース (下記) では `total_findings` が単独で routing を確定させる。

**Routing の単一 SoT は sentinel (= `total_findings`)**: 上記 2 条件は通常同時に動くが、実測必須ゲート導入後は乖離しうる — verification post-condition escalation (`pr-review/SKILL.md` ステップ 5.1.1.1 Failure Procedure) が `evaluation` を `修正必要` に昇格させても、当該 reviewer の指摘が全て非実測なら `total_findings == 0` になる。この乖離時は **`total_findings` が routing を確定させ** `[review:mergeable]` を出力する (`[review:fix-needed:0]` への override は禁止 — `pr-review/SKILL.md` ステップ 8.1 の同注記が SoT)。`evaluation` は人間可読ラベルとして統合レポートに残り、escalation の効力は ステップ 5.1.1.1 step 4 の ERROR 出力と ステップ 5.4 の `### 実測なし指摘 (non-blocking)` section が担う。override すると fix が対象 0 件で完了し、次 cycle も同状態のまま `safety.max_review_cycles` まで空転する。

The following decisions MUST NOT be made by `/rite:pr-review`:
- "The findings are minor, so no action is needed"
- Independently modifying assessment rules

`/rite:pr-review` is responsible only for accurately reporting the assessment results.

## 5.3.7 Prohibition of Independent Judgment After Assessment

> **It is prohibited for the AI to override the assessment logic (5.3.3) results.**

Prohibited actions: Exception handling by severity (e.g., "Only LOWs, so minor"), overriding assessment (e.g., "Effectively merge-OK"), inserting user confirmation.

> **[READ-ONLY RULE]**: 評価結果に基づいてコードを直接修正することは禁止されています。`Edit`/`Write` ツールでプロジェクトのソースファイルを変更してはなりません。ブロック指摘が存在する場合は `[review:fix-needed:{n}]` パターンを出力し、修正は `/rite:fix` に委譲してください。`Bash` ツールは workflow 操作（`gh` CLI、hook scripts、flow state 更新）と **read-only な git コマンド**（完全な許可・禁止一覧は `plugins/rite/agents/_reviewer-base.md` の `## READ-ONLY Enforcement` を single source of truth として参照）のみ許可されます。working tree / index / ref を変更する git コマンド（`git checkout` / `git reset` / `git add` / `git stash` / `git restore` / `git rebase` / `git commit` / `git push` 等）は **禁止** です。

**Principle:** Assessment logic result = final decision. AI's role = reporting + mechanical transition to the next phase only.
