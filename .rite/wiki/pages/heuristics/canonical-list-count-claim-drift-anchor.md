---
title: "新規 exit 1 経路 / sentinel type 追加時は同一ファイル内 canonical 一覧を同期更新し、『N site 対称化』counter 宣言を drift 検出アンカーとして活用する"
domain: "heuristics"
description: "bash block に新規 `exit 1` fail-fast 経路を追加する PR は、同一ファイル内の 2 種の canonical SoT 一覧 (`9.3 exit code` 節の例外リスト / エラーハンドリング表) を **必ず同時更新** する義務を負う。"
created: "2026-04-18T12:50:00+00:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260418T123408Z-pr-579.md"
  - type: "reviews"
    resource: "raw/reviews/20260418T124111Z-pr-579.md"
  - type: "fixes"
    resource: "raw/fixes/20260418T123555Z-pr-579.md"
  - type: "reviews"
    resource: "raw/reviews/20260419T004413Z-pr-585.md"
  - type: "fixes"
    resource: "raw/fixes/20260419T004921Z-pr-585.md"
  - type: "reviews"
    resource: "raw/reviews/20260419T050601Z-pr-590.md"
  - type: "reviews"
    resource: "raw/reviews/20260419T112658Z-pr-599.md"
  - type: "reviews"
    resource: "raw/reviews/20260419T114201Z-pr-599-rereview.md"
  - type: "fixes"
    resource: "raw/fixes/20260419T112900Z-pr-599.md"
  - type: "reviews"
    resource: "raw/reviews/20260501T012144Z-pr-756.md"
  - type: "fixes"
    resource: "raw/fixes/20260501T020145Z-pr-756.md"
  - type: "reviews"
    resource: "raw/reviews/20260504T013212Z-pr-800-cycle2.md"
  - type: "fixes"
    resource: "raw/fixes/20260504T012717Z-pr-800.md"
  - type: "reviews"
    resource: "raw/reviews/20260514T010100Z-pr-950.md"
  - type: "fixes"
    resource: "raw/fixes/20260514T010559Z-pr-950.md"
  - type: "reviews"
    resource: "raw/reviews/20260520T011841Z-pr-1066.md"
  - type: "fixes"
    resource: "raw/fixes/20260520T022118Z-pr-1066-cycle1.md"
  - type: "reviews"
    resource: "raw/reviews/20260607T115501Z-pr-1298.md"
  - type: "reviews"
    resource: "raw/reviews/20260830T135506Z-pr-2489.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/claude-opus-5", at: "2026-08-30T15:15:33Z" }
verified:
  - { by: "rite-wiki-ingest/claude-opus-5", at: "2026-08-30T15:15:33Z" }
---

# 新規 exit 1 経路追加時は同一ファイル内 canonical 一覧を同期更新し、『N site 対称化』counter 宣言を drift 検出アンカーとして活用する

## 概要

bash block に新規 `exit 1` fail-fast 経路を追加する PR は、同一ファイル内の 2 種の canonical SoT 一覧 (`9.3 exit code` 節の例外リスト / エラーハンドリング表) を **必ず同時更新** する義務を負う。また、コメント内の「5 site 対称化」「N site で同型」のような連番 counter 宣言は、canonical 一覧と実装の drift 検出アンカーとして機能し、`grep` で「counter 宣言 vs 実登録数」の gap を検出可能にする。

## 詳細

### 失敗モード（cycle 2 で実測）

起点事例の cycle 1 で placeholder residue gate を 6 site 目として追加した際、cross-validation cycle 2 review で 2 件の MEDIUM 同期漏れが検出された:

- **F-04**: `9.3 exit code` 節の「例外 (`exit 1` fail-fast)」リストに新規 gate の該当行を追加し忘れ
- **F-05**: エラーハンドリング表 (エラー / 対処 / Phase 列) に同 gate の対応行を追加し忘れ

これらは drift 防止用の SoT (Single Source of Truth) 一覧であり、片方だけの更新は「文書化されていない `exit 1` 経路」に読者が遭遇する regression を生む。

### Canonical rule

