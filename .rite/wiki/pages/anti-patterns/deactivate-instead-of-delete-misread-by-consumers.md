---
type: "anti-patterns"
title: "state を削除せず無効化して残すと、無効化を完了の印として読む既存 consumer が中断を完了と読み違える"
domain: "anti-patterns"
description: "作業途中の state を削除していた経路を、無効化して残す形に変えると、無効化された形を完了の印として読んでいた別の consumer が、中断を完了と誤読する。書き込み側を変えるときは、その形を読む consumer を全部洗い出し、完了と中断を区別できる既存のフィールドを判定に加える。"
created: "2026-09-28T09:47:59Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-28T09:47:59Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260928T084811Z-pr-3391.md"
  - type: "fixes"
    resource: "raw/fixes/20260928T090234Z-pr-3391.md"
tags: ["state", "consumer", "deactivate", "hook", "batch"]
confidence: high
promote: rite-plugin
---

# state を削除せず無効化して残すと、無効化を完了の印として読む既存 consumer が中断を完了と読み違える

## 概要

作業途中の state を削除していた経路を、無効化して残す形に変えると、無効化された形を完了の印として読んでいた別の consumer が、中断を完了と誤読する。書き込み側を変えるときは、その形を読む consumer を全部洗い出し、完了と中断を区別できる既存のフィールドを判定に加える。

## 詳細

セッション終了時に作業途中の flow-state を削除していた hook を、`active=false` にして残す形に変えた。resume したときに state を読み戻せるようにするためである。ところが batch の watchdog は、`phase=cleanup` かつ `active=false` を cleanup 完了の印として読んでいた。cleanup の途中でセッションを終えて resume すると、残った state が完了と同じ形になり、watchdog は次の Issue へ進むよう指示した。残りの cleanup（Issue の close・ブランチの削除など）は飛ばされた。変更前は state が消えていたので、同じ入口では最初から判定し直していた。

直し方は次のとおり。

- 無効化した形（ここでは `active=false`）を完了の意味で読む consumer を、全部洗い出す。
- 新しいキーを足す前に、既存の書き込み経路が何を書いているかを確かめる。ここでは cleanup の完了はどの経路でも `next_action=none` を書き、無効化する hook は `active` だけを変えて `next_action` を残していた。そこで判定を「`active=false` かつ `next_action=none`」に絞った。
- 完了形を模したテスト fixture は、実際の完了経路が書く形（`active=false` だけでなく `next_action=none` も）に合わせる。形が一部だけ一致する fixture は、判定条件を絞ったときに誤った側を固定してしまう。
- hook の連携の不具合は、実際の順序（セッション終了 → resume 時の開始 → 停止）で hook を順に流すテストで固定する。session を payload ではなくファイルから解決する hook があるので、fixture にそのファイルも置く。

## 関連ページ

- [既存の永続データを新規 consumer が読むときは、集合の意味を書込側の定義から引く](../heuristics/persisted-collection-semantics-from-writer-not-name.md)
- [共有リソースの type/名前空間を再利用する新機能は、既存消費者のコード内契約（コメント明示の不変条件）を見落として生存中のリソースを破壊しうる](./shared-resource-type-reuse-without-consumer-contract-check.md)

## ソース

- [無効化した state を watchdog が完了と読み違えることを示したレビュー結果](../../raw/reviews/20260928T084811Z-pr-3391.md)
- [完了時にだけ書かれる既存フィールドで完了と中断を区別した fix 結果](../../raw/fixes/20260928T090234Z-pr-3391.md)
