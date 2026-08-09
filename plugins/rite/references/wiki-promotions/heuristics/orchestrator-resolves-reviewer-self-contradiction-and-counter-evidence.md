---
type: "heuristics"
title: "Orchestrator は reviewer 間の反証と reviewer 自身の自己矛盾（指摘記載 vs 結論）を解決してから blocking 判定する"
domain: "heuristics"
promote: rite-plugin
promoted_from: "wiki:/pages/heuristics/orchestrator-resolves-reviewer-self-contradiction-and-counter-evidence.md"
promoted_from: "wiki:/pages/heuristics/orchestrator-resolves-reviewer-self-contradiction-and-counter-evidence.md"
description: "複数 reviewer の所見が食い違う場合は他 reviewer の反証（既存実装の grep 確認）で解決し、単一 reviewer の指摘事項テーブル記載でも reviewer 自身が「対応不要」と結論した場合は Finding Quality Guardrail (bikeshedding filter) で blocking から除外する。反対意見を却下した場合は一方的な宣言で終わらせず、却下根拠を当の提案者へ次 cycle の検証項目として差し戻す — 対立が「どちらが正しいか」ではなく「どの軸を見ていたか」として解ける。"
created: "2026-07-06T04:10:00+00:00"
updated: "2026-08-08T14:00:41+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260801T223635Z-pr-2070.md"
  - type: "fixes"
    ref: "raw/fixes/20260801T224211Z-pr-2070.md"
  - type: "reviews"
    ref: "raw/reviews/20260802T000641Z-pr-2070.md"
  - type: "reviews"
    ref: "raw/reviews/20260725T032345Z-pr-2013.md"
  - type: "reviews"
    ref: "raw/reviews/20260725T041328Z-pr-2013.md"
  - type: "reviews"
    ref: "raw/reviews/20260706T033041Z-pr-1756.md"
  - type: "reviews"
    ref: "raw/reviews/20260706T040234Z-pr-1756-cycle2.md"
  - type: "reviews"
    ref: "raw/reviews/20260706T043448Z-pr-1757.md"
  - type: "reviews"
    ref: "raw/reviews/20260706T050235Z-pr-1758.md"
  - type: "reviews"
    ref: "raw/reviews/20260808T031704Z-pr-2142.md"
  - type: "reviews"
    ref: "raw/reviews/20260808T035533Z-pr-2142.md"
tags: []
confidence: medium
---

# Orchestrator は reviewer 間の反証と reviewer 自身の自己矛盾（指摘記載 vs 結論）を解決してから blocking 判定する

## 概要

起点事例の 2 cycle レビューで、orchestrator（consolidation 担当）が単純な「指摘事項テーブルの件数 = blocking 件数」という機械的合算をせず、(1) 複数 reviewer 間の反証関係、(2) reviewer 自身の総合評価と個別指摘の矛盾、の 2 つを見て blocking findings を確定させた 2 つの実例。

## 詳細

### 実例 1: cross-validation による反証（cycle 1）

tech-writer が「Issue body 取得のフォールバック欠如」を懸念として指摘したが、同時に走った prompt-engineer が「Phase 1.5 で既に Issue body を無条件取得済みのため懸念は根拠がない」と独立に反証した。orchestrator は `grep` で `pr-create/SKILL.md` の Phase 1.5 実装を直接確認し、`gh issue view {issue_number} --json number,title,body,state,labels` が無条件実行されることを検証した上で、tech-writer の指摘を false positive と判断して fix 対象から除外した。

**教訓**: 単一 reviewer の懸念を鵜呑みにせず、(a) 他 reviewer が独立に反証していないか、(b) 反証内容が実装の事実と一致するか、を orchestrator 自身が実ファイルで検証する。2 reviewer が食い違う所見を出すのは対立ではなく、互いの盲点を埋め合う機会として扱う。

### 実例 2: Finding Quality Guardrail (bikeshedding filter) の適用（cycle 2）

