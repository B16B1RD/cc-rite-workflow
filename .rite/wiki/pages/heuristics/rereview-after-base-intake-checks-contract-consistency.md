---
type: "heuristics"
title: "base 取り込み後の再レビューは、同じ差分の再確認ではなく取り込み側との契約整合の確認として指示する"
domain: "heuristics"
description: "前回レビュー以降の差分が base の取り込みだけのとき、差分スコープは空になりフルレビューへ倒れる。そのまま同じ指示を渡すと再レビューは同じ差分の再確認に終わる。取り込みで変わった base 側ファイルと PR が触れた契約の矛盾を探すよう指示すると、再レビューが取り込み後の整合確認になる。"
promote: rite-plugin
created: "2026-09-26T10:50:02Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-26T10:50:02Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260926T104438Z-pr-3137.md"
tags: ["review-scope", "base-intake", "re-review", "cross-file-impact", "wiki-apply-evidence"]
confidence: medium
---

# base 取り込み後の再レビューは、同じ差分の再確認ではなく取り込み側との契約整合の確認として指示する

## 概要

前回レビュー以降の差分が base の取り込みだけのとき、差分スコープは空になりフルレビューへ倒れる。そのまま同じ指示を渡すと再レビューは同じ差分の再確認に終わる。取り込みで変わった base 側ファイルと PR が触れた契約の矛盾を探すよう指示すると、再レビューが取り込み後の整合確認になる。

## 詳細

base の CI 失敗を直すために develop を PR へ取り込むと、PR 固有の差分は変わらないのに HEAD は進む。レビュー済みの commit と HEAD が一致しなくなるため、Ready・merge のゲートは再レビューを要求する。このときの再レビューで確認すべき新しい事実は、PR の差分そのものではなく「取り込みで base 側が変えたファイルが、PR の変えた契約と両立しているか」である。

そこで reviewer への指示には、前回からの差分が base 由来だけであることと、取り込みで変わった主なファイル名を明記し、PR が触れた契約（手順・sentinel・引き渡し規約など）と取り込み後の base 側の記述が矛盾しないかを Cross-File Impact Check の範囲で確認させる。実測では 3 名の reviewer がいずれも取り込み差分を読み、PR の契約に触れていないこと（あるいは既存契約を広げるだけであること）を根拠付きで報告し、再レビューが空振りの儀式にならなかった。

同じ取り込みでは、作業メモリの Wiki 適用証跡も古くなる。証跡は capture 時点の HEAD を記録しており、HEAD が進むと review 側のゲートは `stale_head` で止まる。適用したページがない証跡（`status: none`）なら失う判断材料がないため、capture を取り直して HEAD を更新すれば足りる。適用ページがある証跡は、ページ本文と差分を突き合わせ直してから取り直す。

## 関連ページ

- [検査を独立した段落ではなくゲート段落自体へ統合すると、再回収経路にも自動で効く](./gate-paragraph-consolidation-covers-retry-paths.md)

## ソース

- [レビュー結果](../../raw/reviews/20260926T104438Z-pr-3137.md)
