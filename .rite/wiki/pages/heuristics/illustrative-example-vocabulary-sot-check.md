---
type: "heuristics"
title: "doc の例示語彙は定義元 (SoT) と突合してから書く"
domain: "heuristics"
promote: rite-plugin
description: "docstring / SPEC / コメントの「例示」(e.g. 〜等) に使う語彙が、別レイヤで定義された用語だと、実体のない帰属を doc に固定してしまう。"
created: "2026-07-13T02:50:00+09:00"
updated: "2026-07-13T02:50:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260712T174329Z-pr-1838.md"
tags: ["doc-accuracy", "sot-verification", "illustrative-example", "attribution"]
confidence: medium
---

# doc の例示語彙は定義元 (SoT) と突合してから書く

## 概要

docstring / SPEC / コメントの「例示」(e.g. 〜等) に使う語彙が、別レイヤで定義された用語だと、実体のない帰属を doc に固定してしまう。例示語彙は定義元文書 (SoT) の該当レイヤの定義と突合し、必要なら writer 経路の grep で実在を確認してから書く。

## 詳細

起点事例で work-memory-update.sh の新規 docstring が「local file の `## Detail` 以下に蓄積される『決定事項・メモ』を保持する」と例示したが、「決定事項・メモ」は work-memory-format.md の Basic Structure (Issue コメント replica 形式) で定義された節であり、local File Structure の `## Detail` は「自由記述」のみが定義だった。決定事項・メモ を local `## Detail` に書き込む writer は codebase に存在せず (grep 0 件で demonstrable に確定)、例示が「それらしい語彙」を別レイヤから借用した誤帰属だった。修正は例示を定義元の語彙 (「自由記述内容」) に差し替えるだけで済み、保持機構 (mechanism) の記述は正しかったため変更不要だった。

チェック手順:

1. **例示語彙の定義元を particular に特定する**: 例に挙げる用語が format 定義文書のどのセクション (どのレイヤ) で定義されているかを Read で確認する。同名文書内でも「replica 形式の節」と「local file の構造」のようにレイヤが分かれていることがある
2. **writer 経路の grep で実在を確認する**: 「X が Y に蓄積される」と書くなら、X を Y に書き込むコードが実在するかを grep する。0 件なら例示ではなく誤帰属
3. **mechanism と例示を分離して修正する**: 誤帰属が見つかっても、保持・変換などの機構記述が generic に正しければ例示だけを定義元語彙に差し替える最小修正で済む

## 関連ページ

- [Fix 修正コメント自身が canonical convention を破る self-drift](../anti-patterns/fix-comment-self-drift.md)
- [SoT-reviewer 表現 drift: pos/neg 方向の差で派生記述が silent drift する](../anti-patterns/sot-reviewer-expression-drift.md)
- [canonical reference 文書のサンプルコードは canonical 実装と一字一句同期する](../patterns/canonical-reference-sample-code-strict-sync.md)

## ソース

- [PR #1838 review results — F-05: 「決定事項・メモ」(replica 節) を local ## Detail の例として誤帰属。writer grep 0 件で demonstrable に確定](../../raw/reviews/20260712T174329Z-pr-1838.md)