fix 後の cycle 2 レビューで、prompt-engineer / tech-writer の両者が「overall assessment: Approve/mergeable」と明記した上で、指摘事項テーブルには計 5 件（見出しの語順選好、文の冗長さ、参照アンカーの非対称、列挙順序の不一致、用語の近接による誤読可能性）を掲載していた。個別の指摘文はいずれも「任意」「対応不要（記録のみ）」と reviewer 自身が明記しており、プロジェクト規約の明示的違反を伴わない好み・スタイルレベルの指摘だった。orchestrator は `_reviewer-base.md` の Finding Quality Guardrail（bikeshedding: プロジェクト規約の明示的違反を伴わない好み・スタイル指摘は filter 対象）をこの 5 件に適用し、blocking findings を 0 件と判定して `[review:mergeable]` を確定した。

**教訓**: 「指摘事項テーブルに載っている = 自動的に blocking」という機械的解釈をしない。reviewer 自身の overall assessment（Approve/mergeable）と個別指摘の文言（「任意」「対応不要」）が一致している場合、その指摘は Finding Quality Guardrail の対象として orchestrator が自身の判断で blocking から除外してよい。逆に、reviewer が overall assessment で懸念を示しているのに個別指摘が軽微に見える場合は、機械的に除外せず再確認する（非対称的な適用— bikeshedding filter は「reviewer 自身が要求していない追加対応をしない」ためのものであり、reviewer の総合判断を覆すためのものではない）。

### 実例 3: 全く別の PR・reviewer 組み合わせでの再現

1 行のドキュメント修正 PR（Doc-Heavy PR、tech-writer + code-quality の2reviewer構成）でも同一パターンが再現した。両 reviewer が独立に計 5 件（Low 2件 + nit 3件）を指摘したが、いずれも各 reviewer 自身が「任意の改善」「マージをブロックしません」「対応不要」と明記し、overall assessment はいずれも「承認（mergeable）」だった。orchestrator は同じ Finding Quality Guardrail を適用し blocking findings 0 件で mergeable 確定した。

**教訓**: この解決パターンは特定の PR やレビュアー組み合わせに依存しない汎用的な orchestrator 責務である。「reviewer 自身の overall assessment ＋ 個別指摘文言の両方が非ブロッキングを明示している」という条件が揃えば、PR の性質（コード変更 / ドキュメント変更）や reviewer の専門領域に関わらず適用してよい。

### 実例 4: docs 整合修正 PR での再現

2ファイル（+8/-1）のドキュメント参照不整合修正PRで、prompt-engineer（必須）+ code-quality（sole-reviewer guard co-reviewer）の2reviewer構成でも同一パターンが再現した。両reviewerが独立に計3件（すべてLow）を指摘したが、いずれも各reviewer自身が「対応不要」「任意」「現状維持が妥当」と明記し、overall assessmentはいずれも「承認（mergeable）」だった。orchestratorは同じFinding Quality Guardrailを適用しblocking findings 0件でmergeable確定した。

**教訓**: sole-reviewer guardによる2人目co-reviewer追加時にも同じ判定パターンが安定して機能する。co-reviewerが独自の観点（本例ではテンプレート内表記形式の混在）を追加指摘しても、reviewer自身が非blockingと明記していれば同一のguardrailで扱える。

### 実例 5: 出力側フィルタでなく入力側プロンプトで収束させる — 「0 件は正当な結論」を明示する

実例 1〜4 はいずれも **reviewer が出した指摘を orchestrator が事後にフィルタする**（出力側）解法だった。入力側収束事例の cycle 4 では、**プロンプト設計で事前に**（入力側）収束させる対の手法が実証された。

cycle 4 のプロンプトでは各 reviewer に「ここまで 19 件が全て解消されている。マージをブロックするに値しない観察を指摘事項に格上げしないこと。**指摘 0 件は正当な結論**」と明記した。結果、**6 名中 4 名が「格上げを検討したが見送った」根拠を所見に明示して 0 件を返し**、6 名全員 0 件・評価「可」で収束した（4 cycle の推移: 4 → 8 → 7 → 0）。error-handling は `--kill-after` 未設定を「GNU との意図的パリティ」と判断し、devops は前 cycle の自分の主張を「今 cycle の調査で過大だったと判明」と自ら訂正した。