新規 `exit 1` fail-fast 経路を bash block に追加する PR は、同一ファイル内の以下 2 つの canonical SoT 一覧を **必ず同時更新** する:

1. `9.3 exit code` 節の「例外 (`exit 1` fail-fast)」リスト
2. エラーハンドリング表 (列: エラー / 対処 / Phase)

### 『N site 対称化』counter を drift 検出アンカーとして活用（cycle 3 の final heuristic）

コメント内の「既存 5 site と対称化」「N site で同型」「DRIFT-CHECK ANCHOR: N 箇所 explicit sync」のような連番 counter 宣言は、意図しない副作用として drift 検出アンカーの役割を果たす:

- 新規 site が追加された時、counter が `5 → 6` に update されているかを `grep` で機械検証可能
- reviewer が「カウント宣言 vs 実登録数」の gap を grep で検出できる
- 将来の reader が canonical 一覧の網羅性を counter から逆算可能

### scope 外 drift の扱い

cycle 3 final レビューで「両 reviewer が cross-validation で一致指摘した pre-existing drift」が検出された場合、本 PR scope 外として `AskUserQuestion` で別 Issue 化するのが正規経路（当該 PR で follow-up Issue として切り出し、後続 PR で解消済み）。review サイクルで scope 外修正を混ぜ込むと PR diff が膨張し review gate 失敗の原因となる。

### scope 外 drift の後続 PR による解消ループ（実証）

起点事例で Issue 化された pre-existing drift (`lint.md` L1371 の「5 site 対称化」宣言と canonical 一覧の登録 3 site の gap) は、後続の解消 PR で 2 canonical 一覧 (9.3 exit code 節 + エラーハンドリング表) への Phase 6.2 / 8.3 placeholder gate 追記 (+4 lines / 1 file) で解消された。+4 lines / 2 reviewer (prompt-engineer + code-quality) 0 findings 承認 / re-review 不要という minimal cycle で完了しており、「scope 外 drift → 別 Issue 化 → 後続 PR で解消」フローが (a) review cycle 膨張の回避、(b) drift 恒久化の防止、両方を同時に達成する canonical 経路であることを実証した。

### 拡張: sentinel type enum 同期義務（一般化）

sentinel type enum 事例では `workflow_incident` sentinel の新規 type (`gitignore_drift`) を追加した際に、以下 2 つの enum SoT 一覧を同期すべきだが初版で欠落していた:

1. `docs/SPEC.md` / `docs/SPEC.ja.md` の sentinel type 一覧
2. `references/workflow-incident-emit-protocol.md` の type enum 列挙

新規 sentinel type を `workflow-incident-emit.sh` の `case "$TYPE"` に追加する PR は、上記 2 つの canonical 一覧 + 関連する detection-scope 表 (例: `issue/start.md` Phase 5.4.4.1) を **同一 PR で同期更新** する義務を負う。enum drift は skill writer (LLM) が「未登録の sentinel は発火しない」と silent に誤動作する根本原因になる。

canonical rule の汎化 (本ページの header title も拡張):

- 新規 `exit 1` 経路、新規 sentinel type、新規 incident type enum、新規 fail-fast gate のいずれを追加する PR も、同一ファイル内 / cross-file の canonical SoT 一覧を同期更新する義務を負う
- enum / 例外リスト / エラーハンドリング表は SoT の二重管理であり、片方だけの更新は silent drift
- 「N type 同期」「N entry 登録」counter 宣言を同期アンカーとして活用する

### 拡張: parallelism suffix drift（実証）

canonical 一覧の drift は「counter 数」「エントリの有無」だけでなく、**sibling entry 間の parallelism suffix (「N 種で同型」「N counter で同型」等) の書き漏れ**という微細形でも発生する。parallelism suffix 事例では初版に `9.3 exit code` 節 L1739 Phase 8.3 entry の末尾に「で同型」suffix 3 文字が欠落したまま commit された事例を実測: エラーハンドリング表側 (L1754) は `2 種で同型` で揃っていたが、9.3 節側は `2 種` 止まりで parallel 関係が壊れていた (L1738 Phase 6.2 `3 種で同型` との比較で差分が露呈)。

