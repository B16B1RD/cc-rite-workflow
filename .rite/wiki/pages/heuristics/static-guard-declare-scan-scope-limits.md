---
type: "heuristics"
title: "静的ガードを新設したら、走査面の限界と現存する未カバーサイトをテスト本体のコメントに書く"
domain: "heuristics"
description: "退行を止める静的ガードを追加するとき、走査面（例: *.sh のみで markdown fence を含まない）の限界と、その盲点に現存する違反サイトをテスト本体のコメントと PASS 文言に明記する。書かないと「緑 = そのバグクラスは撲滅済み」と読まれ、実際には live な違反が残っていても誰も気づかない。同一 suite の先行テストが同じ慣行を持っている場合、新設ガードがそれを欠くと非対称が外から見えやすく、複数のレビュアーが独立に同じ穴を突く。"
created: "2026-08-01T17:45:00+09:00"
updated: "2026-08-01T17:45:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260801T074423Z-pr-2080.md"
  - type: "fixes"
    ref: "raw/fixes/20260801T074952Z-pr-2080.md"
tags: [static-guard, test-comment, scope-limit, false-confidence, regression-guard, coverage]
confidence: medium
---

# 静的ガードを新設したら、走査面の限界と現存する未カバーサイトをテスト本体のコメントに書く

## 概要

退行を機械的に止める静的ガード（find + 検出器で全ファイルを走査するテスト等）を追加するとき、**走査面が何を含まないか**と、**その盲点に現時点で違反が残っているか**をテスト本体のコメントと PASS 文言に書く。書かなければ、そのテストが緑であることが「このバグクラスは撲滅済み」と読まれる。実際には走査面の外に live な違反が残っていても、ガードは緑のまま通過する。

## 詳細

- **背景（PR #2080）**: BSD/macOS の `mktemp(1)` が trailing Xs しか置換しない問題で、`-XXXXXX.md` のような suffix 付きテンプレート 2 箇所を修正し、再混入を防ぐ TC-8b-i を追加した。検出器は `find "$PLUGIN_ROOT" -name '*.sh'` で 212 ファイルを走査し、PASS 文言は当初「every mktemp template ends in trailing Xs」だった。これは plugins/rite 全体に対する普遍的主張として読めるが、実際の走査は `*.sh` のみで、rite が実際に実行する skill markdown 内の bash fence を含まない。その盲点に `skills/fix/SKILL.md` の live な `-XXXXXX.md` が残っていた。

- **非対称が指摘の引き金になる**: 直前の類似テスト TC-8b-h は自身のコメントに「Scope limits, stated honestly:」節を持ち、「bash fenced in SKILL.md / references is NOT scanned」と盲点を明示したうえで既知サイト 2 件まで列挙していた。新設ガードがこの慣行を欠いたため、application / test / security の 3 レビュアーが独立に同じ穴を指摘した。**同一 suite に先行例がある場合、そこからの逸脱は外部レビューで検出されやすい**。

- **書くべき 3 点**: (1) 走査面が含まないもの（ファイル種別・ディレクトリ）、(2) その盲点に現存する違反サイトのパスと、それが live code かどうか、(3) 検出器自体の既知の限界（例: `mktemp` とテンプレートが同一行にある形しか見ない）。PASS 文言も走査範囲に合わせて限定する（`every mktemp template in *.sh ends in trailing Xs (...; markdown fences not covered)`）。

- **ガード拡張と実体修正は 1 つの変更に束ねる**: 走査面を広げると盲点に残っていた違反サイトが即 FAIL するため、拡張だけを先行させられない。Issue の Target Files 制約で実体に触れられない PR では、限界の明記に留めて follow-up へ回すのが正しい順序になる。この判断自体もコメントに書いておくと、後続の読み手が「なぜ広げないのか」を再導出せずに済む。

- **既存の専用スキャナがあるなら、そこへ足すほうが穴が減る**: 本件では `hooks/scripts/tmp-hardcode-check.sh` が同じルール系統（mktemp テンプレート形状）を既に持ち、markdown も走査し `/rite:lint` に配線済みだった。新規テストへ独自実装した結果として生まれた「markdown fence 未カバー」はルールの限界ではなく**設置場所の副作用**である。ルールを置く場所は、実装を書く前に既存スキャナの有無で決める。

## 関連ページ

- [re-review / verification mode でも初回レビューと同等の網羅性を確保する (Anti-Degradation Guardrail)](./reviewer-scope-antidegradation.md)

## ソース

- [PR #2080 review results](../../raw/reviews/20260801T074423Z-pr-2080.md)
- [PR #2080 fix results](../../raw/fixes/20260801T074952Z-pr-2080.md)
