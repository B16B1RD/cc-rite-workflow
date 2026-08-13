# /rite:unknowns — 設計理由

`skills/unknowns/SKILL.md` から退避した rationale（設計理由・背景・過去の障害）。本体は各該当箇所に
`rationale: references/rationale.md#<anchor>` の 1 行ポインタだけを残す。

ここにあるのは **why** のみ。分岐表・sentinel 一覧・bash ブロックといった実行時に必要な機械
インターフェースは本体が SoT であり、本ファイルへ複製しない。

## field-guide

プロンプトや計画は「地図」、実際のコードベースと制約は「現地」。その差分 = unknowns が大きいまま
実装に入ると手戻りが高くつく。出典: Thariq Shihipar (Anthropic) "A Field Guide to Fable: Finding
Your Unknowns" (2026)。右列（既知の未知・未知の未知）と左下（見れば分かる系）を、実装より安い
コストで左上に移す。

## no-implement-in-session

探索中に本実装へ進むと、未確定の前提がコードに固定され探索が慎重になる。実装は別セッション・
別ワークフローの仕事。

## brainstorm-for-reaction

目的はユーザーに決めさせることではなく反応してもらうこと。「A の手軽さは魅力だが B のこの部分は
欲しい」という反応こそが、言語化されていなかった要件（未知の既知）を表面化させる。

## prototype-disposable

流用前提になるとプロトタイプが慎重になり、探索の速度が死ぬ。Artifact は CSP で外部送信できない
ため、フィードバックはコピペの橋渡しになる。

## summary-as-handoff

探索したのにサマリがないと、発見が次のセッションに引き継がれず探索が無駄になる。議事録ではなく
次の作業者（未来の自分や別セッションの Claude を含む）への引き継ぎ書として書く。
