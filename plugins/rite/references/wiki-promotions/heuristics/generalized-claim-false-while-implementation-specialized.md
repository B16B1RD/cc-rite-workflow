---
type: "heuristics"
title: "一般化した断定は、実装が特殊化されている限り必ず偽になる — 同じ契約を書く複数サイトは最も限定的な表現に揃える"
domain: "heuristics"
promote: rite-plugin
promoted_from: "wiki:/pages/heuristics/generalized-claim-false-while-implementation-specialized.md"
promoted_from: "wiki:/pages/heuristics/generalized-claim-false-while-implementation-specialized.md"
description: "「除外ブロックが未閉鎖なら検出失敗」のような契約を無限定に書くと、実装が 2 ラッチ限定・特定ファイル限定である以上その断定は偽になる。同一 PR 内の分岐表が正しく限定できていたなら、最も限定的な表現を正としてほかをそれに揃えるのが機械的な解。見送り判断も結論だけでなく根拠を in-repo に残さないと、根拠の誤りが次 cycle で同じ論点を再生産する。"
created: "2026-08-01T00:21:06+09:00"
updated: "2026-08-01T23:12:28+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260731T090329Z-pr-2070.md"
  - type: "reviews"
    ref: "raw/reviews/20260801T131235Z-pr-2081.md"
  - type: "fixes"
    ref: "raw/fixes/20260801T131540Z-pr-2081.md"
tags: []
confidence: high
---

# 一般化した断定は、実装が特殊化されている限り必ず偽になる — 同じ契約を書く複数サイトは最も限定的な表現に揃える

## 概要

同じ契約が複数箇所に書かれているとき、書き手は場所ごとに違う抽象度で表現しがちである。実装が特定の条件下でしか動かないなら、**無限定に一般化した表現はその時点で偽**になる。複数サイトの表現が揺れているなら、最も限定的な表現を正として他をそれに揃えるのが機械的な解法になる。

## 詳細

起点事例の cycle 5 では「除外ブロックが未閉鎖なら検出失敗」という契約が無限定に書かれていた。しかし実装は 2 種類のラッチに限定され、対象ファイルも index.md に限定されている。同一 PR 内の分岐表は正しく限定できていたので、限定的な側を正として他を揃えれば済んだ。

同じ cycle でもう 1 つ観測されたのが**見送り判断の根拠の扱い**である。cycle 4 で見送った論点の理由として「`insrc` を足すと `## ソース` で終わる全ページで誤発火する」と記録したが、これは誤りだった（END 検査は index 側にしか無い）。結論そのものは正しかったが、**根拠が誤ったまま記録されていたため 2 名の reviewer が独立に同じ論点を再提起した**。正しい根拠（producer 不在）を rationale に 1 行残せば再生産は止まる。見送り判断は結論だけでなく根拠を in-repo に残し、その根拠自体も実測で裏取りする。

なお、レビュアーが挙げた「隣接する穴」を最終 cycle で全部塞ごうとしないこと。起点事例では 4 名が別々に同じ未カバー箇所を挙げたが、各人とも producer 不在・Hypothetical と結論し、拡張すると誤発火することも明示していた。**指摘の substance と、そこから連想される拡張は別物**である。

**適用条件**: 同一の契約・不変条件が複数箇所（本体・分岐表・enum 説明・上位仕様書）に書かれているとき。表現の抽象度が揃っているかを確認し、最も限定的なものへ寄せる。

### 述語を散文化するときは母集団を先に束縛してから内訳を書く

この原則が最も鋭く出るのが、**述語の依存関係を散文が落とす**ケースである。判別を 3 値化した事例の実装では `has_arrow` が `¬anchored` の母集団の**内側でしか評価されない tie-breaker** だったが、記述は「marker から `=>` までに句点が入ると降格」と**独立条件**で書かれていた。正規形アンカーは LHS に句点・改行を含んでも `measured=true` のまま残るため、この記述は存在しない false-negative を SoT に記録したことになる。reviewer 4 名が独立に同じ結論へ到達した。

**「A なら B」の形で条件を独立に書くと、実装が「A ∧ C なら B」だったとき必ず偽になる。** 散文が実装の依存関係を落とすのは、依存関係が regex の評価順序という「読まないと分からない」場所にあるため。

**正しい枠取りは repo 内に既にあることが多い**: 同じ事例では `pr-review/SKILL.md` が「検出 regex に match しない finding のうち」と母集団を先に置き、その内側で未判定 / 降格を分けていた。散文を新規に発明せず、**既に正しい面の枠取りを流用する**ことで 4 面の記述が収束した。

なお、この「強すぎる断定」は前 cycle の「弱すぎる断定」（意味論の語彙による言い換え）を修正した結果として生まれている。字句の語彙へ寄せる際に母集団の束縛を落とさないこと（[機械的な述語を文書化するときは意図の語彙ではなく字句の語彙で書く](./mechanical-predicate-prose-lexical-vocabulary.md)）。

## 関連ページ

- [修飾は主張単位ではなく同格の主張の集合単位でかける](./qualifier-applies-to-peer-claim-set.md)
- [散文修正の完了検査は「主張した概念」で走査する（逆引き検査）](./reverse-lookup-concept-sweep-for-prose-fixes.md)
- [機械的な述語を文書化するときは意図の語彙ではなく字句の語彙で書く](./mechanical-predicate-prose-lexical-vocabulary.md)

## ソース

- [PR #2070 review results (cycle 5)](../../raw/reviews/20260731T090329Z-pr-2070.md)
- [PR #2081 review results (cycle 5)](../../raw/reviews/20260801T131235Z-pr-2081.md)
- [PR #2081 fix results (cycle 5)](../../raw/fixes/20260801T131540Z-pr-2081.md)
