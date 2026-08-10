---
type: "heuristics"
title: "Documentation review は対応する実装側 (commands/scripts/templates) の grep verify を必須 step とする"
domain: "heuristics"
promote: rite-plugin
promoted_from: "wiki:/pages/heuristics/docs-review-implementation-grep-verification.md"
created: "2026-05-26T00:00:00Z"
updated: "2026-07-13T17:35:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260713T082548Z-pr-1849.md"
  - type: "fixes"
    ref: "raw/fixes/20260713T081301Z-pr-1849.md"
  - type: "reviews"
    ref: "raw/reviews/20260707T051719Z-pr-1779.md"
  - type: "reviews"
    ref: "raw/reviews/20260706T220114Z-pr-1773-cycle3.md"
  - type: "fixes"
    ref: "raw/fixes/20260706T220317Z-pr-1773-cycle3.md"
  - type: "reviews"
    ref: "raw/reviews/20260706T210924Z-pr-1772.md"
  - type: "reviews"
    ref: "raw/reviews/20260525T070727Z-pr-1139.md"
  - type: "reviews"
    ref: "raw/reviews/20260525T081823Z-pr-1139.md"
  - type: "fixes"
    ref: "raw/fixes/20260525T104719Z-pr-1139.md"
  - type: "fixes"
    ref: "raw/fixes/20260525T124932Z-pr-1139.md"
  - type: "fixes"
    ref: "raw/fixes/20260525T141022Z-pr-1139.md"
  - type: "reviews"
    ref: "raw/reviews/20260602T082558Z-pr-1248.md"
  - type: "reviews"
    ref: "raw/reviews/20260603T162350Z-pr-1261.md"
  - type: "reviews"
    ref: "raw/reviews/20260603T174323Z-pr-1263.md"
  - type: "reviews"
    ref: "raw/reviews/20260607T013821Z-pr-1296.md"
tags: ["docs-drift", "verification-protocol", "implementation-grep", "release-prep", "deprecated-sync", "fact-check"]
confidence: high
---

# Documentation review は対応する実装側 (commands/scripts/templates) の grep verify を必須 step とする

## 概要

Documentation の prose が言及する実装側 (commands/, scripts/, templates/, .ja./.md ペア) の現状 (file 存在・key live 状態・sentinel emit 経路・heading slug) を grep / `ls` / `git show` で機械的に verify する step が review protocol に欠落すると、CHANGELOG / SPEC / CONFIGURATION / migration-guide の記述が実装の現状と乖離したまま merge される。v0.5.0 リリース前の docs 見直し（cycle 14 / 51 findings）で 14 サイクル通じて発火し、cycle 5 で「documentation 内 prose が言及する実装側を grep で確認する」が明文化され、cycle 8 で「fix 履歴の遡及確認」、cycle 12 で「SPEC 全文 1 度通読」、cycle 13 で「prose 内 step 番号書き換えの implementation SoT grep verify」と運用層拡張された。

## 詳細

### 観測された具体パターン

起点事例の cycle 1-14 で 51 件の findings が出た root cause は、ほぼ全件が「documentation の prose が implementation の現状を verify せずに整合性のみ追っていた」点に集約される。本 PR の場合 documentation 側だけで内的整合は cycle 1+2 でほぼ取れていたが、実装側との照合が cycle 5 まで実施されなかったため latent な dead reference / factually-wrong claim が cycle 後半まで蓄積した。

具体的な失敗形態:

