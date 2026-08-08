---
type: "patterns"
title: "独立した判定層は既存層の分岐の内側に置かない — 層ごとに別 marker を持たせ可否は failure marker の不在で決める"
domain: "patterns"
promote: rite-plugin
description: "新設した検査層を既存 marker 検査の一 arm の内側に置くと、守るべき failure mode でその既存層が degraded に降りたときに新層が一度も走らない。新層の入力が既存層に依存していなくても、配置だけで従属する。層は分岐の外に出し、入力の依存関係だけで実行可否を決め、層ごとに別 marker 名を持たせて gate 全体の可否は failure marker の不在で判定する。"
created: "2026-08-07T18:40:00+09:00"
updated: "2026-08-07T18:40:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260807T011214Z-pr-2130.md"
  - type: "fixes"
    ref: "raw/fixes/20260807T013056Z-pr-2130.md"
tags: []
confidence: high
---

# 独立した判定層は既存層の分岐の内側に置かない — 層ごとに別 marker を持たせ可否は failure marker の不在で決める

## 概要

既存の gate に新しい検査層を足すとき、新層を既存層の `case` の 1 arm の内側に書くと「既存層が degraded に降りる状態」で新層が一度も走らない。新層の入力が既存層の値に一切依存していなくても、**配置だけで従属する**。しかも降りる条件は、たいてい新層が守ろうとしている failure mode そのものである。

## 詳細

PR #2130 で cycle 1 の blocking 7 件が出たが、根は 1 つだった — **新設した検査層を既存層の「付録」として設計し、既存層の分岐条件をそのまま継承させた**こと。

**何が起きたか**: 「本 cycle の結果 JSON が実在するか」を確かめる positive 検査を、既存の marker 検査の「marker 不在」arm の内側に置いた。ところが守るべき failure mode（区間ごと skip）では marker 値そのものが空文字 / 未置換になり、marker 層が degraded に降りる。degraded の arm は `*)` ではないので、positive 検査は一度も実行されない。**判定できるのに降ろしていた**。3 reviewer が独立に検出した。

これは「gate を守る対象の内側に置くな」の変種で、今回は **「独立な判定を従属分岐の内側に置くな」**。

**なぜ自然にこうなるか**: 新機能を既存コードへ足すとき、関連する既存ロジックの近くに書くのが読みやすい。`case` の中に既にある arm は「この状況の処理をここに書く」という誘導になっている。入力の依存関係を意識的に問わないかぎり、物理的な近さが論理的な従属にすり替わる。

**対処 (3 点セットで適用する)**:

1. **新しい判定層は既存層の分岐の外に置く**。実行可否は**入力の依存関係だけ**で決める。「この層は既存層のどの出力を読むか」を書き出し、答えが「読まない」なら分岐の外が正しい位置
2. **層ごとに別の marker 名を持たせる**。層を独立させた結果、helper が `GATE=pass` を名乗ると degraded に降りた層の直後に pass が重なり、「degraded を pass と読み替えるな」という caller 規則と観測値が食い違う。層ごとに marker を分ければこの衝突は構造的に起きない
3. **gate 全体の可否は `*_FAILED` marker の不在で決める**。「pass marker が出たか」で判定すると、層が増えるたびに pass の意味が曖昧になる。失敗の不在で決めれば層の追加が既存判定を壊さない

**判定の目安**: 新しい検査を足したとき、その検査が読む変数の一覧に既存層の出力が 1 つも無いのに、コードが既存層の分岐の内側にあるなら誤配置。「守ろうとしている failure mode をシミュレートしたとき、新しい検査は走るか」を実測する — 走らないなら配置が原因である可能性が高い。

## 関連ページ

- [前提条件の silent omit が AND 論理の防御層チェーンを全体無効化する](../anti-patterns/silent-precondition-omit-disables-and-defense-chain.md)
- [機械強制の anchor を強制される側が選べる値にすると、2 層の gate が同一の誤りで同時に無効化される](../anti-patterns/enforcement-anchor-chosen-by-enforced-party.md)

## ソース

- [PR #2130 review results](../../raw/reviews/20260807T011214Z-pr-2130.md)
- [PR #2130 fix results](../../raw/fixes/20260807T013056Z-pr-2130.md)