- **検出経路**: prompt-engineer (LOW finding) と code-quality (推奨事項) が cross-validation で独立に同一箇所を検出。severity 評価は割れたが「drift が存在する」という判定は一致
- **fix 契約の拡張**: canonical rule が「エントリを同期追加する」だけでは不十分で、sibling entry 間の parallelism suffix (表現の揃え方) まで strict に揃える義務を含む。『5 site 対称化』counter は「数」の同期アンカーだが、parallelism suffix は「**表現の同期アンカー**」であり、両輪で機械検証する
- **fix の粒度**: 3 文字追加の micro-fix で 1 cycle 収束 (cycle 1: 1 finding → cycle 2: 0 findings mergeable)。本 PR scope に drift 解消が含まれ、かつ fixable な微細 drift は別 Issue 化ではなく本 PR 内で対応するのが loop 効率的 (ユーザー判定で Phase 5.3.0 mechanical demotion を override する価値がある)

教訓: 同一ファイル内で canonical 一覧が複数セクション (9.3 節 + エラーハンドリング表) に分散している場合、片方への追加・変更が他方と自動的に parallel になる保証はない。reviewer は両セクションの **「数」と「表現」の両軸** で parallel check を行う必要がある。機械 lint では「で同型」の有無は意味的に等価として検出困難なため、cross-reviewer cross-validation が canonical な検出経路。

### 拡張: header の caller list と実 caller の drift + TC enforce 義務

caller list drift 事例の cycle 3 review で `_resolve-flow-state-path.sh` header の **Caller contract enumeration drift** が MEDIUM × 1 で検出された:

- header の Caller contract 節は `4 lifecycle hooks` のみを列挙していた
- 実 caller は `grep -rn _resolve-flow-state-path plugins/` で 6+ (post-tool-wm-sync.sh / pre-tool-bash-guard.sh / commands/issue/create-interview.md を含む)
- TC `TC-749-CALLER-CONTRACT` は keyword loop で 4 hook 名のみ enforce していたため、test 自体が drift を catch できない構造だった

これは canonical 一覧 (header の Caller contract) と SoT (実 caller の grep evidence) の drift であり、本ページが扱う「同一ファイル内 canonical 一覧の同期義務」を **header docstring と実 caller** の cross-file drift に拡張する典型例。

**canonical 拡張 rule**:

1. **header の caller list は machine-verifiable な truth と同期する**: `grep -rn <helper-name> plugins/` の grep evidence ベースで literal SoT と同期。記憶や旧 caller 一覧に依存しない
2. **TC で全 caller を enforce する設計**: caller list を test fixture で keyword loop 検証する場合、4 hook 等の subset ではなく **6+ caller 全て** を enforce する。keyword loop の length 自体が「N caller 同期 counter」として機能 (`'5 site 対称化' counter` パターンの拡張)
3. **caller の category 分類**: 単純列挙ではなく「lifecycle / RITE_DEBUG-gated / command-level」のような category 別に分類することで、新規 caller 追加時に「どの category に入れるべきか」が明示され、無自覚な silent regression リスクが構造的に減少（fix で確立した pattern）
4. **TC が SoT と drift しない構造**: TC の caller list 自体が `grep -rn` evidence と直接対応していること。test fixture が「期待値リスト」をハードコードするのではなく、**grep 経由で動的に取得**するか、**static 一覧と grep evidence の double-check** を test 内で実施する

caller list drift 事例の fix で `_resolve-flow-state-path.sh` header に 6+ caller を category 別 (lifecycle hooks / observability hooks / command-level) で記述し、TC を全 caller enforce に拡張した。これにより同型 drift が将来再発した際に CI で decisive 検出可能になった。

### 拡張: PR description 記載数値と reference 内記述の cross-file 数値 commitment drift（cycle 1 で実証）

