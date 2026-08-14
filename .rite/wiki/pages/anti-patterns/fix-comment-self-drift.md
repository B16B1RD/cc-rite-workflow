---
title: "Fix 修正コメント自身が canonical convention を破る self-drift"
domain: "anti-patterns"
description: "fix サイクルで追加・変更したコメントや説明文自体が、その PR が守るべき canonical convention（例: 「行番号参照禁止」原則）を破ってしまう self-drift failure mode。"
promote: rite-plugin
created: "2026-04-18T12:00:00+00:00"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260712T150908Z-pr-1836.md"
  - type: "fixes"
    resource: "raw/fixes/20260528T144526Z-pr-1169.md"
  - type: "reviews"
    resource: "raw/reviews/20260418T114056Z-pr-578.md"
  - type: "fixes"
    resource: "raw/fixes/20260418T114231Z-pr-578.md"
  - type: "fixes"
    resource: "raw/fixes/20260420T043015Z-pr-617-fix1.md"
  - type: "fixes"
    resource: "raw/fixes/20260426T015356Z-pr-671.md"
  - type: "reviews"
    resource: "raw/reviews/20260501T012144Z-pr-756.md"
  - type: "fixes"
    resource: "raw/fixes/20260501T020145Z-pr-756.md"
  - type: "reviews"
    resource: "raw/reviews/20260527T082452Z-pr-1161.md"
  - type: "reviews"
    resource: "raw/reviews/20260527T083107Z-pr-1161.md"
  - type: "reviews"
    resource: "raw/reviews/20260712T174329Z-pr-1838.md"
  - type: "reviews"
    resource: "raw/reviews/20260803T020301Z-pr-2094.md"
  - type: "reviews"
    resource: "raw/reviews/20260803T051521Z-pr-2094.md"
