---
type: "anti-patterns"
title: "テストが何を kill するかの counterfactual 記述は、変異を当てない限り外れる — 撤去で収束させる"
domain: "anti-patterns"
description: "テストコメントに「この assert は変異 X を kill する」と counterfactual で書くと、その変異を実際に当てて確かめない限りほぼ確実に外れる。実在した過去の実装形を名指しする記述は特に危険で、修正は言い換えではなく撤去が収束する。"
created: "2026-08-12T18:32:43Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260812T180508Z-pr-2278.md"
  - type: "fixes"
    resource: "raw/fixes/20260812T133631Z-pr-2278.md"
tags: ["test-comment", "counterfactual", "overclaim", "removal-over-rephrase"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-12T18:32:43Z" }
---

# テストが何を kill するかの counterfactual 記述は、変異を当てない限り外れる — 撤去で収束させる

## 概要

テストコメントに「この assert は変異 X を kill する」と counterfactual（反実仮想）で書くと、その変異を実際に当てて確かめない限りほぼ確実に外れる。実在した過去の実装形を名指しする記述は特に危険で、`git log -S` で実物を取ってこないと帰属が合わない。修正は言い換えではなく**撤去**（assert が機械的に固定している内容だけを残す）が収束する。

## 詳細

### 同一箇所で 3 cycle 連続して失敗した事実自体が証拠になる

起点事例（SKILL 記述ダイエットのパイロット）では、単一の欠陥クラス「契約を宣言するコメント・ヘッダ自身が、その契約より広く（または誤って）主張する」が 5 cycle を通じて反復した。注目すべきは修正の失敗の仕方である:

- cycle 3: checker script 側のコメントが過大主張
- cycle 4: 同一ファイルのテストコメント（TC-011 / TC-014）と手法文書の精密数値
- cycle 5: **cycle 4 の修正文そのもの**が新しい過大主張に置き換わった（TC-014 の「pre-restructure form への revert を kill する」が、履歴上のどの計数式に対しても成立しない）

言い換えによる修正が 3 cycle 連続で新しい過大主張を生んだという事実は、個別の表現が下手だったのではなく、**その記述クラスをそこに置くべきでない**ことの証拠として読む。

> **規則**: counterfactual な kill 主張は、変異を実際に当てて確認した場合にのみ書く。確認していないなら書かず、assert が機械的に固定している内容だけをコメントに残す。既に書いてしまった過大主張は、言い換えず撤去する。

### 派生値（%・倍率）は書かない方が構造的に安全

同じ「検証されない主張」の系として、手法文書で精密数値を概数化するとき、**概数から導かれる派生値の再計算漏れ**が残る。主要値だけ更新して派生値を放置すると、文書自身が公開する概数どうしで検算が合わない内部矛盾になる。

起点事例の実測: 19.2 → 12.4 KB は −35.4% なのに「約 −36%」と書かれ、3.8/12 ÷ 3.1/36 = 3.68 なのに「約 3.6 倍」と書かれた。いずれも元の精密値からは正しく、概数化した公開値からは導けない。

> **規則**: 概数を公開する文書では、その概数から導ける派生値（パーセンテージ・倍率）を書かない。読者が検算できる形にすると、概数化のたびに検算が合わなくなる。

### 削除で直せる指摘は削除で直す

同じ収束の型は fix 側でも観測された。未使用の `--quiet` フラグに対する指摘は、テストケースを足して正当化するのではなく**フラグごと削除**して解消した（呼び出し元ゼロ + regression proof なし）。ガードや説明を積み増す方向の修正は、次の cycle で新しい主張面を増やす。

> **規則**: 「使われていない」「確かめていない」ことが指摘の根拠なら、正当化を書き足すのではなく対象を削除する。撤去は主張面を減らすので、次 cycle の指摘対象を構造的に増やさない。

## 関連ページ

- [Test pin protection theater: 「N site pin」claim と実 assert の gap が regression 検出を破壊する](./test-pin-protection-theater.md)
- [Scope drift fix での overclaim substitution (置換後に新たな過剰主張を持ち込む)](./scope-drift-fix-overclaim-substitution.md)
- [新設した検証機構が、その機構自身の目的を局所的に打ち消す](./self-defeating-guard-local-purpose-negation.md)

## ソース

- [契約コメントの過大主張が 3 cycle 連続で言い換え修正に失敗した記録](../../raw/reviews/20260812T180508Z-pr-2278.md)
- [削除で直せる指摘を削除で直した cycle](../../raw/fixes/20260812T133631Z-pr-2278.md)
