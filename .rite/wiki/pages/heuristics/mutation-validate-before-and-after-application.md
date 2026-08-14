---
type: "heuristics"
title: "mutation は適用前に一致件数を、適用後に構文を検証してから結論に使う"
domain: "heuristics"
description: "mutation テストの結論（「このアサーションは守れている / 守れていない」）は、mutation 自体が正しく適用されて初めて意味を持つ。"
created: "2026-08-03T07:46:56Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260802T173849Z-pr-2094.md"
  - type: "fixes"
    resource: "raw/fixes/20260802T174557Z-pr-2094.md"
  - type: "fixes"
    resource: "raw/fixes/20260802T171659Z-pr-2094.md"
  - type: "reviews"
    resource: "raw/reviews/20260802T183251Z-pr-2094.md"
  - type: "reviews"
    resource: "raw/reviews/20260803T012646Z-pr-2094.md"
  - type: "fixes"
    resource: "raw/fixes/20260803T013513Z-pr-2094.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-03T07:46:56Z" }
---

# mutation は適用前に一致件数を、適用後に構文を検証してから結論に使う

## 概要

mutation テストの結論（「このアサーションは守れている / 守れていない」）は、mutation 自体が正しく適用されて初めて意味を持つ。**適用前に「対象文字列がちょうど 1 回一致すること」を assert し、適用後に `bash -n` を通す。** これを省くと、一致 0 回の mutation が「テストが弱い」と誤読され、構文を壊した mutation が「全 TC が Red」という無意味な結果を出す。

## 詳細

### 適用前: ちょうど 1 回一致を assert

コメント中に同じ文字列があると置換対象が 2 件になり、意図しない箇所を壊す。逆に文字列が 1 文字でも違えば 0 件一致となり、「mutation を当てたのにテストが落ちない = テストが弱い」という反転した結論が出る。

```bash
n=$(grep -c -- "$TARGET" "$FILE")
[ "$n" -eq 1 ] || { echo "mutation target matched $n times (expected 1)" >&2; exit 1; }
```

### 適用後: `bash -n` を通す

`grep -v` で行を消す mutation は `if`/`else` を孤立させて構文エラーになる。この状態でスイートを走らせると全 TC が Red になり、「テストが強い」と誤読される。適用後に構文検査を挟むと、**無効な mutation を判断材料から除外できる**。

### 報告は「生存した mutation の列挙」が本体

「9 通り当てて 3 通りが生存した」という形で報告すると、テストが守れている範囲と守れていない範囲が同時に分かる。「全部 Red になった」だけの報告より情報量が多い。

### 出力から原理的に判別できない性質は、強化ではなく relabel

既定値と同じ値を assert するテストは kill power を持たない。`loop_count: 0` の照合は、既定値が `0` である以上 carry-forward の有無を区別できず、carry-forward を丸ごと削除しても Green のままだった。

**全入力で同じ出力になる等価変異は、アサーションを強化しても捕捉できない。** 正しい対処は名前とコメントを実態に合わせ、実際に守っているアサーション（非既定値を使うもの）を明示すること。「直接確認」等の強い語をアサーション名に置くと、読み手は守られていると誤認する。

同様に、**否定・既定値の assertion は値が偶然一致しない fixture で書く**。「1 に採番し直す」を検証する fixture の元値が 1 だと、mutation を入れても Green のまま通る。seed を 2 回回して 2 にしてから壊すだけで判別力が出る。

### seed と同値を assert するブロックには完走確認を 1 本置く

seed が env override で書いた値と、更新後に照合する値が同一だと、**検証対象の更新が no-op でも abort でも全アサーションが Green** になる。各ブロックに前提確認か body 差し替えの照合を 1 本置く（`WM_BODY_TEXT` の値が出力に含まれるか、が最小の判別子）。

### 否定 assertion は「その否定が最も破られやすい入力」で書く

「WARNING を誤報しない」を非既定値の fixture だけで検証すると、**既定値状態（production で最も多い）での誤発火 mutant が生存する**。否定の検証は、その否定が最も破られやすい入力で行う。

関連して、**肯定と否定の assertion が同じリテラルを別々に持つと、否定側が静かに死ぬ**。文言変更で肯定側だけ追随すると、否定側の grep は何にも一致せず「出ていない」と誤って PASS する。照合文字列は 1 変数に集約して両方から参照する。

### 生存した防御コードを「テスト不足」と読まない

mutation で生存した防御コードに対して不要な TC を増やす前に、**到達可能な入力が構成できるか**を確認する。構成できないなら、それは coverage hole ではなくデッドコードであり、削除が正しい対処。

### guard 自身も mutation で殺せることを確認する

「X が壊れたことを検出する guard」を書いたら、**必ず X を壊す変異で guard が落ちることを実測する**。実例では、sweep 正規表現から腕を落とす回帰を検出する guard の初版が、正規表現とは独立に site を数えていたため変異を殺せなかった。正規表現を変数へ一本化し、guard が同じ式を見る形へ作り直して初めて機能した。**書いただけでは検出しているとは限らない。**

### テストへの env 追加は kill power を「交換」しうる

優先順位 1 > 2 を pin するため 2 回目の実行に env override を足したところ、その env がガードを偽にして**既存ファイル値が候補から外れ、優先順位 1 > 3 を守っていた保護が消えた**。1 本のテストで 2 つの優先関係を同時に固定しようとすると、片方の入力がもう片方の前提を壊す。**優先関係ごとに実行を分ける。**

### PATH shim は選択的にする

外部コマンドを全面的に失敗させる shim は、そのコマンドに依存する無関係な TC を巻き込む。対象の呼び出しを引数で見分けて、それだけを失敗させる。

## 関連ページ

- [アサーションの検証強度は「該当行を壊して赤くなるか」でしか測れない](./mutation-testing-measures-assertion-strength.md)
- [mutation は述語軸だけでなく配置・routing・副作用・到達の各軸に当てる](./mutation-axes-beyond-predicate.md)
- [Test pin protection theater: 「N site pin」claim と実 assert の gap が regression 検出を破壊する](../anti-patterns/test-pin-protection-theater.md)

## ソース

- [PR #2094 review results (cycle 3)](../../raw/reviews/20260802T173849Z-pr-2094.md)
