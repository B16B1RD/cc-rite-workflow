---
type: "patterns"
title: "置換で作った fixture は置換後の行の実在を確かめてから判定し、marker は完全一致で照合する"
domain: "patterns"
description: "正常形の fixture を置換して異常形を作るテストは、置換が外れると正常形と同じ入力になり、同じ結果で合格する。marker を部分一致で照合すると空値でも一致する。置換後に対象行があることを grep -Fxq で確かめ、marker は行全体の完全一致で照合し、置換は bash のパラメータ展開で行う。"
created: "2026-09-15T03:40:00Z"
generated: { by: "rite-wiki-ingest/claude-opus-5", at: "2026-09-15T03:40:00Z" }
sources:
  - type: "fixes"
    resource: "raw/fixes/20260915T025447Z-pr-2829.md"
  - type: "fixes"
    resource: "raw/fixes/20260915T023331Z-pr-2829.md"
  - type: "fixes"
    resource: "raw/fixes/20260915T013143Z-pr-2829.md"
tags: ["testing", "fixture", "vacuous-assertion", "grep", "locale"]
confidence: high
---

# 置換で作った fixture は置換後の行の実在を確かめてから判定し、marker は完全一致で照合する

## 概要

正常形の fixture を置換して異常形を作るテストは、置換が外れると正常形と同じ入力になり、同じ結果で合格する。marker を部分一致で照合すると空値でも一致する。置換後に対象行があることを grep -Fxq で確かめ、marker は行全体の完全一致で照合し、置換は bash のパラメータ展開で行う。

## 詳細

### 入力側の空振り — 置換が外れる

「見出しの末尾に空白があっても受理する」テストを、正常形の出力の見出し行を置換して作った。期待結果は正常形と同じ（rc=0 と同じ marker）なので、置換パターンが外れて何も書き換わらなくても合格する。置換パターンをわざと外したコピーでも全件合格したことで、テストが何も検査していないと分かった。

```bash
trailing=${ok_body//$'\n### 見出し\n'/$'\n### 見出し  \n'}
printf '%s\n' "$trailing" > "$dir/out-trailing.md"
run_check table --input "$dir/out-trailing.md"
if grep -Fxq '### 見出し  ' "$dir/out-trailing.md" && [ "$rc" -eq 0 ]; then pass; else fail; fi
```

- 置換の直後に、書き換えた行が実在することを `grep -Fxq` で確かめ、その条件を判定の連言に入れる
- 置換は awk / sed ではなく bash のパラメータ展開で行う。awk / sed を使うとテスト側にロケールや実装差（BSD / GNU）が入り、置換そのものが環境によって外れる

### 照合側の空振り — 部分一致

「未検証の項目が無い」ことを `grep -q 'unverified='` のような部分一致で確かめると、値が空の `unverified=` にも、値が入った `unverified=AC-3` にも一致し、どちらの実装でも落ちない。固定すべき marker は行全体を `grep -Fxq '[CONTEXT] X=ok; rows=3; unverified='` のように完全一致で照合する。

### 変異で確かめる

どちらの空振りも、テストを書いた時点の合格では気づけない。置換パターンを外す・実装の該当行を壊すといった変異を 1 つずつ入れ、テストが赤くなることを確かめてから固定する。

## 関連ページ

- [assert_not_grep は「対象が fixture に存在する」ことを前提にしないと恒真になる — positive control を対で置く](../anti-patterns/assert-not-grep-vacuous-without-fixture-scope.md)
- [否定形の assert は前提条件が崩れると fail-silent になる](../anti-patterns/negative-assertion-vacuous-without-precondition-floor.md)
- [アサーションの検証強度は「該当行を壊して赤くなるか」でしか測れない](../heuristics/mutation-testing-measures-assertion-strength.md)

## ソース

- [置換後の行の実在確認を足した fix 結果](../../raw/fixes/20260915T025447Z-pr-2829.md)
- [fixture の置換を bash のパラメータ展開へ移した fix 結果](../../raw/fixes/20260915T023331Z-pr-2829.md)
- [marker の部分一致照合を完全一致へ直した fix 結果](../../raw/fixes/20260915T013143Z-pr-2829.md)
