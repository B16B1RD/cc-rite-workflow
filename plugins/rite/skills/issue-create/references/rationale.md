# /rite:issue-create — 設計理由

`skills/issue-create/SKILL.md` から退避した rationale（設計理由・背景・過去の障害）。本体は各該当箇所に
`rationale: references/rationale.md#<anchor>` の 1 行ポインタだけを残す。

ここにあるのは **why** のみ。分岐表・sentinel 一覧・bash ブロックといった実行時に必要な機械
インターフェースは本体が SoT であり、本ファイルへ複製しない。

## ask-only-user-unique

質問はユーザーの頭の中にしかない情報に限定する。リポジトリ・Wiki から導出可能な情報はモデルが
探索で自己解決する。探索サマリ検出時に 4.0/5.0 を丸ごと skip しない理由は
`unknowns-boundary-rationale.md`。

## sentinel-html-comment

sentinel は hook / grep 契約のため必須だが、HTML コメント化することでユーザーに「完了したのか
途中なのか」の判別を阻害しない。user-visible な末端は `✅ ...` 完了メッセージ。

## no-flow-state

本コマンドは Issue 作成のみで work phase を持たず、flow-state を init / 所有しない。別の active
な work フロー（`/rite:open` 等）の途中で sub-task として呼ばれたとき、親セッションの flow-state
を誤って上書きしない。

## decompose-three-stage

親作成・Sub 一括作成・link・fetch を helper に委譲し、LLM は Write tool で body を raw ファイル化
する。heredoc malform 源を撤廃するため。親 complexity は helper 内で `XL` 固定。

## fact-check-before-create

4.2.1 / 5.1.1 は作成・ユーザー確認の前に検証する。記憶・推測での `VERIFIED` は reference が禁じる
経路。分解パスは 4.1 を通らないが、親仕様書は親 Complexity が `XL` 固定のため 3 クラスすべてを
検査範囲とする。
