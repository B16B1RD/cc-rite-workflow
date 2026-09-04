---
type: "anti-patterns"
title: "glob で集合を指すと、集合の増減に silent に追随しない — 診断・分岐の述語には明示列挙を使う"
domain: "anti-patterns"
description: "エラー分類の集合（例: 「caller 契約違反である本文検査 4 段」）を、判定述語として `reason=body_*` のような **glob（接頭辞パターン）で指す**と、集合と glob の一致は保証されない。"
created: "2026-07-28T21:30:00+09:00"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260728T122258Z-pr-2038.md"
  - type: "reviews"
    resource: "raw/reviews/20260728T081222Z-pr-2038.md"
  - type: "reviews"
    resource: "raw/reviews/20260813T081206Z-pr-2304.md"
  - type: "fixes"
    resource: "raw/fixes/20260813T081923Z-pr-2304.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-13T19:20:00+09:00" }
---

# glob で集合を指すと、集合の増減に silent に追随しない — 診断・分岐の述語には明示列挙を使う

## 概要

エラー分類の集合（例: 「caller 契約違反である本文検査 4 段」）を、判定述語として `reason=body_*` のような **glob（接頭辞パターン）で指す**と、集合と glob の一致は保証されない。ずれは **2 方向**に起きる。

- **取りこぼし**: 命名規則に合わない既存要素（`count_body_mismatch`）が hit しない
- **過剰一致**: 後から追加された別集合の要素（`body_check_unavailable`）が hit する

**命名規則と集合の境界は独立に変化する。** 命名は可読性や語順で決まり、集合の境界は意味論で決まるので、両者が一致し続ける保証はどこにもない。

## 詳細

### 実例

gate の ERROR ACTION が、caller 契約違反を判別する述語として glob を使っていた。

```
ACTION: まず会話に [CONTEXT] NONBLOCKING_RECORD_FAILED=1; reason=body_* があるか確認してください。
        あれば caller 契約違反です — 本文を作り直してから再実行します。
        無ければ 6.1.d 自体が未実行です。
```

対象の集合は 4 要素だった: `body_file_empty` / `body_marker_missing` / `body_sentinel_missing` / `count_body_mismatch`。

- `count_body_mismatch` は **4 段の 1 つで、gate の ERROR を確定的に発火させる**のに `body_` で始まらないため hit しない → LLM は「6.1.d 自体が未実行」という**誤った原因を報告書に転記**する
- 後の cycle で追加した `body_check_unavailable`（環境起因、差し戻さない）は glob に hit する → 「本文を作り直せ」という**正反対の復旧手順**を指示する

決定的なのは、**同一ファイル内で矛盾していた**こと。別の箇所が「`count_body_mismatch` では gate の Pre-Check が差し戻す」と明記しているのに、その gate の診断述語が当該 reason を見られない構造になっていた。

```
$ printf 'reason=count_body_mismatch\nreason=body_check_unavailable\n' | grep -c 'reason=body_'
1        ← hit は body_check_unavailable のみ。逆方向にずれている
```

### 対処

**明示列挙に置き換え、対象外も併記する。**

```
ACTION: reason=body_file_empty / body_marker_missing / body_sentinel_missing /
        count_body_mismatch のいずれかがあるか確認してください
        (body_check_unavailable は対象外 — 環境起因で marker を残しません)。
```

対象外の併記が重要で、これが無いと「列挙に無い = 未定義」なのか「列挙に無い = 対象外」なのかを読み手が判別できない。

### 適用範囲

glob が問題になるのは**判定述語**として使う場合であり、grep での探索や人間向けの概説では実害が小さい。分ける基準は「その一致結果が分岐や報告内容を決めるか」。

- 分岐・診断・転記条件 → **明示列挙**（対象外も書く）
- 探索補助・概説 → glob でよい

### ファイル集合を指す glob でも同じ穴が開く

判定述語だけでなく、**検査対象のファイル集合を指す glob** でも取りこぼしが起きる。決定論レンダリングの契約チェックは `for scene in scenes/*.html` で全シーンを走査していたが、英語版シーン 7 本を新設した `scenes-en/` は glob の外にあり、**英語シーンだけが契約ガードの対象集合から抜けた**。

決定的なのは、同じ PR の設計文書に「契約ガードを 1 組に保つため同一ディレクトリへ置く」と書いた直後に、その主張が実装で成立していない状態になっていたこと。glob は「ディレクトリを 1 つ増やす」という変更に silent で、追加したファイル側にも既存 glob 側にも警告は出ない。

対処は glob の明示列挙化（`for scene in scenes/*.html scenes-en/*.html`）。**sibling ディレクトリを新設したら、既存の走査 glob を grep で洗い出す**のが、この方向の drift に対する唯一の機械的な手当てになる。

### 一般化

- 集合を指す述語を書くとき、**その集合の全要素を数え、glob が過不足なく一致するか**を確かめる
- 集合に要素を足すとき、**その集合を参照している述語を grep で洗い出す**。glob だと「更新不要に見えて実は壊れる」ため、明示列挙のほうが drift が可視になる
- 命名規則を集合の定義に流用しない。命名は変わる

## 関連ページ

- [エラーを 1 つの reason へ畳むときは「原因の類型」が同じかを確かめる](../heuristics/error-classification-by-cause-not-detection-site.md)
- [新規 exit 1 経路 / sentinel type 追加時は同一ファイル内 canonical 一覧を同期更新する](../heuristics/canonical-list-count-claim-drift-anchor.md)
- [カテゴリ列挙の圧縮はブロッキング/informational の分類を SoT で確認してから削る](../heuristics/enumeration-compression-verify-blocking-classification.md)

## ソース

- [fix 結果](../../raw/fixes/20260728T122258Z-pr-2038.md)
- [レビュー結果](../../raw/reviews/20260728T081222Z-pr-2038.md)
- [新設 `scenes-en/` が決定論スイープ glob の外に落ちた](../../raw/reviews/20260813T081206Z-pr-2304.md)
- [スイープ glob を明示列挙して sibling ディレクトリを取り込んだ](../../raw/fixes/20260813T081923Z-pr-2304.md)
