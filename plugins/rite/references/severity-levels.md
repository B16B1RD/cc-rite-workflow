# Severity Levels and Evaluation Criteria

This document defines the common severity levels and evaluation criteria used by all reviewers in the Rite Workflow.

## Severity Levels

| Level | Definition | Response Timeline |
|--------|------|---------------|
| **CRITICAL** | Immediately exploitable vulnerabilities, deployment failures, or production crashes | Must fix before merge |
| **HIGH** | Serious issues with significant impact (security risks, data exposure, perceptible degradation) | Recommended to fix before merge |
| **MEDIUM** | Potential concerns or best practice violations that should be addressed | Address early |
| **LOW-MEDIUM** | Minor concerns whose blast radius is bounded (例: 独自ジャーゴン濫用 — 個別修正で完了する localized 問題) | Address when convenient (LOW より優先) |
| **LOW** | Minor improvements or optimization opportunities | Address when time permits |

**Note**: Each reviewer may provide domain-specific examples of what constitutes each severity level in their respective documentation.

## Severity 語彙 3 系統 Crosswalk

<a id="severity-vocabulary-crosswalk"></a>

rite には severity を表す 3 つの正当な語彙が併存する。それぞれ用途が異なるため統一はせず、以下の表を単一 crosswalk SoT とする(`templates/issue/default.md` の Type Notation Policy と同じ crosswalk 方式)。

| schema enum (5 値) | reviewer checklist 見出し | 運用 3 段 |
|---|---|---|
| `CRITICAL` | Critical (Must Fix) | Critical |
| `HIGH` | Important (Should Fix) | Important |
| `MEDIUM` | Recommendations | Minor |
| `LOW-MEDIUM` | Recommendations | Minor |
| `LOW` | Recommendations | Minor |

- **schema enum (5 値)**: `findings[].severity` の JSON 出力値。上記 Severity Levels 表で正式定義され、`review-result-schema.md` の schema が受理する唯一の値域。
- **reviewer checklist 見出し (3 値)**: 各 `agents/*-reviewer.md` の `## Review Checklist` セクション見出し(`### Critical (Must Fix)` / `### Important (Should Fix)` / `### Recommendations`)。レビュー観点を投資領域ごとに整理するための見出しであり、finding 発行時の enum 値そのものではない。`Recommendations` は MEDIUM/LOW-MEDIUM/LOW の 3 値を包含する。
- **運用 3 段 (3 値)**: ドキュメント上の説明的表現(例: `review-result-schema.md` の外部ツール別名運用に関する記述)。reviewer が「Important」を出力した場合に読み手が enum 値へ変換するための日常語彙。

**判断**: どちらか一方へ統一せず、3 系列を残し上表を単一 crosswalk SoT とする。**根拠**: 5 値 enum は JSON の型契約として、checklist 見出しはレビュー観点の整理として、運用 3 段は説明用の自然言語として、それぞれ異なる目的で存在しており、統一しても境界が別の場所(schema ⇄ 見出し ⇄ 説明文)に移動するだけ。非自明な対応は `Recommendations`/`Minor` が MEDIUM 以下 3 値をまとめて指す点のみ(他は大文字小文字・字面の差)。

## Observed Likelihood Axis

Severity alone (impact axis) is insufficient. Every finding must also be classified along the **Observed Likelihood** axis — the degree to which the triggering condition can be demonstrated to exist in the codebase under review.

| Likelihood | Definition |
|-----------|-----------|
| **Observed** | The bug has been reproduced (test failure, crash log, runtime trace, or grepped error in CI) on the diff under review. |
| **Demonstrable** | The bug has not been reproduced, but the triggering call site or entrypoint connection exists in the **diff-applied codebase as a whole** (existing code + new code introduced by this PR). The reviewer can cite the call site by `file:line`. |
| **Hypothetical** | The triggering condition is plausible in principle but the reviewer cannot cite a concrete call site or entrypoint that reaches the buggy code in the diff-applied codebase. |

### Demonstrable: scope of proof

