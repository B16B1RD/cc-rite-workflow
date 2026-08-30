---
type: "heuristics"
title: "runtime 診断は「どこを見ればいいか」だけ示す — 原因の分類は SoT に持たせる"
domain: "heuristics"
description: "診断 WARNING に「lowercase key / 全角コロン / リスト項目化 / 未展開 placeholder 等の崩れが疑われます」という**原因の列挙**を書くと、その列挙は分岐が増えるたびに実態とずれる。"
created: "2026-08-08T14:00:41+09:00"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260808T032734Z-pr-2142.md"
  - type: "reviews"
    resource: "raw/reviews/20260808T031704Z-pr-2142.md"
tags: ["diagnostics", "sot", "warning-message", "maintenance", "drift"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-08T14:00:41+09:00" }
---

# runtime 診断は「どこを見ればいいか」だけ示す — 原因の分類は SoT に持たせる

## 概要

診断 WARNING に「lowercase key / 全角コロン / リスト項目化 / 未展開 placeholder 等の崩れが疑われます」という**原因の列挙**を書くと、その列挙は分岐が増えるたびに実態とずれる。

ある PR では「節に値行が無い」という新しい原因クラスを、その原因を列挙していない既存の WARNING へ合流させた。結果、**崩れていない正しい見出しを名指しながら、存在しない記法崩れを探させる**診断になった。運用者は列挙されたどの項目にも当たらない原因を、列挙の中から探すことになる。

## 詳細

### 「列挙に 1 項目足す」が解にならない理由

列挙を維持する道を選ぶと:

- 同じ列挙を持つ**散文 site との同期義務**が増える（runtime メッセージと docstring と reason 表の 3 箇所）
- 次の退避先・分岐が増えれば同じ指摘が再発する
- 列挙の網羅性そのものが load-bearing になり、漏れが新しい欠陥クラスになる

**runtime 診断の目的は切り分けであって分類ではない。** 「どこを見ればいいか」（対象ファイル・行番号・reason 名）を示せば運用者は SoT を引ける。原因の分類は docstring と reason 表という単一の SoT が持てばよい。

### 副次的な利得

runtime 側の列挙を撤去すると、外部入力を診断へ埋め込む必要も減る。行番号と reason 名だけなら中和も長さ上限も要らない。診断チャネルの衛生問題が構造的に消える。

### 併発しやすい兄弟欠陥

同 cycle では、対比を指示語（前者 / 後者）で圧縮した説明文が実測と逆の帰属になっていた。**同クラス（コメントが実測を騙る）は 4 cycle 連続で再発し、しかも同種を潰した commit の中で新しい個体が生まれている**。対比構造は指示語で圧縮せず、両方のサブケースを明示的に書き分ける。

また、不変条件を守る機構が 2 つになったら SoT の因果節を両方へ更新する。「同じ記入漏れが記法で reason 分裂しない」という不変条件は当初 1 機構で成り立っていたが、節境界の追加で 2 機構の連言になった。SoT が 1 機構しか書いていないと、読み手が節境界を「冗長」と判断して外し、分裂が再発する。

## 関連ページ

- [診断 WARNING メッセージの読者を曖昧にしない](./diagnostic-warning-message-audience-ambiguity.md)
- [診断主張は発火条件にスコープする](./diagnostic-claim-scoped-to-firing-condition.md)
- [指示 (directive) と帰結を分離し SoT ポインタで結ぶ](../patterns/separate-directive-from-consequence-with-sot-pointer.md)
- [同期サイトを同期する前に、サイトの数を減らす](./reduce-sync-sites-before-syncing-them.md)

## ソース

- [PR #2142 fix results (cycle 6)](../../raw/fixes/20260808T032734Z-pr-2142.md)
- [PR #2142 review results (cycle 5)](../../raw/reviews/20260808T031704Z-pr-2142.md)