cross-file 数値 commitment 事例の cycle 1 で reviewer (prompt-engineer) が MEDIUM finding として「PR description の数値 commitment (`12 → 4`) と reference 内記述 (`12 → ≤ 5`) の乖離」を検出。同一概念 (強調マーカー削減数) の数値表現が `pull request body` / `commit message` / `reference 内 prose` の 3 箇所に散在しており、片方のみ更新すると `12 → 4 (上限 ≤ 5)` のような統合形式に修正しないと整合性が取れない drift パターン。

**Canonical 対策の拡張**（cycle 1 で確立）:

1. **数値 commitment の SoT を 1 箇所に集約**: 同一概念の数値 (削減目標 / 件数 / 閾値) は SoT を 1 箇所 (推奨: PR description) のみに置き、他箇所は SoT への参照リンクで代替
2. **集約困難な場合は同期契約の prose 明示**: SoT 集約が物理的に困難な場合 (commit message / reference 等で文脈ごとに表現が異なる必要がある場合)、各 site で「他 site の数値 X と整合」の同期契約を prose で明示する
3. **統合形式での表現**: 上限値 / 達成値の両方を表現する場合 (`12 → 4 (上限 ≤ 5)` のように) 1 つの表現に集約することで、片方のみ更新する drift 経路を構造的に塞ぐ
4. **cycle 2 での verify**: 数値 commitment 修正後の verify (cycle 2 の cross-validation review) で全 site が drift なし確認されることを mergeable 条件とする

cross-file 数値 commitment 事例では本対策で cycle 2 reviewer (prompt-engineer + code-quality) が cross-validation で全 3 site の drift なしを確認、cycle 4 で mergeable 達成。

### 拡張: refactor 対象外 reference 内の "site count" stale 化（実証）

start.md Phase 5.5.2 / 5.2.1 / 2.4 を 3 references へ抽出した PR の cycle 1 review で 2 reviewer (prompt-engineer + code-quality) が独立に同一の MEDIUM finding を検出: refactor で SoT を新規 references に移管した結果、refactor **対象外** の既存 reference `pre-condition-gate.md` 内に書かれていた「site count」(本体側 callsite 数を absolute 言及していた箇所) が stale 化した。

- **検出経路**: 2 reviewer cross-validation で独立に同一箇所を検出 (high-confidence)
- **失敗モード**: SoT 移管 PR は新規 reference 側の整合性に注意が向くため、移管対象外 reference 内の「N callsite」「N 箇所」のような absolute claim が忘れられる
- **canonical 拡張**: 本ページの規範は「**新 SoT 宣言時、本体 + 全 references 横断で「site count」「N 箇所」絶対参照を検索し、移管対象外 reference 内の stale claim も同時更新する**」までスコープを拡張する。`grep -rn 'N callsite\|N 箇所\|N 個所' commands/issue/references/` で検出可能
- **scope 内対応の判断**: site count stale 事例では本 drift を当該 PR scope 内で fix (cycle 1) し cycle 2 で 0 blocking findings 達成。fixable な微細 drift は別 Issue 化せず本 PR で対応する parallelism suffix 事例 cycle 3 の方針と一致

### 拡張: 'N-site 対称化' narration claim と peer 経路 (watchdog 等) の含意整合性（実証）

narration claim 事例の cycle 11 で 3 reviewer (prompt-engineer + code-quality + error-handling) が cross-validated として「PR が『4-site 対称化』を謳うが、実 site は 3 sites (post-compact.sh / start.md / start-finalize.md) で `gh pr list` 経由の watchdog は対象外」という narration claim vs 実態 site の不一致を独立検出した。

本 PR の「N-site 対称化」claim は本来 (a) PR が修正する site 数 (= 3) のはずが、(b) 同型問題が peer 経路 (watchdog の `gh pr list`) にも existing するという system 全体の context を読者が暗黙に補完しうるため、narration の `4` が「peer も含めた将来 scope」と誤読される経路があった。本ページの canonical rule (N-site counter を SoT 一覧と機械検証する) に **peer 経路への含意の整合性検証** を新 sub-pattern として追加する:

