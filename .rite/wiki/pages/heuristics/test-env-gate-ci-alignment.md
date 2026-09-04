---
title: "Test の env gate 配置と CI workflow 起動コマンドの claim alignment を empirical 検証する"
domain: "heuristics"
description: "Test 内の特定セクション (例: assertion ブロック / meta-test ブロック) を `STRICT_CHARTER=1` のような env gate でガードしていると、PR description が「CI で常時実行される」と主張していても、CI workflow の起動コマンドが env を未設定で test を呼ぶ場合、gate された assertion は **silent に skip** される。"
promote: rite-plugin
created: "2026-05-09T09:10:00Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260509T071343Z-pr-915.md"
tags: [test, env-gate, ci-alignment, pr-description-claim, meta-test]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-08T13:37:28Z" }
---

# Test の env gate 配置と CI workflow 起動コマンドの claim alignment を empirical 検証する

## 概要

Test 内の特定セクション (例: assertion ブロック / meta-test ブロック) を `STRICT_CHARTER=1` のような env gate でガードしていると、PR description が「CI で常時実行される」と主張していても、CI workflow の起動コマンドが env を未設定で test を呼ぶ場合、gate された assertion は **silent に skip** される。env gate の **配置** (どの assertion を inside / outside に置くか) と CI workflow の起動コマンドの **alignment** が empirical に取れていないと、PR description claim が嘘になる silent regression 経路を生む。reviewer 側で「test 内 env gate が CI workflow 設定とどう alignment しているか」を 1 行 grep (`grep -E '<TEST_NAME>|STRICT_<GATE>=' .github/workflows/*.yml`) で必ず verify する canonical pattern として運用する。

## 詳細

### 失敗の構造

起点事例の cycle 1 review で test reviewer が HIGH として検出した事例:

- **PR description の主張**: 「meta-test は `STRICT_CHARTER` env gate の **外側** に配置されており、CI workflow `.github/workflows/test-hooks.yml` の `bash run-tests.sh` (STRICT_CHARTER 未設定) で **常時実行** される」
- **実装上の事実 (cycle 1 時点)**: meta-test ブロックが `STRICT_CHARTER=1` 内側 (`if [ "${STRICT_CHARTER:-}" = "1" ]; then ... fi` 内) に配置されており、CI workflow が `STRICT_CHARTER` 未設定で起動するため、CI 上では meta-test が **silent に skip** される構造
- **claim と実態の non-alignment**: PR description が CI 自動実行を保証するという test plan claim を立てていたが、env gate 配置の修正なしには claim を満たさない

### 教訓

Test 内に env gate (`STRICT_*=1` / `RUN_FULL=1` 等) を配置する PR で「CI で常時実行」を主張する場合、reviewer は以下の 3 段階で alignment を empirical 検証する:

1. **Test 内の env gate 範囲を確定**: `grep -nE '\[ "\$\{?<GATE>\}?" = "1" \]' <test_file>` で gate 開始行 / 終了行を特定。gate 内側 / 外側のいずれにどの assertion が配置されているかを行レベルで明示する
2. **CI workflow の起動コマンドの env 設定を確認**: `grep -nE '<TEST_NAME>|<GATE>=' .github/workflows/*.yml` で当該 test を invoke するコマンドの env (`<GATE>=1` 設定の有無) を確定
3. **claim との alignment を 1 表で表現**: 上記 1, 2 を基に「PR description の test plan claim」「test 内 env gate 配置」「CI workflow 起動コマンド」の 3 軸を 1 表に並べて、不整合がないかを 1 度の visual scan で判定する

### 検出手段 (reviewer scope への追加)

新規 test 追加 PR / 既存 test に env gate を追加する PR で「CI で常時実行」「CI で機械検証」等の claim が PR description にある場合、以下を必須 verify:

1. **gate 内側に置かれた assertion**: CI 実行時に env が未設定であれば skip 対象。「CI で常時実行」 claim に矛盾する箇所がないか確認
2. **gate 外側に置かれた assertion**: CI 実行時も評価対象。claim と整合
3. **CI workflow の env 設定**: `env:` block / `run:` 行の env prefix で当該 gate が設定されているか

3 軸が aligned していない場合 HIGH finding として挙げる。

### 既存教訓との接続

本 heuristic は [AC 解消 statement の数値解釈は実装で裏取りする](ac-resolution-statement-implementation-verification.md) と同じ「PR description claim を実装/設定で empirical 裏取りする」系列の sub-pattern。あちらが「数値解釈の出典 grep」を canonical 化したのに対し、本 heuristic は「test の env gate 配置と CI workflow 起動コマンドの alignment grep」を canonical 化する。両 heuristic はいずれも PR description claim の fact-check gate として機能する。

### 適用範囲

本 heuristic は以下の文脈で発動する:

1. Test に env gate (`STRICT_*=1` / `FULL_RUN=1` / `INTEGRATION=1` 等) を配置する PR
2. PR description / commit message に「CI で常時実行」「CI で機械検証」「自動化された regression 検出」等 CI 自動実行の claim を含む
3. CI workflow の起動コマンドが当該 test を直接 invoke している (matrix / parametrized でない単純 case)

3 件すべて該当する場合、reviewer は env gate 配置 vs CI 起動コマンドの alignment を最初の 5 分以内に grep で verify することを必須化する。

## 関連ページ

- [AC 解消 statement の数値解釈は実装で裏取りする (PR description fact-check gate)](ac-resolution-statement-implementation-verification.md)
- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](../patterns/mutation-testing-test-fidelity.md)
- [散文で宣言した設計は対応する実装契約がなければ機能しない](../anti-patterns/prose-design-without-backing-implementation.md)

## ソース

- [meta-test の env gate 配置と CI workflow 自動実行の意図/現実 non-alignment 検出](../../raw/reviews/20260509T071343Z-pr-915.md)