> **教訓**: 収束が近い cycle では、reviewer に「0 件が正当」と **明示する**。出さないと「まだ何か見つけなければ」という圧力が働き、severity を水増しした指摘が出て cycle が伸びる。出力側の Finding Quality Guardrail（実例 1〜4）と入力側のプロンプト明示は対をなし、後者は水増し指摘の発生自体を抑える。

**あわせて、収束の決め手は「実測で潰した」記録が reviewer 側に残ること**だった。最終 cycle が 0 件になったのは reviewer が懸念を持たなかったからではなく、懸念を実機で潰したから — security は `kill "TERM", -$pid` について「呼び出し元シェルのグループを撃つか」を sibling プロセスの生存確認で否定し、test は 6 種の mutation で新テストの load-bearing を確認し、devops は CI 実行時間を実測した（両スイート 81s / 予算 15 分の 9%）。前 cycle の指摘への対応内容と検証手順を具体的に渡すと、reviewer は再現から入れる。

### 実例 6: reviewer の数値主張が誤っていても、中核の欠陥は実在しうる（cycle 3）

application reviewer が `_timeout` の perl シムについて「GNU timeout 2s vs シム 27s」と報告したが、orchestrator が再現したところ **GNU timeout も 27s**（trap TERM を持つ子は、グループ送信でも TERM を無視すれば待つ）で数値は不正確だった。しかし **別のケース（孤児が stdout を保持）では GNU 3s vs シム 30s** となり、中核の主張（deadline がプロセスグループに効かない）は実在を確認できた。

> **教訓**: reviewer の数値主張は **再現してから採否を決める**。ただし「数値が違う = 指摘ごと棄却」にしない — 数値が誤っていても中核の欠陥は実在しうる。数値の誤りは severity 調整（発火経路の有無で follow-up へ降格等）の材料であって、指摘そのものの棄却理由ではない。これは実例 1 の「orchestrator 自身が実ファイルで検証する」を **反証側だけでなく肯定側にも** 適用した形。

### 実例 7: 外部事実の読みが割れたら、多数決でも先着順でもなく一次ソースで決める（cycle 4）

実例 1〜6 は **自リポジトリの実装**を根拠に解決する形だった。**管理外の上流実装**についてレビュアーの読みが割れる場合も、解決手段は同じ — ただし難度が上がる。

同じ上流実装のグラフ構築モデルについて、あるレビュアーは「辺は本文リンク + frontmatter の `sources` から構築」、別のレビュアーは「辺は本文リンクのみ、`sources` は node のデータ」と述べた。実装を直接読むと後者が正しかった（`_build_graph` は `c.links_to` だけを走査し、`sources` は `to_node()` のペイロードに載るだけ）。

> **教訓**: 独立したレビュアーの主張が外部事実について食い違ったら、**多数決でも先着順でもなく一次ソースで決める**。両者の主張はどちらも「上流を読んだ」形で提示されるため、**読み比べないと誤りがそのまま通る**。上流が OSS なら API 1 回・数十行で決着することが多く、コストは「どちらが正しいか分からないまま進む」リスクに見合わない（[[external-dependency-claim-hedge-vs-citation]]）。

**あわせて、同一の疑問が複数レビュアーから独立に上がるのは記述の曖昧さが実在する強いシグナル**。PR #2070 ではフィールドの母集団を広げたが名前を据え置いた判断について、3 名が独立に同じ確認を提起した。これは合議で潰す対象ではなく、ユーザー確認へ回して仕様として決着させるべき合図である。

### 実例 8: 却下は宣言で終わらせず、次 cycle の検証項目として当の提案者へ差し戻す（PR #2142 cycle 5 → 7）

`--keep-newline` の 1 語削除 mutant を pin すべきかで判定が割れた。security は「既定モードへの格上げは中和が**強まる**方向だから pin 不要、再提起するな」と明示的に反対し、code-quality と prompt-engineer は「行構造が壊れる」と主張した。統合側は実測（3 行の stderr が 1 行へ潰れ、直後の `[CONTEXT]` marker が snippet 末尾へ連結して**行頭を失う**）で後者を採り、security の反対を却下した。