The proof scope is the **diff-applied codebase as a whole**, not "existing code only". This intentionally closes the new-feature-PR loophole: a PR that introduces a brand-new module would otherwise have no pre-existing call sites and would be auto-downgraded to Hypothetical even when the new module's own entrypoint is wired up.

Acceptable evidence for Demonstrable status (any one of the following is sufficient):

1. **Existing call site**: `Grep` finds a pre-existing caller of the function/path in question.
2. **New call site**: The PR diff itself adds a caller of the function/path.
3. **Entrypoint connection**: The buggy code is reachable from a CLI command, HTTP route, webhook, cron, framework convention (controller / handler / hook), test runner, or other registered entrypoint — even if `Grep` for the function name returns no results because dispatch is dynamic (reflection, decorator, plugin registry, hook system, configuration-driven routing).
4. **Runtime observation**: The reviewer has actually run the diff-applied code and observed the failure.

The reviewer must record which evidence type was used in the finding's `内容` column using the standardized machine-readable prefix `Likelihood-Evidence: <label> <location>` defined in [`agents/_reviewer-base.md` "Demonstrable: proof of burden"](../agents/_reviewer-base.md#demonstrable-proof-of-burden). Examples: `Likelihood-Evidence: existing_call_site src/api.ts:45`, `Likelihood-Evidence: new_call_site src/new-module.ts:12`, `Likelihood-Evidence: entrypoint_connection commands/foo.md → hooks/foo.sh L23`. See `_reviewer-base.md` for the full label list and the machine-detection contract.

### Grep failure ≠ Hypothetical

If a static text search (`Grep`) returns no results, that alone does NOT downgrade a finding to Hypothetical. Dynamic dispatch, reflection, hook scripts, framework conventions (e.g., Rails controllers, Next.js route files, Django URL routers, Claude Code skill auto-discovery), and configuration-file-driven routing all produce real call sites that `Grep` cannot see. The reviewer must:

1. Search for entrypoint registration files (`commands/`, `hooks/`, `skills/`, `routes/`, `urls.py`, etc.) that mention the buggy file or function.
2. If an entrypoint mentions the file, the reviewer has met the Demonstrable bar — even with zero `Grep` hits for the function name.
3. Only when neither direct call sites nor entrypoint connections can be demonstrated does the finding fall to Hypothetical.

## Impact × Observed Likelihood Matrix

The final severity reported in the findings table is determined by combining the Impact axis (CRITICAL / HIGH / MEDIUM / LOW-MEDIUM / LOW) with the Observed Likelihood axis. The matrix below is the mechanical rule reviewers apply at finding-emission time:

| Impact \ Likelihood | Observed | Demonstrable | Hypothetical |
|---|---|---|---|
| **CRITICAL** | CRITICAL | CRITICAL | **降格 → 推奨事項** (例外カテゴリを除く) |
| **HIGH** | HIGH | HIGH | **降格 → 推奨事項** (例外カテゴリを除く) |
| **MEDIUM** | MEDIUM | MEDIUM | **降格 → 推奨事項** (例外カテゴリを除く) |
| **LOW-MEDIUM** | LOW-MEDIUM | LOW-MEDIUM | **降格 → 推奨事項** (例外カテゴリを除く) |
| **LOW** | LOW | LOW | 報告禁止 |

**Rule**: Hypothetical findings in the CRITICAL / HIGH / MEDIUM / LOW-MEDIUM rows are all downgraded to **推奨事項** (a single, mechanical destination — no reviewer-side judgment required). LOW × Hypothetical is **報告禁止** because both axes are already at the lowest tier and further downgrade would produce zero-information findings. The only exceptions are reviewers in the Hypothetical Exception Categories below.

## COMMENT_QUALITY 軸 (Impact カテゴリ)

