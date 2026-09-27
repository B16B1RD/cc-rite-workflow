---
type: "heuristics"
title: "記録の同定 marker は、正規の経路で重複しうる軸をすべてキーに含める"
domain: "heuristics"
promote: rite-plugin
description: "記録が既に書かれたかを marker で判定するとき、キーに含めない軸で同じ値が正規に繰り返されると、2 件目の記録が 1 件目と同一とみなされて書かれない。同定キーは、正規経路で同じ値のまま進みうる軸まで含めて作る。"
created: "2026-09-27T11:35:00Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T11:35:00Z" }
sources:
  - type: "fixes"
    resource: "raw/fixes/20260927T112450Z-pr-3267.md"
tags: ["identity", "work-memory", "review"]
confidence: medium
---

# 記録の同定 marker は、正規の経路で重複しうる軸をすべてキーに含める

## 概要

記録が既に書かれたかを marker で判定するとき、キーに含めない軸で同じ値が正規に繰り返されると、2 件目の記録が 1 件目と同一とみなされて書かれない。同定キーは、正規経路で同じ値のまま進みうる軸まで含めて作る。

## 詳細

レビューの記録が作業メモリに載ったかを、run と commit から作った marker で判定していた。同じ commit を再レビューする経路は run を引き継ぐ正規の経路なので、fix-needed の cycle のあとに同じ commit で mergeable を閉じると、2 件目の記録は 1 件目と同じ marker になり、追記されないまま完了扱いになった。marker を run・cycle・commit の全キーで作り直すと、cycle ごとに記録が区別される。

- 同定キーを決めるときは、正規経路で同じ値のまま次の記録へ進みうる軸（同一 commit の再実行、同一 run の継続など）を列挙し、すべて含める
- 回帰テストは「同じ commit で 2 件目を閉じると 2 件目の記録が載る」形で固定し、marker からキーを 1 つ外す変異で落ちることを確かめる
- 追記後の再取得に失敗したときは、記録不在と区別して報告する。終了コードが正しくても診断文が混同すると、原因の切り分けを誤らせる

## 関連ページ

- [同定に使う needle は位置まで固定し、人間が複製できる文字列を使わない](../anti-patterns/identity-needle-position-and-machine-only-sentinel.md)
- [構造化レコードの部分更新は全行再生成へ置き換え、同定述語をキー位置まで anchor する](../patterns/structured-record-full-row-regeneration-with-anchored-key.md)

## ソース

- [記録の同定キーを文脈の全キーで作り直した fix 結果](../../raw/fixes/20260927T112450Z-pr-3267.md)
