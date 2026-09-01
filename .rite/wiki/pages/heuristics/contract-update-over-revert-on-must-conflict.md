---
type: "heuristics"
title: "実装が Issue の MUST と原則の両方に挟まれたら、実装を戻さず契約側（Decision Log と AC の例外）を更新する"
domain: "heuristics"
description: "純粋抽出リファクタの「振る舞い不変」MUST と fail-loud 原則のように、実装を直すことが別の MUST 違反になる衝突では、実装を機械的に復元しても同じ reviewer が同じ指摘を再発行する往復になる。契約側へ例外を明記して閉じるほうが収束する。"
created: "2026-09-01T20:26:00+09:00"
generated: { by: "rite-wiki-ingest/claude-opus-5[1m]", at: "2026-09-01T20:26:00+09:00" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260901T092252Z-pr-2498.md"
  - type: "fixes"
    resource: "raw/fixes/20260901T092936Z-pr-2498.md"
  - type: "reviews"
    resource: "raw/reviews/20260901T095150Z-pr-2498.md"
tags: []
confidence: high
---

# 実装が Issue の MUST と原則の両方に挟まれたら、実装を戻さず契約側（Decision Log と AC の例外）を更新する

## 概要

純粋抽出リファクタの「振る舞い不変」MUST と fail-loud 原則のように、実装を直すことが別の MUST 違反になる衝突では、実装を機械的に復元しても同じ reviewer が同じ指摘を再発行する往復になる。契約側へ例外を明記して閉じるほうが収束する。

## 詳細

**衝突の形**: 純粋抽出 Issue が「振る舞いは抽出前と完全に一致すること」を MUST として掲げているとき、抽出作業中に silent fallback を見つけて fail-loud へ直すと、その改善自体が MUST 違反になる。逆に改善を revert すると、プロジェクト原則（fallback より fail-loud）の側に違反が残る。どちらへ倒しても reviewer が指摘できる状態になり、cycle を跨いで往復する。

**閉じ方**: 実装は残し、契約側を 3 点セットで更新する。

1. Issue の Decision Log に例外エントリを足す（何を・なぜ・どの範囲で逸脱するか）
2. 対応する AC の `Then` に例外を明記する
3. テスト名またはテストコメントから当該 Decision Log ID を辿れるようにする

PR #2498 では、分類 helper 失敗時の marker 値を `none` から `unknown` へ変えた逸脱がこの形で閉じた。前 cycle に CRITICAL を出した reviewer 自身が次 cycle で FIXED と判定している。往復を止めたのは revert ではなく契約の明文化だった。

**判断の後押しになる signal**: 4 レビュアーのうち 3 者が独立に同じ逸脱を認定し、対応方針は全員「revert せず記録」で一致した。独立した複数 reviewer の一致は、契約更新という（一見すると「指摘を実装で直さない」に見える）選択の妥当性を支える。

**落とし穴 — 例外は書く場所が増えるほど不一致の面が増える**: 例外文を複数箇所へ書くとき、適用範囲の記述を全箇所で揃える。PR #2498 では §3.3 の例外括弧を 2 軸で、AC-8 の Then を 3 軸で書いたところ、次の cycle で「契約文書内で例外の適用範囲が食い違う」と別 reviewer に指摘された。例外の軸（対象・条件・派生箇所の数）を 1 つの文言に固定し、各所へは同じ文言を転記する。

**revert を選んだ場合の検証 baseline は「導入 commit の親」**: 逆に実装を戻す判断をしたときは、`develop` との照合で検証してはならない。当該 call site が `develop` に存在しない（この PR で初めて入った）場合、その照合は成立しない。最も強い証拠は `git diff <その hunk を導入した commit の親>..HEAD -- <file>` が空であること。

## 関連ページ

- [インライン処理の helper 抽出は「helper が起動しない」経路を新設し、marker 不在＝成功の消費規則を破る](../anti-patterns/helper-extraction-creates-unstarted-path.md)
- [汎用契約の表に経路固有の詳細を書かず下位節へ委譲する。ただし委譲は委譲先の網羅性を load-bearing にする](./generic-contract-table-delegates-path-specific-detail.md)

## ソース

- [PR #2498 review results](../../raw/reviews/20260901T092252Z-pr-2498.md)
- [PR #2498 fix results](../../raw/fixes/20260901T092936Z-pr-2498.md)
- [PR #2498 review results (cycle 2)](../../raw/reviews/20260901T095150Z-pr-2498.md)