`COMMENT_QUALITY` は Impact 軸 (CRITICAL/HIGH/MEDIUM/LOW-MEDIUM/LOW) に対する Impact カテゴリ分類の一つで、コメント品質違反 (Comment Rot / ジャーナルコメント / 過剰冗長 / 内部 helper の些末コメント等) を Impact × Likelihood Matrix で扱うための軸である。本軸は SoT ([`comment-best-practices.md`](../skills/rite-workflow/references/comment-best-practices.md)) と reviewer 側 [`Comment Quality Finding Gate`](../agents/_reviewer-base.md#comment-quality-finding-gate) を統合する severity 判定の入口となる。

### Impact 等級概要

| Impact 等級 | 該当する Comment Quality 違反 (高レベル概要) |
|-----------|-----------------------------------------|
| **CRITICAL** | Comment Rot (security/correctness 主張が現コードと不一致 — 読者を能動的にミスリード) |
| **HIGH** | ジャーナルコメント (`cycle N` / `verified-review` / `PR #N` 等)、行番号・cycle 番号参照 |
| **MEDIUM** | 過剰冗長 (内部 helper のコメント密度逆転、公開 API の docstring 0 行 等) |
| **LOW-MEDIUM** | 独自ジャーゴン濫用 (Whitelist 外の造語) |
| **LOW** | 内部 helper の些末 WHAT コメント等 (詳細粒度は SoT 参照) |

> **重要度プリセット表本体は SoT に集約**: 上記は概要のみ。各違反パターンと SoT check 参照を含む完全な重要度プリセット表は [`_reviewer-base.md` の Comment Quality Finding Gate](../agents/_reviewer-base.md#comment-quality-finding-gate) を参照すること。本ファイル (`severity-levels.md`) で表本体を複製すると SoT 重複問題 (= 同じ重要度プリセット表が複数ファイルに重複している状態。別途整理予定) を再導入してしまうため、forward-pointer のみとする。粒度の対応関係: SoT 表は検出パターン単位で記述され (各 Impact 等級に対して 1 つ以上の具体的検出パターンを列挙)、概要表は Impact 等級単位で要約する。両者の粒度差は意図的であり、reviewer は finding 発行時に SoT 表で対応する具体的検出パターンを参照する。

### Hypothetical 降格ルール (本軸での適用例)

`COMMENT_QUALITY` カテゴリは Hypothetical Exception Categories (security / database migration / devops infra / dependencies) に **含まれない**。したがって Impact × Observed Likelihood Matrix の通常ルールに従い、Hypothetical 判定の finding は **推奨事項に降格** される。

典型的な Hypothetical 降格例:

- 「将来の cycle で orphan になるかもしれない」コメント (e.g., `// 旧実装は ... — cycle 8 で削除予定`) — 削除予定コードが現時点で reachable な call site を持たず、`Grep` でも参照が確認できない場合は Hypothetical → **推奨事項** に降格
- 「もしリファクタが入ったら drift する可能性がある」cycle 番号参照 — 現時点で参照先 cycle が存在しなくても、コメント単体が誤誘導しているわけではない場合は Hypothetical → **推奨事項** に降格

### Demonstrable 昇格 signal (本軸での適用例)

逆に、以下のような observation を提示できれば Hypothetical → **Demonstrable** に昇格させ、Impact 等級そのままで finding を発行できる:

- **`git blame` 実証**: `git blame {file}` で当該コメント行が対応する code change より明確に古い (= merge 済み) ことを示し、かつコメント中の reference (`cycle N` / `PR #N` / 関数名) が現コードベースで grep ヒット 0 であることを実証 → 該当 reference の宛先が更新されていない Comment Rot として **HIGH** 以上で finding 発行可
- **新規 diff 由来**: `git diff {base_branch}...HEAD` の `+` 行に対象コメントが追加されている場合、`Likelihood-Evidence: new_call_site {file}:{line} (本 PR diff の `+` 行で追加)` を提示できるため Demonstrable 確定 (これは [`_reviewer-base.md` Comment Quality Finding Gate `Hypothetical → Demonstrable 昇格 signal`](../agents/_reviewer-base.md#hypothetical--demonstrable-昇格-signal) と同じ判定基準)

## Hypothetical Exception Categories

Four reviewer categories MAY retain **CRITICAL / HIGH / MEDIUM / LOW-MEDIUM** severity for Hypothetical findings (matching the Matrix rows that specify "降格 → 推奨事項 (例外カテゴリを除く)"), because in their domain a single occurrence of the bug is catastrophic and "wait until we observe it in production" is not an acceptable risk model:

| Category | Reviewer | Rationale |
|---|---|---|
| **Security** | `security-reviewer.md` | Adversarial input is the reviewer's job. A SQL injection vector that has no observed exploit today is still a CRITICAL risk because the attacker chooses when to demonstrate it. |
| **Database migration** | `application-reviewer.md` | A migration runs once in production. A destructive or irreversible migration cannot be retried. The blast radius is the entire production dataset. |
| **Infrastructure** | `devops-reviewer.md` | Deployment, rollback, and infra-as-code paths are exercised rarely but failure leaves production in a broken state with no rollback. |
| **Dependencies** | `dependencies-reviewer.md` | Known CVEs, supply-chain compromise, and license violations are inherently "could happen any time" risks. Waiting for observed exploitation is wrong. |

Reviewers in these categories MUST still record the Likelihood classification in the finding's `内容` column (e.g., "Likelihood: Hypothetical (例外カテゴリ: security)") so the reader knows the severity was not auto-downgraded.

All other reviewers MUST apply the matrix above and downgrade Hypothetical findings.

> **本例外は Likelihood 軸のみに適用される**: 例外カテゴリで severity を維持できるのは「Hypothetical でも `全指摘事項` に残せる」ことまでで、**merge を止めるか (blocking) は [§実測必須ゲート](#実測必須ゲート-measured-confirmed-gate) が別途決める**。実測 (`Verification:` アンカー) を伴わない例外カテゴリ指摘は severity を維持したまま non-blocking に分類され、ステップ 5.4 統合レポートの「実測なし指摘」section に記録されて draft PR の人間レビューに委ねられる。上の rationale 列の「観測を待つのは許容できないリスクモデル」は severity 判定の根拠であり、blocking 判定の根拠ではない。

> **Note — 3 ゲート運用への forward-pointer**: 指摘事項化の必要条件は impact + likelihood の 2 軸に加えて **revert test を含む 3 ゲート** を同時充足することが求められます。revert test の運用手順は [`agents/_reviewer-base.md` "Necessary conditions for inclusion in 指摘事項"](../agents/_reviewer-base.md#necessary-conditions-for-inclusion-in-指摘事項) を参照してください。本ファイル (severity-levels.md) は impact + likelihood の 2 軸定義に特化しており、revert test の定義は意図的に `_reviewer-base.md` に集約されています。

## 実測必須ゲート (Measured CONFIRMED Gate)

<a id="実測必須ゲート-measured-confirmed-gate"></a>

mergeable 判定の blocking 条件を「**runtime 実測を伴う CONFIRMED 指摘ゼロ**」に定義する (Issue #2024)。「CONFIRMED 指摘」= 3 ゲート (Confidence >= 80 / Observed Likelihood >= Demonstrable / revert test pass) を通過して `全指摘事項` に残った指摘を指す。

**blocking の定義** (実測必須ゲート適用後):

```
blocking = CONFIRMED (全指摘事項に残存)
         AND verification.measured == true   (repro または failing_test の実測証跡あり)
                                             (※ 未判定 = 本式の対象外。下記「適用範囲」参照)
         AND scope in {current-pr, follow-up}  (nit-noted は従来どおり対象外)
```

- **適用範囲 (measured は 3 値)**: 本式が対象とするのは **`全指摘事項` に載る rite reviewer finding のみ**。`measured` は `true` / `false` に加えて **未判定** の 3 値を取る。未判定は「実測の有無を判定する構造そのものが無い」状態で、(a) 外部ツール / 人間レビュー由来の指摘 (`Verification:` アンカーを構造的に持てない)、(b) レビュー結果 JSON の `findings[].verification` が欠落している場合 (**本ゲートを適用する前に書かれた旧形式 JSON**)、(c) **形式崩れアンカー** — marker と同一セグメント内に `=>` があるのに検出 regex に match しない finding (raw pipe / `=>` 右辺空 / 種別ラベル誤記 / 装飾 marker / アンカー直前の境界欠落) の 3 経路がある。(c) では `scripts/review-measured-gate.sh` が **`verification` を設定しない**ことで未判定を表現する — アンカーの書式が読めない状態を `measured=false` と確定させると、実測済みの指摘が書式ミスだけで blocking から消えるため。したがってゲート適用後の JSON でも `verification` は欠落しうる。いずれも **未判定 = 本ゲートの対象外**として従来どおり blocking に扱う (SoT は [`fix/SKILL.md`](../skills/fix/SKILL.md) ステップ 1.3 分類表の External review 行と同ステップの measured lookup)。したがって consumer 側の [`fix-relaxation-rules.md`](../skills/fix/references/fix-relaxation-rules.md) が `blocking = measured != false` と書くのは本式との**意図的なスコープ差**であり矛盾ではない — 本式は rite reviewer finding に閉じた定義、consumer 側は未判定を含む fix loop 全体の定義。
- **severity 閾値**: 既存の 5.3.1 Red blocking rule を踏襲し **全 severity 帯** (CRITICAL〜LOW) が対象 (nit-noted / auto-demote 済みを除く)。severity による段階的緩和は導入しない。
- **実測 (measured=true) の受理形式**: (a) 再現コマンド + 観測される誤動作 (`repro`)、または (b) failing test のパス + 失敗出力 (`failing_test`) のいずれか。形式は [`review-result-schema.md` §verification サブフィールド](./review-result-schema.md#verification-サブフィールド) で固定し、LLM の自由裁量に委ねない。
- **非実測指摘 (measured=false) の扱い**: 破棄せず **non-blocking** に分類し、**4 経路すべてに記録する** — (1) 永続 JSON (`.rite/review-results/*.json` の トップレベル `non_blocking_findings[]`)、(2) `/rite:pr-review` ステップ 6.1.d の PR 記録コメント (`## 📜 rite 非実測指摘の記録`、update-in-place の 1 件。`pr_review.post_comment` 設定に**依存しない** — Issue #2024 D-01 の担保であり opt-out 対象外。lookup が自分の過去投稿を見つけられない場合 (gh 失敗による degraded、別トークン identity での過去投稿、または既存記録コメントの最終非空行が機械専用 sentinel でない場合 — sentinel 導入前の記録 / marker で始まる手書きコメント。この経路は `degraded=0` のまま発生し `NONBLOCKING_LEGACY_ORPHAN` marker で可視化される) は縮退する — **帰結は件数依存**で、本 cycle の非実測指摘が 1 件以上なら新規作成となり 2 件目が作られ、0 件なら投稿自体を省くため前 cycle の記録が stale で残る (他 4 文書 SPEC.md / CONFIGURATION.md / rite-config.yml / assessment-rules.md と同じ分岐)、(3) `/rite:pr-review` ステップ 5.4 統合レポートの `### 実測なし指摘 (non-blocking)` section (severity 明示、E2E でも省略禁止)、(4) E2E output line の `| non-blocking: {n}` suffix (件数 > 0 のときのみ)。(1) は無条件、(2) は best-effort (「0 件 ∧ helper が既存の記録コメントを**検出できない**」ときは投稿を省き、本文不備 4 種 / gh 失敗 2 種 / jq 実行環境起因 1 種 (`body_check_unavailable`) では `outcome=failed` で投稿されない。lookup が degraded した cycle では既存が実在しても検出できず skip に落ち、前 cycle の記録が stale で残る)、(3)(4) は実行モードと件数に依存する補助経路。fix サイクルは起動しない (mergeable countdown / `total_findings` から除外)。ただし同一 file:line の GitHub thread が rite finding 由来と確認できない場合は [`fix/SKILL.md`](../skills/fix/SKILL.md) ステップ 1.3 step 4 の出自確認で External review = blocking へ振り替わる — 本ゲートは finding を対象とし、thread routing は別レイヤ。既定構成 (`pr_review.post_comment: false`) では (1) がローカルの、(2) が PR 上で共有可能な永続チャネルであり、これによりマージ後に人間が拾い直せる状態を保つ (Issue #2024 D-01。`.rite/review-results/` は gitignore 対象のためレビュアーと共有できるのは (2) のみ)。
- **Observed Likelihood 軸との関係**: `measured=true` は Likelihood 軸の **Observed** (runtime 実測済み) に相当する。Demonstrable のうち **evidence type 1-3 (existing/new call site・entrypoint connection — call site 提示のみで実測なし)** は CONFIRMED ではあるが measured=false のため non-blocking。**evidence type 4 (runtime observation) は Observed 相当で measured=true** — この場合は `Likelihood-Evidence: runtime_observation` と `Verification: repro` / `failing_test` の**両方**を添付する ([_reviewer-base.md §Verification: runtime 実測の添付](../agents/_reviewer-base.md#verification-runtime-measurement))。Likelihood 軸のゲート (Hypothetical 降格) は従来どおり **先に** 適用され、実測必須ゲートはその後段で blocking / non-blocking を分ける。
- **Hypothetical Exception Categories との関係**: 例外カテゴリ (security / database migration / devops infra / dependencies) は Likelihood 軸の例外 (Hypothetical でも severity 維持で `全指摘事項` に残せる) であって、**実測必須ゲートの例外ではない**。実測を伴わない例外カテゴリ指摘も non-blocking として ステップ 5.4 に記録され (severity 明示)、draft PR の人間レビューで判断される。ループ収束性 (「指摘ゼロ」の到達可能性) を優先する設計判断。

**判定の全体順序**: Impact × Likelihood Matrix (Hypothetical 降格) → 3 ゲート通過で CONFIRMED → **実測必須ゲート** (measured=false → non-blocking 降格 + ステップ 5.4 記録) → 残った blocking 指摘ゼロで mergeable。適用手順の実装は [`assessment-rules.md`](../skills/fix/references/assessment-rules.md) **§5.3.0.M (適用手順)** / **§5.3.1・§5.3.3 (判定への反映)** を参照。

**「残った blocking 指摘ゼロ」の判定単位**: `findings[]` 配列全体の空ではなく、**`scope ∈ {current-pr, follow-up}` の部分集合が空**であることを指す (`total_findings` の定義と同一)。`scope == "nit-noted"` の finding は本ゲートの対象外として `findings[]` に残り続けるため、配列全体の空を条件にすると nit が 1 件でもある限り mergeable に到達しない (Issue #2072 D-03)。

**強制層**: 本ゲートの分類は `/rite:pr-review` ステップ 5.3.0.M の [`scripts/review-measured-gate.sh`](../scripts/review-measured-gate.sh) が JSON 後処理として決定論的に実行する。アンカー検出 (2 段判定)・`verification` の設定・`non_blocking_findings[]` への移送・`overall_assessment` の確定はすべて helper 側にあり、LLM は結果の marker を読むだけで分類を行わない。**LLM 裁量に置いた旧設計では、PR #2070 の全 9 サイクルで一度も降格が実行されなかった** — 「自分の指摘を non-blocking 化して mergeable を宣言する」判断は reviewer 群の thoroughness 指示と正面衝突するため、裁量に置く限り構造的に実行されにくい (Issue #2072)。

**強制層が依存するもの (裁量を消しても依存は消えない)**: 分類の入力は JSON の `findings[].scope` と `findings[].description` であり、どちらも LLM が書く。したがって強制層は「LLM の裁量」への依存を「LLM の**記述忠実性**」への依存に置き換えたにすぎない。helper はその依存を hard fail と marker で守る (hard fail はいずれも JSON を書かずに非ゼロ終了する = fail-closed):

- **`scope` は 3 値 enum を要求する** — 値が外れてもキーが欠落しても `reason=scope_enum_violation` で停止する (フラグ有無に依らず発火)。欠落を severity ベースの default mapping で補完する互換モードは持たない — 補完の帰結は enum 外と同一 (`current-pr` の LOW / LOW-MEDIUM が gated から脱落する) で、検出形の違いだけで扱いを割る理由がないため。gated 判定は完全一致のため、未知 scope は blocking 件数からも `non_blocking_findings[]` への移送対象からも**同時に**外れ、実測済み CRITICAL を `findings[]` に残したまま `assessment=mergeable` を確定させる (`blocking=0; demoted=0` は「指摘ゼロの正常終了」と区別できない)。
- **アンカーは直前の境界 (行頭 / `<br>` / 空白) を要求する** — 境界を落とした転記や raw pipe を含む repro は full regex に match しない。この形は **`measured=false` へ潰さず未判定 (= blocking のまま) として扱う** (上記「適用範囲」の経路 (c))。`MEASURED_UNDETERMINED_ON_ANCHOR` marker + WARNING で可視化し、**helper は停止しない**。**未判定と降格を分ける判別子 (定義の SoT は [`assessment-rules.md` §5.3.0.M](../skills/fix/references/assessment-rules.md#530m-実測必須ゲート-measured-confirmed-gate)) は、full regex が no-match だった finding の中でだけ評価される** — 正規形として検出できたアンカーは、LHS に句点や改行を含んでいても `measured=true` のまま blocking に残る。その母集団の内側で、marker から `=>` までの間に改行 / `<br>` / 句点 (U+3002) が挟まる形と距離が判別子の上限を超える形が `measured=false` で降格し、`MEASURED_DEMOTED_ON_ANCHOR` marker + WARNING を出す。この絞り込みが無いと、stage 1 の意図的に緩い存在判定が拾う散文がそのまま恒久 blocking になる。**判別子は字句的で、書き損じか散文かを意図では区別しない** — 同一セグメント内に `=>` が現れる散文は未判定へ倒れ、逆に書き損じたアンカーもセグメントが切れていれば降格する。どちらも既知の残存限界 (範囲と上限の担保は [`assessment-rules.md` §5.3.0.M](../skills/fix/references/assessment-rules.md#530m-実測必須ゲート-measured-confirmed-gate) の「(i) は完全な分離ではない」を SoT とする)。集約的な hard fail (「blocking 候補が全件形式崩れなら止める」等) は一度導入したが撤去しており、per-finding の 3 値化で是正した現在も導入しない。

**判定はいずれも helper 側に置く。** caller 側の散文 routing に置くと、本 Issue が排除対象にした「LLM が marker を読んで止める」依存が強制層の中に残るため。caller が観測するのは非ゼロ終了と `reason` だけで、そこに裁量の余地はない (routing は `pr-review/SKILL.md` ステップ 5.3.0.M step 3 の表)。

**なお強制は全域には及ばない。** `--reject-preset-verification` が弾くのは「既存 `verification.measured` が本ゲートの算出結果 (実測あり / 実測なし / 未判定) と**食い違う**」形だけで、算出結果と一致する preset は素通りし、その `repro` / `failing_test` は helper の抽出を経ず LLM が書いた文字列のまま永続 JSON に残る。preset の存在自体を弾く形にはできない — ゲート適用後の JSON は**未判定を除き** `verification` を持つため、再実行が必ず失敗し冪等性 (AC-5) が壊れる (未判定はキー自体を持たないので再実行でも preset とみなされない)。したがって「実測していないのに正規形アンカーと整合する `verification` を書けば通る」経路は残依存として残る。

## Severity × Scope Matrix

> **Reference**: scope enum 定義と Cross-field invariants は [`review-result-schema.md` §findings.scope](./review-result-schema.md) を参照。scope assign 手順の SoT は [`_reviewer-base.md` §Scope Assignment Flowchart](../agents/_reviewer-base.md#scope-assignment-flowchart)。

各 finding は Impact 軸 (CRITICAL/HIGH/MEDIUM/LOW-MEDIUM/LOW) に加えて **scope 軸 (current-pr / follow-up / nit-noted)** を持つ。両軸の許容組み合わせは以下のマトリクスで定義する。

| Severity | デフォルト scope | 許容 scope | 禁止 scope |
|---|---|---|---|
| **CRITICAL** | `current-pr` | `current-pr` のみ | `follow-up` / `nit-noted` |
| **HIGH** | `current-pr` | `current-pr` / `follow-up` | `nit-noted` |
| **MEDIUM** | `current-pr` | `current-pr` / `follow-up` / `nit-noted` (LOW-MEDIUM 寄り case のみ、`nit_reason` 必須) | — |
| **LOW-MEDIUM** | `nit-noted` | 全 3 値 | — |
| **LOW** | `nit-noted` | `current-pr` (本 PR が文体修正のみの場合) / `nit-noted` | `follow-up` |

### 禁止セルの根拠

| 禁止セル | 根拠 | Cross-field invariant |
|---------|------|----------------------|
| **CRITICAL × follow-up** | CRITICAL 級の脆弱性 / 機能崩壊を別 Issue として deferred することは silent risk accumulation。CRITICAL は必ず本 PR で修正必須 | (本ファイル独自) |
| **CRITICAL × nit-noted** | 同上に加えて「修正不要の nit」として受け流すことは更に重大。schema 1.1.0 invariant #4 で **FAIL invariant** として jq 阻止 | [review-result-schema §Cross-field invariants #4](./review-result-schema.md) |
| **HIGH × nit-noted** | HIGH 級の重大度を nit として受け流すことは review-fix loop の信頼性を毀損。schema 1.1.0 invariant #4 で **FAIL invariant** として jq 阻止 | [review-result-schema §Cross-field invariants #4](./review-result-schema.md) |
| **LOW × follow-up** | LOW 級は本 PR で修正するか nit として受け流すかの二択。別 Issue を切るほどの blast radius がないため follow-up は冗長 | (本ファイル独自) |

### 自動 default mapping (schema 1.0 後方互換)

schema 1.0 / 1.0.0 の review-results JSON は `scope` フィールドを持たないため、read 側で severity ベースの default mapping を適用する:

| Severity | Default scope (schema 1.0 read 時) |
|----------|-----------------------------------|
| CRITICAL / HIGH | `current-pr` |
| MEDIUM | `current-pr` |
| LOW-MEDIUM | `nit-noted` |
| LOW | `nit-noted` |

詳細な jq 表現と `[CONTEXT] REVIEW_SOURCE_SCOPE_DEFAULTED=1` emit ルールは [`review-result-schema.md` §後方互換性](./review-result-schema.md) を参照。

### Hypothetical Exception カテゴリの scope 制約

[Hypothetical Exception Categories](#hypothetical-exception-categories) に該当する 4 reviewer (`security` / `application` / `devops` / `dependencies`) は、Likelihood 軸の例外であって scope 軸の例外ではない。**全 severity 帯で scope=`nit-noted` の出力を禁止** する (詳細は [`_reviewer-base.md` §Scope Assignment Flowchart](../agents/_reviewer-base.md#hypothetical-exception-カテゴリの-nit-noted-禁止) を参照)。

| Reviewer | scope=`nit-noted` | 許容 scope |
|----------|------------------|----------|
| `security-reviewer.md` | ❌ 禁止 | `current-pr` / `follow-up` |
| `application-reviewer.md` | ❌ 禁止 | `current-pr` / `follow-up` |
| `devops-reviewer.md` | ❌ 禁止 | `current-pr` / `follow-up` |
| `dependencies-reviewer.md` | ❌ 禁止 | `current-pr` / `follow-up` |

## Evaluation Criteria

Determine evaluation following this flowchart (after applying the Impact × Likelihood matrix):

```
開始
  │
  ▼
CRITICAL 指摘あり？ ──Yes──> 評価: 要修正
  │No
  ▼
HIGH 指摘あり？ ──Yes──> 評価: 要修正
  │No
  ▼
MEDIUM or LOW-MEDIUM 指摘あり？ ──Yes──> 評価: 条件付き
  │No
  ▼
LOW 指摘のみ or 指摘なし？ ──Yes──> 評価: 可
```

| Evaluation | Condition |
|------|------|
| **要修正** | 1 or more CRITICAL or HIGH findings |
| **条件付き** | 1 or more MEDIUM or LOW-MEDIUM findings (no CRITICAL/HIGH) |
| **可** | LOW only, or no findings |