- 「N-site」counter の N は (a) PR の修正対象 site 数か (b) 同型 idiom が存在する全 peer 経路数か を narration で明示する
- 同型 idiom が watchdog / 別 path 経由でも存在する場合、claim の N は「修正した sites」のみを意味し、peer 経路の存在を読者から隠さない: 例「3-site 対称化 (peer 経路の watchdog は `gh pr list` 経由で本 PR scope 外、別 Issue で検討)」と footnote で peer 存在を明示
- canonical 検出経路: 「N-site」counter を含む PR description / commit message を読む reviewer は、当該 idiom (例: `gh pr view`) の全 occurrence を `grep -rn` で repo 全体から探し、PR 修正範囲に含まれない hit があれば narration の N と乖離していないか check する

本件は 3 reviewer が独立に同手順を実施し cross-validated として収束。fix (cycle 1) で「3-site 対称化」+ watchdog footnote へ narration を訂正し、reasoning prose は保持しつつ counter 表現と peer scope 限定を分離した。本 sub-pattern は本ページの拡張群 (parallelism suffix drift / caller list drift / cross-file 数値 commitment drift / refactor 対象外 reference の stale claim) と並列し、「**narration 内の数値 / counter が読者に含意するシステム全体 scope と実 PR scope の乖離**」という新カテゴリを追加する。

### 転換: hand-maintained counter の撤廃と step enumeration 列挙への統一（実証）

本ページの canonical rule は counter 宣言を「drift 検出アンカー」として活用する方向だったが、counter 撤廃事例 (0 findings / 初回 mergeable) で **hand-maintained counter 自体が drift 源になる構造的限界** が確認され、counter を撤廃して grep で各 site を直接検証可能な **step enumeration 列挙** に統一する転換が successful application として実測された:

- **counter の構造的曖昧さ**: 「5 site」「7 site」「N 箇所」のような counter は **計数規則の曖昧さ** (inline 実装のみを数えるか helper 委譲分を含むか) を内包する。`wiki/lint.md` の branch_strategy fail-fast 5 site のうち 6.0 / 6.2 が helper 委譲済みになった時点で「5 site」の解釈が二義的になり、counter の update 義務が judgment call 化して silent drift する
- **enumeration の構造的優位**: counter `5 site` を step 列挙 (`1.3 / 2.2 / 6.0 / 6.2 / 8.1` のような enumeration) に置換すると、計数規則の曖昧さが**構造的に消滅**し、各 site を `grep` で直接実在検証できる (counter は「数の一致」しか検証できないが enumeration は「各 site の実在」を検証できる)
- **検証 protocol**: 5 reviewer が独立に enumeration の全数検証 (列挙された各 step の実在 grep + helper 委譲注記の helper 実在確認) を実施し全員一致で正確と確認。counter 残存ゼロを repo 横断 grep (`5 site / 7 site / N 箇所で同型`) で機械検証
- **qualitative 表現の残置基準**: 「各 site で同型」のような **数を主張しない qualitative 表現** は、具体的 step 集合の併記があれば drift 源にならないため意図的残置が妥当
- **本ページ canonical rule との関係**: counter を drift 検出アンカーとして活用する rule は「counter が正確に維持される」前提に立つが、計数規則が曖昧になった counter はアンカー機能自体を失う。**counter 活用 (本ページ原 rule) → enumeration 列挙への転換** は、`drift-check-anchor-semantic-name.md` の「line 番号 literal 禁止 → semantic name 参照」と同型の構造的閉塞であり、counter は line 番号と同じ「書いた時点から陳腐化が始まる」hand-maintained literal の一種として扱う

### 拡張: 集合を数詞で要約した散文は、集合を列挙した散文とは別サイトである

canonical 一覧の同期義務は「列挙している箇所」だけでは閉じない。判定式のループ対象を 5 変数から 4 変数へ縮めた変更で、同一ファイル内の exit code 契約表とエラー処理表に残る「`n_*` 5 種」という**数詞要約**が更新から漏れた。追加してあった静的 pin は「判定基準の散文 / bash の if 条件 / residue gate のループ」の 3 サイトを相互突合していたが、数詞要約はそのどれにも該当せず機械検知されなかった。3 レビュアーが独立に同一箇所を指摘しており、人間には見えるが pin には見えない典型形である。