1. **CHANGELOG `removed in #N` claim の `ls` 未 verify** (cycle 2 F-01 CRITICAL): CHANGELOG が `plugins/rite/i18n/ja/` を「remain on disk but are no longer referenced at runtime」と書いたが、ディレクトリ自体は #1117 で完全削除されており `ls` は ENOENT を返す。`removed in #N` 系の claim は対応する path に対して `ls` / `git show {sha}:{path}` で actual state を verify せず prose を書いた結果、CHANGELOG 自身が factually false。
2. **CHANGELOG の `# wave` で削除された複数 keys の DEPRECATED 化漏れ** (cycle 1 F-04/F-05, cycle 2 F-02 HIGH): `#1118` で 3 keys が同時削除されたが PR は `separate_issue_creation.*` のみ DEPRECATED 化し、`observed_likelihood_gate.*` / `fail_fast_first.*` / `fix.severity_gating` / `project.type` の他 4 keys を docs 側に live として残置。`# wave` を unit of consistency と認識せず個別 key として処理した結果。canonical 対策: CHANGELOG に `removed in #N` を追記する PR は、その # で削除された全 keys を CHANGELOG 自体から再抽出し、各 key について `grep -rn '<key>' docs/` で残存する live citation を機械検出し、同じ DEPRECATED 化パターンで一括更新する。
3. **Sentinel / Terminal marker の implementation 未 verify** (cycle 1 F-02/F-03 HIGH): docs/SPEC.md Terminal marker 表に新コマンド (`iterate.md` / `ready.md`) の sentinel を書く際、`grep -n '\[iterate:completed\]' plugins/rite/commands/pr/iterate.md` で実装側に存在するかを verify せず、旧 orchestrator の用語 (`Workflow Termination block`) を流用。`iterate.md` の実 sentinel は `[review:mergeable]` / `[fix:replied-only]` / `[fix:cancelled-by-user]` で、phantom sentinel が docs に landed していた。
4. **Documentation が言及する live phase の implementation grep 欠落** (cycle 5 F-01 CRITICAL 4 箇所): documentation が「review 出力からの自動 Issue 作成は発生しない」と factually false な主張をしていたが、`review.md` Phase 7 を grep すると `source: pr_review` 経路で live。#1136 で削除されたのは `fix.md` Phase 4.3 のみ。documentation の「fully removed」claim が cycle 5 まで implementation grep されなかった結果、5 cycle 通じて生き残った。cycle 5 で tech-writer が新規 hunt で実装側 grep を実施した結果として初めて発見。
5. **Self-Defeating Fix の連続再発** (cycle 4/5/8/11/12): fix 自体が新たな dead reference / fact error を導入する pattern が 5 cycle 連続で発火。cycle 4 で「self-defeating fix」が learned に記録されたが、cycle 5/8/11/12 でも同根 (新規導入する説明文の事実確認 step が verification protocol に組み込まれていない) で再発。learned 単発記録では足りず verification protocol レベルでの強制が必要。
6. **TOC anchor の symmetric fix sweep 漏れ** (cycle 12 F-01 / cycle 13 CQ-F-01 HIGH): SPEC TOC anchor mismatch を 1 箇所 fix した際、同じ rename pattern を持つ他の heading を全て sweep する step が欠落。cycle 12 で `Internationalization` H2 rename を fix したが `Project Types` H2 rename を sweep し忘れ、cycle 13 で再検出。
7. **Tree comment / Plugin Structure tree の implementation mirror drift** (cycle 11 F-02 HIGH): SPEC plugin structure tree が templates/ / commands/ の実状を mirror する場合、関連する config 変更 (#1118 で `project-types/` 削除) の影響を tree 側に grep 反映する step が欠落。

### 確立された verification protocol

起点事例から導かれた「documentation review verification protocol」の必須 step:

1. **CHANGELOG fact-check**: `removed in #N` / `migrated in #N` 等の claim には対応 path に対して `ls path/` / `git show {sha}:{path}` で actual state を verify する。
2. **`# wave` grep sweep**: CHANGELOG に `# N` 言及がある場合、その PR で削除された全 keys / features を `git show {sha}` で enumerate し、各 key について `grep -rn '<key>' docs/` で残存 live citation を一括検出する。`# wave` は unit of consistency。
3. **Sentinel / Terminal marker の implementation 存在 verify**: docs に sentinel literal (`[xxx:completed]` 等) を書く前に必ず `grep -n '\[<sentinel>\]' plugins/rite/commands/` で実装側に存在するか確認する。旧 orchestrator 由来の用語 (`Workflow Termination block` 等) は特に高 risk。
4. **`fully removed` 系 claim の path 分解**: 「fully removed」claim は (a) fix-side (b) review-side 等の経路ごとに分解し、各経路の現状を `grep -rn` で個別 verify する。1 経路 only の removal は `2 経路 + 各経路の #N status` table 形式で明示。
5. **Heading slug 再計算 verify**: 手書きで anchor (`#xxx`) を書く PR では GitHub slug 算法 (`lowercase + 非英数除去 + space→hyphen`) で再計算し本文の anchor と一致するか verify する。typo は silent failure。
6. **JA/EN pair grep**: 片方 fix の際は対応する日英ペアを `grep -rn` で再走査し parity drift を防ぐ。fix の日英ペア同時適用 verification が verification protocol に必要。
7. **同 file 内の関連 prose grep**: fix 適用時に同 file 内の関連 prose を `grep` 検索し self-contradiction を防ぐ (cycle 7→8 で CONFIGURATION.md L548 を post-#1136 に書き直したが他 5 箇所が live モデル残置した self-contradiction を一括補修した教訓)。
8. **Docs vs Template SoT grep** (cycle 10 F-01): docs を更新する際、対応する template (`templates/config/rite-config.yml` 等、配布物の SoT) も grep で確認する。docs と template の SoT drift は配布物としての挙動に影響する。
9. **SPEC 全文 1 度通読**: SPEC は section ごとに独立した記述が散らばっており、削除済機能の言及が複数 section (tree / Phase / Project Types / sub-skill table) に分散する場合、全文 1 度通読が必要 (cycle 12 F-02/F-03 で section ごとに散在する Project Types / /rite:init Phase 2 Detection を一括 retired 化した教訓)。

### Root cause summary

documentation review の verification protocol が **「内的整合 (CHANGELOG ↔ CONFIGURATION の言及対応など)」のみに focus し「documentation ↔ implementation の cross-reference 検証」を欠いていた** ことが起点事例の 51 findings / 14 cycle convergence の本質。release-prep docs PR は特に「latest implementation の grep が SoT」と認識し、prose 内のあらゆる factual claim (file 存在・key live・sentinel emit・phase 経路) を implementation grep で裏取りする protocol を必須にすべき。

### 適用範囲

- リリース直前の大規模 docs 整備 PR (起点事例のような pre-release docs review)
- 大型 retire/decompose 系 PR (`#1117` i18n 廃止、`#1118` scaffolding 削除、`#1136` /rite:issue:start 4 分解 など) の事後 docs 整備
- migration-guide 更新 PR (旧 → 新 phase mapping を含むため特に implementation grep が critical)
- CONFIGURATION.md / SPEC.md / CHANGELOG.md / README.md の cross-doc 整合 PR

### Successful application — prose 散文括弧書きの正確性 review

0 findings / 1 cycle の PR で本 protocol の **prose 散文 ↔ helper 実装出力語彙の cross-check** 側面を successful preventive application として実測。`commands/init.md` の NO_RITE_HOOKS routing 行の括弧書き `(already clean)` → `(no rite hooks removed)` という 1 行文言修正レビューで、両 reviewer (prompt-engineer / code-quality) が (1) 説明対象 helper `settings-local-rite-hook-cleanup.sh:15` の実出力語彙 `nothing removed` を SoT として括弧書きの正確性を裏取り (mv 失敗サブケースで `already clean` が不正確になる nuance を実装側で確認)、(2) 同 doc 内の対称注記行 (`no output (...)` 形式、line 650/756) への伝播漏れを `grep "clean)"` で機械検証 (0 件 = 旧語彙残存なし) し、0 findings で確認。**散文括弧書きの正確性 review は、説明対象実装の出力語彙・コメントを implementation grep の SoT に含める**という protocol step の小規模 application であり、同時に Asymmetric Fix Transcription (`Wiki provenance: ../anti-patterns/asymmetric-fix-transcription.md`) の「同 doc 内対称注記行の grep verify」と pair で機能した。

### Successful application — Doc-Heavy mode 5 カテゴリ検証の全主張 grep verify + pre-existing i18n drift の revert-test routing

`docs/SPEC.md` +4/-2 の Doc-Heavy PR（0 findings / 1 cycle）で本 protocol の **「prose が言及する実装主張を悉皆 grep verify する」中核** を successful preventive application として実測。tech-writer (Doc-Heavy mode) と code-quality (sole-reviewer guard co-reviewer) が、SPEC.md に追加した flow-state 権威スコープ再定義ノートの全実装主張を独立に grep/Read 裏取りし全件一致を確認した: (1) per-session 構造 `.rite/sessions/{session_id}.flow-state` を `flow-state.sh` の `SESSION_DIR` 定義で確認、(2) 「`commands/pr/merge.md` Step 1 is the first application of this boundary」を `merge.md` Step 1 の `gh pr view --json mergeable,mergeStateStatus,isDraft` 権威化実装で確認、(3) 相互参照リンク先 `docs/designs/clear-per-command-flow-state-decoupling.md` の実在を確認、(4) work-memory パス `.rite-work-memory/issue-{n}.md` を SPEC architecture table と照合、(5) 継続ループ系列挙 (`iterate.md` review↔fix / `stop-loop-continuation.sh` + handoff / `pr:review` / `pr:fix` / `resume.md`) の実在を確認。Doc-Heavy mode の 5 カテゴリ verification protocol は本 heuristic の「documentation ↔ implementation cross-reference 検証」を mode-gated に強制する構造であり、本 PR はその構造が clean PR で 1 cycle 収束を達成した positive evidence。

加えて、両 reviewer が独立に **`docs/SPEC.ja.md` の per-session 構造への i18n parity drift (pre-existing)** を検出し、protocol step 6 (JA/EN pair grep) の観点で `grep "sessions/" docs/SPEC.ja.md` → 0 hits / legacy `.rite-flow-state` 全面記述を確認したうえで、**revert test により本 PR diff 由来でないと判定して blocking finding から除外し follow-up Issue (#1262) へ routing** した。JA/EN parity drift が検出されても pre-existing なら current-pr blocker にせず follow-up 化する scope judgment が、本 protocol の grep verify と revert test の組み合わせで正しく機能した実例。

### Successful application — 翻訳 PR での実装突合により原本 (EN) 由来の誤り転写を表面化

前項の follow-up にあたる SPEC.ja.md per-session 全面同期 PR で、**翻訳 PR でも原本への盲目的信頼をせず実装突合を行う価値** が実証された。Doc-Heavy mode の 5 カテゴリ検証で大半の主張 (hooks.json 7 events / PHASE_ENUM_V3 13 値 / session-ownership.sh 4 関数・4 source caller / loop_count writer 0 hits 等) を実装側 grep verify した結果、EN SPEC.md に既存する 2 件の事実誤り (存在しないファイル `state-read.sh` / `_resolve-flow-state-path.sh`+`STATE_FILE_PATH` への参照) が JA 版へ忠実翻訳で転写されていたことが表面化した (revert test pass で本 PR diff 由来と判定、HIGH × 2)。JA 単独修正は i18n parity を破壊するため scope=follow-up (EN+JA 両側同時修正の別 Issue) が適切と両レビュアーが独立に収束し、本 protocol の grep verify が「原本の誤りは fact 検証で初めて表面化する」という翻訳 PR 特有の検出経路として機能した。決着パターンの詳細は i18n 同期 PR の忠実翻訳は原本の誤りを転写する — 検出時は accept + 両側同時修正 follow-up で決着する (`Wiki provenance: ./i18n-faithful-translation-source-error-accept-followup.md`) を参照。

### Successful application — docstring contract 追記 PR の claim-実装整合全数検証

コメント / docstring のみの +8/-0 docs PR（0 findings / 1 cycle）で、本 protocol が **script docstring に追記した契約 claim の層** にも適用されることを successful preventive application として実測。`review-findings-maps.sh` docstring への stdout contract 追記 (severity_map_json / scope_map_json は構築検証のみで stdout に emit しない) と TC-D 観測性制約注記 (in-process validation 変数は differential test では観測できない) について、4 reviewer (test / error-handling / performance / security) 全員が「追加コメントの主張と実装の整合」を Grep/Read/テスト実行 (review-findings-maps.test.sh 19/19 pass) で独立に全数検証し、claim-実装乖離ゼロを確認した。Asymmetric Fix Transcription (`Wiki provenance: ../anti-patterns/asymmetric-fix-transcription.md`) の懸念 (claim 文言の片肺化・vacuous claim 化) も非該当と判定。推奨事項 3 件 (usage() の `--help` 時 stdout 出力と「stdout contract: なし」文言の境界注記余地 — 2 reviewer が独立言及 / 将来 stdout emit 契約変更時の test pin 整備方針の defer 妥当性) はいずれも本 PR スコープ外の任意改善として扱われた。コメント追加 only の PR でも「コメントが宣言する契約」は implementation grep verify の対象であり、本 protocol が prose / CHANGELOG / SPEC に加えて docstring contract 層でも 1 cycle 収束を支えることを示す positive evidence。

### Successful application — 定量的棚卸し調査文書における全数値の grep 再実行検証

0 findings / 1 cycle の棚卸し調査 PR で本 protocol の**「実装 grep 検証」を、実装の現状記述ではなく調査文書自身が主張する大規模定量値（`[CONTEXT]` marker 675箇所/55ファイルの棚卸し）に適用する**変種を successful preventive application として実測。tech-writer と code-quality の両 reviewer が独立に `grep -rn '\[CONTEXT\]' plugins/rite/` を再実行し、文書が主張する全数値（総ヒット数・ファイル数・種別内訳6区分の合計・上位15ファイルの個別件数・emit/consume内訳・参照ファイルの実在）を1件残らず突合、捏造・不整合ゼロを確認して1 cycle mergeableに到達した。教訓: 大規模な定量的棚卸しを含む調査文書は、（a）再現可能な grep コマンドを本文に明記し、（b）集計を漏れなく分割された内訳（合計と一致する区分）として提示すると、reviewer 側が実装 grep verify を機械的に反復実行でき、高い信頼性を伴う短サイクル収束を実現できる。本適用は「documentation ↔ implementation」ではなく「調査文書自身の定量claim ↔ grep実測」という cross-reference 対象のバリエーションだが、根底にある「prose の factual claim は必ず機械的に再実行可能な検証手段を伴わせる」原則は同一。

### Successful application — 「削除対象一覧」文書のドキュメント化石化検出 + 後方互換性を理由とした意図的な現状維持判断

アンインストール手順ドキュメント（cycle 3 で 1 LOW 検出 → accept 決着）で、本 protocol の**「削除されるべきファイル一覧」型ドキュメントに対する implementation grep verify** バリエーションを実測。tech-writer が Doc-Heavy mode の 5 カテゴリ検証 (Implementation Coverage) で README の削除対象一覧の各項目を現行実装ソースと突合した結果、掲載されていた `.rite-guidance-shown` が過去の refactor で生成箇所自体が既に除去されており、「現行コードが生成する」という文書の暗黙前提と実装が乖離していることを発見した (`git grep` で参照ゼロを確認)。

本件が既存の「実装 grep 未 verify で dead reference が残る」パターンと異なる点は、**検出後の正しい対応が「削除して仕様を最新化する」ではなく「後方互換性 (旧バージョンからのアップグレード環境での残存可能性) を理由に意図的に現状維持する」であった**こと。fix cycle でこの finding を `accept (認知のみ)` として処理し、fingerprint を永続化して次 cycle 以降の再指摘を抑制した。教訓: 「このコマンドで削除される対象一覧」ドキュメントの grep verify は、乖離を機械的に炙り出すことはできるが、乖離の是正方法 (削除 vs 意図的保持) は reviewer ではなく実装コンテキスト (後方互換性要求など) を踏まえた判断が必要であり、reviewer の役割は「乖離の可視化」に留め、是正判断は fix 側の accept 経路に委ねる責務分離が有効に機能した。

### Successful application — in-source 設計コメントの構造断定（trap 到達可能性）を呼び出し site grep で検証

cycle 2 / 0 findings 収束の PR で、本 protocol の **in-source 設計コメント層**（bash script のヘッダコメントが主張する構造的事実）への適用を実測。file-wide trap retrofit のヘッダコメントが関数 local tmpfile の除外根拠を「command substitution の subshell 内で mktemp されるため親の trap から構造的に到達不能」と全関数に一般化したが、error-handling / code-quality の 2 reviewer が独立に全 call site を grep し、`cache_comment_id` が init mode で親シェルから直接呼ばれる 2 経路（existing_id / created_id の cache 書込）を持つことを実証（cross-validation で MEDIUM→HIGH boost、Comment Rot 判定）。fix はコメントを経路ごと（`get_owner_repo` / `get_comment_id` = subshell 経由で到達不能、`cache_comment_id` = 親シェル直接呼び出しあり）に書き分けて 1 cycle で解消し、cycle 2 で全 6 reviewer が FIXED 判定。教訓: (1) 「構造的に不可能 / 到達不能」と断定する設計コメントは、コードの動作ではなくコメント自身が正しさの根拠を主張する層であり、書く前に全呼び出し site の実行形態（command substitution subshell か親シェル直接か）を grep で確認する。(2) コメントのみの修正でも revert test / 影響スキャン（同一文言の他出現 grep）を省略しない。docstring contract 層に続き、設計根拠コメント層でも本 protocol が機能した positive evidence。

## 関連ページ

- Asymmetric Fix Transcription (対称位置への伝播漏れ) (`Wiki provenance: ../anti-patterns/asymmetric-fix-transcription.md`)

## ソース

- Review cycle 1-2 (trap 被覆設計ヘッダコメントの機構誤認を 2 reviewer 独立検出、cross-validation boost、cycle 2 で FIXED 収束) (`Wiki provenance: ../../raw/reviews/20260713T082548Z-pr-1849.md`)
- Fix (経路ごとの書き分け修正で 1 cycle 解消、コメントのみ修正でも影響スキャン省略しない教訓) (`Wiki provenance: ../../raw/fixes/20260713T081301Z-pr-1849.md`)
- Review cycle 3 (Doc-Heavy Implementation Coverage 検証で削除対象一覧ドキュメントのファサード化を検出) (`Wiki provenance: ../../raw/reviews/20260706T220114Z-pr-1773-cycle3.md`)
- Fix cycle 3 (accept 決着: 後方互換性を理由に意図的現状維持、fingerprint 永続化) (`Wiki provenance: ../../raw/fixes/20260706T220317Z-pr-1773-cycle3.md`)
- Review (調査文書の定量的棚卸し全数値をgrep再実行で検証、tech-writer/code-quality両者独立全数一致、0 findings 1cycle mergeable) (`Wiki provenance: ../../raw/reviews/20260706T210924Z-pr-1772.md`)
- Review cycle 1 (anchor link typo / phantom sentinel / Asymmetric Fix Transcription on #1118 wave) (`Wiki provenance: ../../raw/reviews/20260525T070727Z-pr-1139.md`)
- Review cycle 2 (CHANGELOG `remain on disk` factual error / project.type CHANGELOG vs CONFIGURATION drift) (`Wiki provenance: ../../raw/reviews/20260525T081823Z-pr-1139.md`)
- Fix cycle 5 (Verification Cross-Reference Gap 確立: review.md Phase 7 live を 5 cycle 経て初検出) (`Wiki provenance: ../../raw/fixes/20260525T104719Z-pr-1139.md`)
- Fix cycle 8 (Implementation-Grep Verification Gap: fix 履歴の遡及 grep 必須化) (`Wiki provenance: ../../raw/fixes/20260525T124932Z-pr-1139.md`)
- Fix cycle 12 (SPEC Multi-Section Same-Topic Drift: SPEC 全文 1 度通読の必要性) (`Wiki provenance: ../../raw/fixes/20260525T141022Z-pr-1139.md`)
- Review (prose 散文括弧書きの正確性を helper 出力語彙と cross-check、0 findings の successful application) (`Wiki provenance: ../../raw/reviews/20260602T082558Z-pr-1248.md`)
- Review (Doc-Heavy mode 5 カテゴリ検証で全実装主張を grep verify + pre-existing SPEC.ja.md i18n drift を revert-test で follow-up #1262 化、0 findings の successful application) (`Wiki provenance: ../../raw/reviews/20260603T162350Z-pr-1261.md`)
- Review (翻訳 PR での実装突合により EN 原本由来の事実誤り 2 件の転写を表面化、両レビュアー独立で follow-up 収束) (`Wiki provenance: ../../raw/reviews/20260603T174323Z-pr-1263.md`)
- Review (docstring stdout contract / TC-D 観測性制約 claim の実装整合を 4 reviewer 独立全数検証、0 findings の successful application) (`Wiki provenance: ../../raw/reviews/20260607T013821Z-pr-1296.md`)
- Review — design-rationale.md への 1 文追記 PR で、prompt-engineer/code-quality 両レビュアーが追記内容の技術的主張を file-based/string-based 両鏡像実装の jq ロジックと突合し正確性を実地検証、0 findings の successful application) (`Wiki provenance: ../../raw/reviews/20260707T051719Z-pr-1779.md`)
