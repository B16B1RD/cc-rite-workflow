---
type: "patterns"
title: "テストダブルは被テスト式を実際に評価させ、helper 呼び出しの有無は記録モックの不在で pin する"
domain: "patterns"
description: "モックの gh が `--jq` を無視して固定文字列を返すと、被テストの式は一度も実行されず退行を検出できない。モックはフィクスチャ JSON を実 jq に通し、絶対パスで呼ばれる helper は解決先のプラグインルートに記録用モックを置いて受領ペイロードを観測する。「helper は呼ばれない」という失敗系の契約は、WARNING 文字列ではなく記録ファイルの不在と到達 positive control の対で pin する。"
created: "2026-09-16T03:09:20Z"
generated: { by: "rite-wiki-ingest/claude-fable-5-1", at: "2026-09-16T03:09:20Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260916T025549Z-pr-2896.md"
tags: ["test", "mock", "jq", "hook", "positive-control", "acceptance-criteria"]
confidence: high
---

# テストダブルは被テスト式を実際に評価させ、helper 呼び出しの有無は記録モックの不在で pin する

## 概要

モックの gh が `--jq` を無視して固定文字列を返すと、被テストの式は一度も実行されず退行を検出できない。モックはフィクスチャ JSON を実 jq に通し、絶対パスで呼ばれる helper は解決先のプラグインルートに記録用モックを置いて受領ペイロードを観測する。「helper は呼ばれない」という失敗系の契約は、WARNING 文字列ではなく記録ファイルの不在と到達 positive control の対で pin する。

テストダブルは「被テストコードが実際に評価する経路」を残す形で作る。観測は副作用の有無ではなく受領した入力で行い、不在アサーションは到達 control と対にする。

## 詳細

### 固定文字列モックは式を素通りさせる

hook が `gh pr view --json isDraft --jq '<式>'` を呼ぶのに対し、テストのモック gh は `"pr view") echo "false" ;;` のように結果の文字列だけを返していた。これでは hook 側の `--jq` 式は一度も jq に渡らないため、式に boolean を潰す演算子が混入しても全テストが green のまま通る。実際にそうなった。

対処は、モックが引数から `--jq <式>` を取り出し、フィクスチャ JSON（`{"isDraft":false}` 等）に対して **実 jq** で評価して返すこと。jq を解決できない環境ではリテラルへ倒さず `MOCK ASSERTION FAILED` で落とす。フィクスチャを JSON にしておけば、true / false / キー欠落の各経路を式の側で検証でき、モックが「正しい答え」を先回りして知っている状態が消える。

退行防止として、モックの各 `pr view` arm が実 jq の dispatch 関数を経由することを静的 pin で固定する。純粋なエラー arm の免除は形から推測せず明示マーカーで宣言させる（関連ページ）。

### 絶対パス呼び出しには PATH 注入が効かない

hook が `"$plugin_root/scripts/<helper>.sh"` のように絶対パスで helper を呼ぶ場合、テストが PATH の先頭にモック helper を置いても実体が呼ばれる。受領ペイロードを観測するには、テストディレクトリ配下に **sandbox プラグインルート**（hooks をコピーし、`scripts/<helper>.sh` に「`$1` をファイルへ書くだけ」の記録モックを置いたもの）を作り、hook にそのルートを解決させる。

記録モックが残すのは呼ばれた事実ではなく受領した JSON そのものなので、「呼ばれた」だけでなく「どの status role を渡したか」まで assert できる。上流の契約変更（列名から role への移行など）はここで検出される。

### 失敗系の「呼ばれない」は不在で pin する

受入条件の Then に「pr view が失敗したら helper は呼ばれない」が含まれるとき、既存テストが stderr の WARNING トークンしか見ていないことがある。失敗系フィクスチャは repo view や GraphQL も縮退させているのが普通で、hook が失敗後に照合ブロックへ進んでも helper に到達しない。そのため「失敗しても照合に進む」退行は WARNING が残る限り緑のままになる。失敗分岐の変数代入を書き換える変異を当てても検出されないことで実測された。

pin の形は次のとおり。pr view だけ非 0 で終わり、repo view と GraphQL は happy と同じ正常応答を返すフィクスチャを sandbox プラグインルート付きで起動し、(1) WARNING トークンの存在を **到達 positive control** として確認し、(2) 記録ファイルの不在と「mismatch detected」の不在を本命として assert する。不在だけでは hook が早期に死んでも緑になるので、control が対になっていないと pin は成立しない。

### 一般化

- テストダブルは結果を先回りして返さず、被テストコードが評価する式・パースする JSON をそのまま通す
- 観測点は副作用の発生ではなく受領入力に置く。helper が絶対パスで解決されるなら、解決先ごと差し替える
- 受入条件の否定側（〜しない）は、肯定側の到達 control と対にした不在アサーションで pin する。文字列 grep だけでは経路未到達と区別できない

## 関連ページ

- [否定アサーションには positive control を添える — `|| true` は唯一の crash signal を消す](./negative-assertion-positive-control.md)
- [jq の `//` は false を falsy として右辺へ倒す — boolean フィールドに既定値演算子を付けない](../anti-patterns/jq-alternative-operator-collapses-boolean-false.md)
- [静的 pin は禁止表記の denylist ではなく、成立させたい性質の allowlist で書く](../heuristics/static-pin-semantic-allowlist-not-notation-denylist.md)
- [オプションを常に明示するテストは、既定値解決という最も壊れやすい経路を丸ごと素通りさせる](../anti-patterns/explicit-option-tests-bypass-default-resolution.md)

## ソース

- [レビュー結果](../../raw/reviews/20260916T025549Z-pr-2896.md)