- **pin 対象のサイト分類に「N 種 / N 件 / N 箇所」の数詞要約を独立の類として加える**。列挙形の集合一致 assert は数詞要約を包含しない
- 数詞要約は本ページの「counter 宣言を drift 検出アンカーとして活用する」規則の裏面でもある。counter は**アンカーとして使えると同時に、同期漏れの発生源でもある**

### 拡張: rationale ポインタ方式は本体とアンカー先の両方を直す

「rationale は `references/` へ退避し本体に 1 行ポインタを残す」構造では、振る舞いを変えたときに本体だけを直してもポインタ先に同じ主張が残る。実測では本体の「informational 指標として完了レポートの内訳にのみ表示する」を実態へ直した後も、`rationale:` 行が指す先の同じ主張が旧仕様のまま残っていた。**ポインタ方式は記述の重複を消すのではなく 1 レベル下へ移すだけ**なので、canonical 一覧の同期義務も 1 レベル下まで及ぶ。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [canonical reference 文書のサンプルコードは canonical 実装と一字一句同期する](../patterns/canonical-reference-sample-code-strict-sync.md)
- [DRIFT-CHECK ANCHOR は semantic name 参照で記述する（line 番号禁止）](../patterns/drift-check-anchor-semantic-name.md)

## ソース

- [PR #579 review results (cycle 2)](../../raw/reviews/20260418T123408Z-pr-579.md)
- [PR #579 review results (cycle 3 final)](../../raw/reviews/20260418T124111Z-pr-579.md)
- [PR #579 fix results (cycle 2)](../../raw/fixes/20260418T123555Z-pr-579.md)
- [PR #585 review results](../../raw/reviews/20260419T004413Z-pr-585.md)
- [PR #585 fix results](../../raw/fixes/20260419T004921Z-pr-585.md)
- [PR #590 review results](../../raw/reviews/20260419T050601Z-pr-590.md)
- [PR #599 review results](../../raw/reviews/20260419T112658Z-pr-599.md)
- [PR #599 re-review results](../../raw/reviews/20260419T114201Z-pr-599-rereview.md)
- [PR #599 fix results](../../raw/fixes/20260419T112900Z-pr-599.md)
- [PR #756 cycle 3 review (caller contract enumeration drift MEDIUM)](../../raw/reviews/20260501T012144Z-pr-756.md)
- [PR #756 cycle 4 fix (header caller list を 6+ caller に拡張 + TC enforce 強化)](../../raw/fixes/20260501T020145Z-pr-756.md)
- [PR #800 cycle 2 review (cross-file 数値 commitment drift 全 3 site 整合 verify)](../../raw/reviews/20260504T013212Z-pr-800-cycle2.md)
- [PR #800 cycle 1 fix (`12 → 4 (上限 ≤ 5)` 統合形式での数値 commitment 集約)](../../raw/fixes/20260504T012717Z-pr-800.md)
- [PR #950 review (refactor 対象外 reference 内の site count stale 化を 2 reviewer cross-validation で検出)](../../raw/reviews/20260514T010100Z-pr-950.md)
- [PR #950 cycle 1 fix (pre-condition-gate.md 内の stale site count を SoT 移管と同 cycle で同期更新)](../../raw/fixes/20260514T010559Z-pr-950.md)
- [PR #1066 review (3 reviewer cross-validated: '4-site 対称化' narration claim vs 実 3-site 不一致 + watchdog peer 経路含意の漏れ)](../../raw/reviews/20260520T011841Z-pr-1066.md)
- [PR #1066 cycle 1 fix ('3-site 対称化' + watchdog footnote で peer scope 限定を narration に明示)](../../raw/fixes/20260520T022118Z-pr-1066-cycle1.md)
- [PR #1298 review (hand-maintained counter 撤廃 → step enumeration 列挙統一の successful application、0 findings 初回 mergeable)](../../raw/reviews/20260607T115501Z-pr-1298.md)
- [PR #2489 review results (散文カウント drift を 3 レビュアーが独立検出)](../../raw/reviews/20260830T135506Z-pr-2489.md)