ここで却下を宣言で終えず、**cycle 7 で同 reviewer にその判定の妥当性を問うた**。security は実測のうえで自身の主張を撤回し、「統合側の判定が正しい。さらに自分の軸（攻撃面）でも net-positive — `sed` の indent と合わせて snippet 内から行頭 `[CONTEXT]` を偽造する経路が閉じる」と報告した。

> **教訓**: reviewer の反対を却下したら、**却下根拠を当の提案者に次 cycle で検証させる**。どちらが正しいかの勝敗ではなく「security はバイト衛生の軸を、他 2 名は行構造の軸を見ていた」という**軸の違い**として解けるため、撤回も追加の利得発見も同じ工程で得られる。同様に、cycle 4 で却下した error-handling の提案（awk の `exit` が END を実行するため二重 print になる）も、同 reviewer 自身が gawk / mawk で再現して却下が事実と確認した。

**あわせて、reviewer の提案パッチは指摘と同じ強度で検証する**。指摘の実測アンカーは「欠陥が実在すること」を示すが、**suggestion 欄の実測は誰もしていない**。PR #2142 cycle 4 では 2 つの独立した提案がどちらも欠陥を持ち（片方は誤帰属を残し、片方は正常系を壊す）、7 ケースの実測比較で初めて合成形が確定した。統合側が提案を走らせる工程を省くと、次 cycle の fix が壊れたパッチを適用して新しい blocking を生む。

## 関連ページ

- `rejected(scope-creep)` judgment は cross-validation + empirical revert test で gate する (`Wiki provenance: ./scope-creep-rejection-empirical-gate.md`)
- 新設した検証機構が、その機構自身の目的を局所的に打ち消す (`Wiki provenance: ../anti-patterns/self-defeating-guard-local-purpose-negation.md`)
- reviewer の判定割れは用語の曖昧さのシグナル (`Wiki provenance: ./reviewer-verdict-split-signals-term-ambiguity.md`)
- awk の exit は END 規則を実行する — 早期終了と END フォールバックの併用は二重出力になる (`Wiki provenance: ../anti-patterns/awk-exit-runs-end-rule-double-output.md`)

## ソース

- PR #2013 review cycle 3 — reviewer の数値主張を再現し、数値の誤りと中核欠陥の実在を切り分けた記録 (`Wiki provenance: ../../raw/reviews/20260725T032345Z-pr-2013.md`)
- PR #2013 review cycle 4 — 「0 件は正当な結論」をプロンプトに明示して 6 名全員 0 件で収束 (`Wiki provenance: ../../raw/reviews/20260725T041328Z-pr-2013.md`)
- PR #1756 review results (`Wiki provenance: ../../raw/reviews/20260706T033041Z-pr-1756.md`)
- PR #1757 review results (`Wiki provenance: ../../raw/reviews/20260706T043448Z-pr-1757.md`)
- PR #1758 review results (`Wiki provenance: ../../raw/reviews/20260706T050235Z-pr-1758.md`)
- PR #2070 review results (cycle 4) — 上流実装の読みが 2 名で割れ、一次ソースで決着 (`Wiki provenance: ../../raw/reviews/20260801T223635Z-pr-2070.md`)
- PR #2070 fix results (cycle 4) (`Wiki provenance: ../../raw/fixes/20260801T224211Z-pr-2070.md`)
- PR #2070 review results (cycle 5, mergeable) (`Wiki provenance: ../../raw/reviews/20260802T000641Z-pr-2070.md`)
- PR #2142 review results (cycle 5) — 反対意見の却下と、その却下根拠の差し戻し (`Wiki provenance: ../../raw/reviews/20260808T031704Z-pr-2142.md`)
- PR #2142 review results (cycle 7, mergeable) — 提案者自身による撤回と軸の明示 (`Wiki provenance: ../../raw/reviews/20260808T035533Z-pr-2142.md`)
