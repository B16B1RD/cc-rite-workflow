# /rite:issue-edit — 設計理由

`skills/issue-edit/SKILL.md` から退避した rationale（設計理由・背景・過去の障害）。本体は各該当箇所に
`rationale: references/rationale.md#<anchor>` の 1 行ポインタだけを残す。

ここにあるのは **why** のみ。分岐表・sentinel 一覧・bash ブロックといった実行時に必要な機械
インターフェースは本体が SoT であり、本ファイルへ複製しない。

## vs-issue-update

`issue-update` は作業メモリ、`issue-edit` は Issue 本体（title / body / Projects fields）。混ぜると
進捗メモと仕様変更が同じコマンドに載り、確認境界が崩れる。

## fact-check-own-question

fact-check は Phase 3.2 の確認に折り込まない。reference の per-call item limit と overflow 規則を
そのまま適用するため。limit は `AskUserQuestion` 1 回あたりであり総予算ではない。fact-check の
決定を先に確定してから、ユーザーに編集の承認を求める。

承認結果を `{new_body}` に反映したあと 3.1 の diff を再表示するのは、3.2 が承認する対象と 4.1 が
書く対象を post-check 本文に揃えるため。再実行はしない。annotation-only でも再表示する。

## class3-scope

自己矛盾候補は verdict 軸では上表と直交するが、発火条件は直交しない。`M 以上` のときだけ
class 3 がスコープに入る。Complexity 無しで number-reference に狭めたときは class 3 も外す。
class 3 の定義は reference が単一なので、両 consumer が揃う。

## annotated-claim-recheck

「要確認」/「要検証」が既にあっても annotation ステップだけ skip し、検証は走らせる。marker は
「かつて検証不能だった」記録であり、今の文面については何も言わない。rewrite した annotated
claim は再検査する。同じ session で決着済みの項目は body から推論しない — `そのまま続行` は
marker を残さないので、body-only guard だと Phase 3.2 / 5.2 の再入で毎回聞き直す。

## option-ids-from-api

option ID は常に API から取る。`field_ids` で指定できるのは field ID だけ。