tags: ["self-drift", "canonical-convention", "grep-self-check", "review-fix-loop", "lint-rule-self-meta-drift"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-03T07:46:56Z" }
---

# Fix 修正コメント自身が canonical convention を破る self-drift

## 概要

fix サイクルで追加・変更したコメントや説明文自体が、その PR が守るべき canonical convention（例: 「行番号参照禁止」原則）を破ってしまう self-drift failure mode。reviewer の推奨値を盲信した fix ほど発生しやすく、commit 前の `grep` self-check で decisive に検出できる。

## 詳細

### 発生事例（cycle 2）

F-ID 衝突 fix 事例では、同一ファイル内で同一 F-NN ID が 2 件の独立 finding を指す silent ambiguity を解消する fix を行った。その際に追加したコメントの中に、本プロジェクトが既に確立している「canonical convention = 行番号参照は脆いため semantic 参照を用いる」という原則に違反する `L1144` 等の literal 行番号を書き込んでしまった。cycle 2 で MEDIUM finding として浮上し、修正コメント自身が canonical を破っているという構造的欠陥が検出された。

### 失敗の構造

1. reviewer 1 が「recommend 値 = F-16」を提示（ただし既存 F-IDs との grep 検証は未実施）
2. fix 側が推奨値を盲信し、衝突がないか `grep` で全件確認しないまま採用しそうになる
3. 追加したコメント内に literal 行番号を書き込み、既に確立済みの「行番号参照禁止」原則を自ら破る
4. 同型 drift が fix コメントの複数箇所に波及し、cycle 2 で片付かず cycle 3 まで発散
5. reviewer 自身の推奨値が canonical convention を破る hallmark pattern として可視化

### Detection Heuristic

fix の commit 前に以下を必須として習慣化する:

```bash
# 1. 行番号参照の残存検出
grep -nE 'L[0-9]+' {changed_files}

# 2. F-ID / ID 採番時は必ず最大値 +1 で全件 grep
grep -oE 'F-[0-9]+' {target_file} | sort -u
# reviewer 推奨値ではなく、既存 IDs の最大値 +1 を選択

# 3. canonical convention 一覧との突合 (事前に確立した原則を列挙)
#    - 行番号参照禁止
#    - `if ! cmd; then rc=$?` 禁止
#    - `mktemp \|\| echo ""` 禁止
```

### 経験則の適用

本 anti-pattern は以下の既存経験則を束ねる **メタレベル self-drift pattern** である:

- **canonical reference 文書のサンプルコードは canonical 実装と一字一句同期する**: fix 自身が書くコメントも canonical の一部であり、drift すると下流の実装者が「reference が正」と信じてコピペする
- **Asymmetric Fix Transcription**: 1 箇所の fix が他の対称位置に伝播されない、の self-referential 版（fix コメント自体が canonical 位置との非対称を作る）
- **Observed Likelihood Gate — evidence anchor 未提示は推奨事項に降格**: reviewer 推奨値に `grep` 検証 evidence が付いていなければ盲信しない

### 対処の canonical pattern

1. **commit 前 grep self-check**: fix で新規追加 / 変更した全行に対し、プロジェクトの確立済み convention を `grep` で走査する。最低限: 行番号参照 / `if ! cmd; then rc=$?` / `mktemp \|\| echo ""` の 3 点
2. **reviewer 推奨値の evidence gate**: reviewer 提示の具体値 (ID / 閾値 / 識別子) は、採用前に必ず既存コードベースとの衝突を `grep` で検証する。推奨値盲信は 2 段階修正（cycle 2 で再発見）の主要原因
3. **fix scope の self-review**: fix 適用後、fix 自身が canonical convention を破っていないか逐語 self-review を行う。review の gate を 2 段（reviewer による検出 + self-check）にすることで cycle 2 発散を抑止する
4. **canonical convention の list 化**: プロジェクトで確立した原則（行番号参照禁止等）は reference 文書に集約し、`grep` 検証が容易な表現（`L[0-9]+` 等）で記述する

### Prose 内行番号 literal も対象

prose 散文事例の fix で確認された通り、本 anti-pattern は **fix で追加されるあらゆる散文記述** (commit message / fix コメント / PR description / 設計メモ) 内の line 番号 literal にも適用される。fix 自身が canonical convention「行番号参照禁止」を破る self-drift を防ぐには、`grep -nE 'L[0-9]+' {changed_files}` による全件 scan を fix の必須 self-check として習慣化する。コメント / 散文 / commit message のいずれにも literal `Lxxx-yyy` / `(line N)` / `at L1234` 等が混入していないか確認する。

prose 散文事例で扱われたケース: 自修正 fix 中に prose 説明文で「Lxxx-yyy」記述を生成する経路を identify。fix 適用前に prose 全体を grep し、line 番号 literal が **新規追加されていないこと** を decisive に確認することで cycle 2 発散を防げる。canonical 違反の検出 grep は fix の **commit 前最終 gate** として固定化する。

### Lint rule 追加 PR の self-meta drift

lint rule 追加 PR 事例では、新規 lint script `hardcoded-line-number-check.sh` (P-A `(line N, M)` / P-B 散文形式 / P-C `{file}:{line}` の 3 種 hardcoded line-number reference を検出) を追加する review-fix loop の中で、**当該 PR が新規導入する lint.md 内の Asymmetry note (lint.md:978) に literal 散文形式 line-number reference が混入** し、その lint script 自身の P-B/P-C パターンによって自己検出された事例を実測した。

これは「累積対策 PR の review-fix loop で fix 自体が drift を導入する fractal pattern」(fix-induced-drift-in-cumulative-defense.md) と self-drift が交差する **self-meta drift** の典型例:

- **F-ID 衝突 fix 事例**: fix が追加した **コメント内** の literal 行番号
- **prose 散文事例**: 自修正 fix 中の **prose 散文** での line 番号 literal
- **lint rule 追加 PR 事例**: 新規 **lint rule 自身** を追加する PR の prose に、その lint rule が検出する pattern 違反が混入

特に lint rule 追加 PR 事例の構造的特徴: 「rule X を強制する script を追加する PR」の prose / Asymmetry note が rule X に違反する self-referential silent regression。同 PR が lint script を test fixture (commands/**/*.md で 0 finding baseline) で検証していても、lint.md 自身の prose が baseline scan の対象に含まれていれば self-detect 可能だが、`--exclude` 等で除外されていると永続的に隠蔽される。canonical 対策:

- **lint rule 追加 PR の必須 gate**: 新規 lint rule を導入する PR の commit 前に、`bash {new-lint-script} --all` を **lint script 自身を含む commands/**/*.md** に対して実行し、self-violation を decisive 検出する
- **rule 適用範囲の明示**: 新規 lint rule の prose / Asymmetry note / 説明文に literal 行番号を書く必要がある場合、semantic name 参照 ([DRIFT-CHECK ANCHOR semantic name 参照](../patterns/drift-check-anchor-semantic-name.md)) に変換するか、その箇所を rule の `--exclude` 対象から外して self-detect 可能にする
- **review-fix loop での累積 surface**: lint rule 追加 PR 事例では 8 件の blocking findings のうち self-meta drift が main fix patterns の 1 つとして surface (cycle 2 で発見)。新規 rule 追加 PR では「rule 違反 prose の self-introduction」を review checklist の必須項目化する

### F-ID 衝突 fix 事例での実測収束軌跡

3 cycle で収束: `1 HIGH + 1 MEDIUM → 1 MEDIUM → 0 findings`

- cycle 1: F-ID 衝突 / iteration 方式非対称 (**構造的** 欠陥)
- cycle 2: **self-drift** = 修正コメント内の literal 行番号（canonical 違反の連鎖 defect）
- cycle 3: convergence

cycle 2 は cycle 1 fix 中に発生した self-drift であり、commit 前 grep self-check があれば cycle 2 自体が不要だった。self-check の省略コストは「1 review-fix cycle 分の時間 + reviewer 集中力」に相当する。

### Cycle 内 fix の「全置換」claim と置換漏れ二重検出

全置換 claim 事例の cycle 2 で commit message が「F-NN/F-XX journal markers を semantic 説明に置換」と claim したが、test ファイル全体を網羅的に scan しなかったため一部置換漏れが発生した。test-reviewer と code-quality-reviewer が独立に同一 finding を HIGH × 2 (二重検出) で検出。これは「Comment Quality Finding Gate (no_journal_comment 原則 2)」の反復違反パターン (本 anti-pattern の `lint rule self-meta drift` sub-pattern と並ぶ canonical convention 違反系統)。

教訓:

- **「全置換」claim 時の機械的検証必須化**: cycle 内 fix で「全置換」を主張する commit message を書く前に、`git diff ${base_branch}...HEAD | grep -E '\+.*F-[0-9]+'` のような **機械的 grep 検証** を必須化する。LLM が「ファイルを scan した」自己申告に依存しない
- **二重検出 reviewer cross-validation の意味**: 独立 reviewer が同一 finding を high confidence で再検出する状況は、「fix 側で grep evidence を提示せずに claim だけで通そうとしている」ことを reviewer 側が見抜いている強い signal。`Observed Likelihood Gate` の triple cross-validation 適用対象
- **SoT lint 自動化提案**: Comment Quality Finding Gate (no_journal_comment 原則 2) の反復違反は 4 PR で繰り返され、SoT (`comment-best-practices.md`) 側に lint script (`grep -E '\+.*F-[0-9]+'`) を CI 自動化することで構造的に防止する。本 wiki でも `hardcoded-line-number-check.sh` 同型の `journal-marker-check.sh` を提案する

全置換 claim 事例の cycle 3 で 2 件、cycle 4 で 1 件 (line-number drift と複合) の self-drift が累積検出され、cycle 5 で finally 0 finding 収束。本累積パターンは「commit message が claim する変換は機械検証する」doctrine の SoT 化の必要性を実証する。

### 「旧 X は Y していた」journal phrase の同 PR 別箇所残存

journal phrase 残存事例の cycle 8 で `comment-best-practices.md` 原則 2 (`no_journal_comment`) 整備 commit を landed させたが、cycle 9 で同 PR の別箇所 (script:309 / test:49) に `旧 X は Y していた` 構造の journal phrase が残存し HIGH × 2 で検出された。cycle 1-3 で導入された journal phrase が cycle 8 の sweep で取りこぼされた事例。

cycle 7 で同種違反 3 件 → cycle 9 で 2 件 → cycle 11 で 0 件と単調収束 (3 → 2 → 0)、3 reviewer (code-quality / error-handling / test) cross-validation を経て mergeable へ。`旧 X は Y していた` 形式は日本語 prose 中に自然に混入しやすく、英語前提の `grep -E 'F-[0-9]+'` 系では検出できない。

教訓:

- **整備 commit の対象 commit は cycle 全体ではなく PR 全体**: cycle 8 で「comment doctrine 整備」commit を行う場合、対象は同 cycle で touched された行に限らず、PR 全体の prose / コメントを scope に含める。`git diff ${base_branch}...HEAD` で PR 全体の追加行を出してから journal phrase を grep する
- **多言語 journal phrase の grep pattern 拡張**: `comment-best-practices.md` の no_journal_comment 禁止句リストに「日本語 / 旧版表現」(`旧 X (は|を) Y (している|していた)` 構造) を canonical 化し、`journal-marker-check.sh` 同型 lint script で `grep -E '旧[^[:space:]]+(は|を)[^[:space:]]+(している|していた)'` のような多言語パターンを CI 化する
- **shrinking convergence の signal**: 3 → 2 → 0 のような単調減少 trajectory は「整備 commit による積み残しの順次解消」を示す。drift class が cycle ごとに細粒度化せず単純減少しているなら、機械検証 (lint script) ではなく per-cycle reviewer scan で十分閉塞可能と判断できる

### テストコードのコメントでも no_journal / no_cycle_reference は MUST

テストコメント cycle 参照事例の cycle 5 で、cycle 4 で追加した TC-H6 (consume-handoff の fail-closed 回帰 test) の **コメントに `cycle-2 fix` という review cycle 番号参照が混入**していた点を code-quality reviewer が HIGH (current-pr) で検出した。「fix 自体が新たな drift (journal comment) を持ち込む」典型例で、ドッグフーディング repo では特に出やすい。対策はコメントから cycle 文脈を削除し、observability の目的のみを残す恒久記述への書き換え (1 行)。

教訓:

- **テストコードのコメントも本 anti-pattern の対象**: prose / commit message / 本体コメントだけでなく、**test fixture / assertion のコメント**でも `no_journal_comment` / `no_line_or_cycle_reference` は MUST。fix で新規追加するコメントには cycle / PR / Issue 番号や review cycle 文脈を書かず、WHY (observability の目的等) のみを stable に記述する
- **新規 diff 行の違反は scope 内で必ず修正する**: 蔓延している pre-existing パターンの retrofit (別 Issue 化可) と、**新規 diff 行が違反を導入する**ケースは区別される。後者は本 PR の責務として scope 内で必ず修正する。「既存も違反しているから」を新規違反の言い訳にしない

### 回帰テストの意図説明に「旧実装は…だった」履歴フレームが混入する

履歴フレーム事例の cycle 1 fix で追加した回帰テスト (negation-leak → DRIFT) のケースコメント 2 件が「旧実装の特定ルール文字列一致だと…偽陽性 DRIFT になっていた回帰ケース」という履歴フレームで WHY を記述し、cycle 2 で tech-writer が `no_journal_comment` (原則 2 Failure Pattern: "In the old code we used X; now we use Y") 違反の MEDIUM × 2 として検出した。特徴的なのは **同一 PR 内に正しい形と誤った形が混在**していた点 — 同じ fix で追加した別ケース (TC-9) は同じ WHY を「check-ignore -v は negation マッチでも rc=0 を返すため rc のみでは不十分」と現在形で記述しており、こちらは指摘されなかった。

教訓:

- **回帰テストの意図説明は現在形の制約文で書く**: 「現在の実装の何が、どの構成を偽陽性/偽陰性にするか」を現在形で述べる。「旧実装は…だった」の変更経緯は commit message に置く
- **コメント追加時は同 PR 内の正しい先例に揃える**: 同一 fix 内に正誤が混在するのは、ケースごとにコメントを独立に書き下ろしている signal。先に書いた正しいパターン (現在形記述) を後続ケースへ複製する方が drift しない
- **grep pattern**: `旧実装(の|は|では)` は journal phrase 残存事例で確立した多言語 journal phrase grep の対象。fix commit 前に `git diff | grep '旧実装'` で新規追加行を検査する

### 修正コメントの帰属一般化が次の category error を誘発する

帰属一般化事例では「コメントと分岐表の矛盾」(cycle 1 LOW-MEDIUM) を修正した文言自体が、cycle 2 で「pre-check を『status 行あり』群に括る帰属の category error」(MEDIUM) として再指摘された。修正コメントは「pre-check / validation の gh api 失敗では status 行あり」と経路を一般化して書いたが、status 行の有無を決めるのは後続の投稿・検証段であり pre-check ではない — コメントが動機として挙げた rate limit ではむしろ pre-check と投稿が相関失敗して status 行なしになる反例が成立した。cycle 3 の再修正で「status 行の有無は投稿・検証段が決める」と決定主体を明示する帰属に書き直して収束した。

教訓:

- **挙動を要約するコメントは「どの段が何を決めるか」の帰属を実装の emit ポイント (file:line) と突合してから書く**: 一般化した topic 文 (「gh 失敗でも status 行を出す」「X の失敗では Y あり」) は経路別の反例で崩れる。決定主体 (「Y の有無は Z 段が決める」) を主語にすると経路の組合せに対して安定する
- **修正コメントのレビューは元指摘と同じ厳密さで**: cycle 1 の指摘を解消する文言が cycle 2 の指摘源になる連鎖は、修正文言を「元の矛盾が消えたか」だけで検証し「新しい主張が全経路で真か」を検証しないことから生じる

## 関連ページ

- [canonical reference 文書のサンプルコードは canonical 実装と一字一句同期する](../patterns/canonical-reference-sample-code-strict-sync.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](./asymmetric-fix-transcription.md)
- [Observed Likelihood Gate — evidence anchor 未提示は推奨事項に降格](../heuristics/observed-likelihood-gate-with-evidence-anchors.md)
- [DRIFT-CHECK ANCHOR は semantic name 参照で記述する（line 番号禁止）](../patterns/drift-check-anchor-semantic-name.md)
- [累積対策 PR の review-fix loop で fix 自体が drift を導入する](./fix-induced-drift-in-cumulative-defense.md)

## ソース

- [PR #578 cycle 2 review (self-drift detection)](../../raw/reviews/20260418T114056Z-pr-578.md)
- [PR #578 cycle 2 fix (2 段階修正)](../../raw/fixes/20260418T114231Z-pr-578.md)
- [PR #617 fix (prose 内行番号 literal scope 拡張)](../../raw/fixes/20260420T043015Z-pr-617-fix1.md)
- [PR #671 fix (新規 lint rule 自身の self-meta drift)](../../raw/fixes/20260426T015356Z-pr-671.md)
- [PR #756 cycle 3 review (journal marker 二重検出 HIGH × 2)](../../raw/reviews/20260501T012144Z-pr-756.md)
- [PR #756 cycle 4 fix (全置換 claim の機械検証必須化)](../../raw/fixes/20260501T020145Z-pr-756.md)
- [PR #1161 cycle 9 review (`旧 X は Y していた` journal phrase の同 PR 別箇所残存 HIGH × 2)](../../raw/reviews/20260527T082452Z-pr-1161.md)
- [PR #1161 cycle 11 review (3 → 2 → 0 単調収束で mergeable)](../../raw/reviews/20260527T083107Z-pr-1161.md)
- [PR #1169 fix results (cycle 5) — TC-H6 のコメントに混入した `cycle-2 fix` review cycle 番号参照を削除し observability 目的のみの恒久記述へ。テストコードのコメントも no_journal / no_cycle_reference MUST、新規 diff 行の違反は scope 内修正](../../raw/fixes/20260528T144526Z-pr-1169.md)
- [PR #1836 fix results (cycle 2) — 回帰テストのケースコメント 2 件の「旧実装は…だった」履歴フレームを現在形の技術的 WHY へ書き換え。同一 PR 内に正しい現在形記述と誤った履歴フレームが混在した事例](../../raw/fixes/20260712T150908Z-pr-1836.md)
- [PR #1838 review results (4 cycles) — F-01 修正文言が F-03 帰属 category error を誘発した連鎖。決定主体を主語にした帰属への書き直しで収束](../../raw/reviews/20260712T174329Z-pr-1838.md)

## 変種: 行番号アンカーは「導入コミット内で自壊する」

コメントから他ファイルの行番号を参照する self-drift には、**書いた瞬間に既に誤りになっている**という極端なケースがある。参照を導入したコミット自体が参照先ファイルに行を足すと、コミット適用後には参照先がシフトしている。

実例では、テストコメントが hook の行番号を裸で参照していたが、**同じコミットが header に 8 行・診断コメントに 13 行を足した**ため、コミット時点で既にずれていた。しかも検出機構がファイル名接頭辞を要求する regex だったため、同一文脈内の裸の `:NNN` 形式は機械検出を素通りしていた。

### 対処

- 他ファイルを指すときは行番号ではなく**一意な文字列**（シンボル名 / 定数名 / メッセージの一部）をアンカーにする
- 同一コミットで両方のファイルを触る修正では特に危険。「行番号は commit 適用後の値である保証がない」と考える
- semantic anchor（「〜のブロック」「〜の 2 行」）で書けば、上流に行が増えても壊れない

### 併発する self-drift: 規則と反例の同時導入

同じ性質の失敗として、**規則をコメントに書きながら同じ diff でその規則を破る**ケースがある。「caller を列挙して説明しない」と書きつつ、同一ファイル内の 2 箇所で caller を列挙していた実例がある。規則と反例が同時に入ると、保守者は「規則に従って直す」か「規則を無効と見なす」の二択を迫られ、どちらもコストになる。**規則を書いたらファイル全体へ適用しきってから commit する。** 適用しきれないなら規則の scope を明示する（「本コメントでは」等）。

## ソース（追記分）

- [PR #2094 review results (cycle 4) — 行番号コメントが同一コミット内で自己矛盾](../../raw/reviews/20260803T020301Z-pr-2094.md)
- [PR #2094 review results (cycle 3) — 6 件中 4 件が前 cycle の fix で追加したコメント由来](../../raw/reviews/20260803T051521Z-pr-2094.md)
