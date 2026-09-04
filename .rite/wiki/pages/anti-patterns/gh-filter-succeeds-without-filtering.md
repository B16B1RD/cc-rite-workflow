---
type: "anti-patterns"
title: "gh のフィルタオプションは絞り込めていないのに成功して見える"
domain: "anti-patterns"
description: "gh の検索・一覧オプションは exit 0 と JSON を返す一方で、呼び出し側が期待した絞り込みを静かに捨てる。boolean qualifier への番号付与、exact-match オプションへの glob、件数 limit の窓いっぱいは、いずれも「絞り込めていないのに成功して見える」同じ欠陥クラスである。"
created: "2026-09-02T00:50:00Z"
generated: { by: "rite-wiki-ingest/grok-4.6", at: "2026-09-03T01:10:00Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260901T133013Z-pr-2500.md"
  - type: "reviews"
    resource: "raw/reviews/20260901T140807Z-pr-2500.md"
  - type: "fixes"
    resource: "raw/fixes/20260901T134035Z-pr-2500.md"
  - type: "reviews"
    resource: "raw/reviews/20260903T003746Z-pr-2531.md"
tags: []
confidence: high
---

# gh のフィルタオプションは絞り込めていないのに成功して見える

## 概要

gh の検索・一覧オプションは exit 0 と JSON を返す一方で、呼び出し側が期待した絞り込みを静かに捨てる。boolean qualifier への番号付与、exact-match オプションへの glob、件数 limit の窓いっぱいは、いずれも「絞り込めていないのに成功して見える」同じ欠陥クラスである。

## 詳細

観測された 3 形は見た目が違うが、呼び出し側が「空 / 非空 / 件数」を判定表に載せると検知できない点で同じである。

1. **boolean qualifier に番号を付けても捨てられる。** `--search "linked:issue:{N}"` の `linked:issue` は boolean であり `:{N}` は無視される。存在しない番号でも同じ集合が返る。破壊的判断（ブランチ削除・worktree 削除）の入力に使うと、対象外の PR を掴む。
2. **exact-match オプションは glob を解釈しない。** `--head "*issue-{N}*"` は常に空を返す。空を「該当なし」と読むと、実在する head を見逃して別経路へ倒れる。
3. **limit 窓いっぱいは「全部取れた」ではない。** `--search` を退けた代わりに `--limit 100` を置くと、最新 100 件の窓に対象が無いときも「0 件」に見える。取得件数が limit と等しいときは「0 件」と結論せず fail-loud で止めるのが、機構を増やさずに済む最小の対処。

確実な経路は、実ブランチ名を先に確定させて exact `--head` を引くことである。ブランチが未確定なら Issue timeline（`cross-referenced` / `connected`）から PR を取る。`--state all --limit 100` の窓で代用してはならない（3 の limit 窓と同じ欠陥になる）。フィルタの契約はヘルプ文面ではなく、既知の失敗入力（存在しない番号・glob 文字・limit ちょうど）で 1 回当てて確かめる。

参照実装からコピーするとき、元が集計表にしか使っていなかった形を破壊的判断へ流用すると、同じ失敗が CRITICAL に格上げされる。コピー先で「空 / 非空を何の判断に使うか」を先に見る。兄弟スキルの片側だけ直しても、残った側は同じ入力で同じ失敗を返す。

## 関連ページ

- [検出器が「走査できなかった」を「問題なし」に畳むと、ガードが黙って無検査になる](./checker-conflates-unscannable-with-clean.md)
- [全滅形だけを想定したガード条件は部分欠損形を必ず取り逃す](./total-failure-only-guard-misses-partial-loss.md)

## ソース

- [レビュー結果](../../raw/reviews/20260901T133013Z-pr-2500.md)
- [レビュー結果](../../raw/reviews/20260901T140807Z-pr-2500.md)
- [fix 結果](../../raw/fixes/20260901T134035Z-pr-2500.md)
- [レビュー結果](../../raw/reviews/20260903T003746Z-pr-2531.md)
