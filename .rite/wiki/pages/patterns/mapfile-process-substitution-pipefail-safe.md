---
title: "`mapfile -t < <(...)` で pipefail safe な iteration を書く"
domain: "patterns"
created: "2026-05-07T01:08:00+00:00"
updated: "2026-05-07T01:08:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260506T162735Z-pr-868.md"
  - type: "fixes"
    ref: "raw/fixes/20260506T163131Z-pr-868.md"
tags: ["bash", "pipefail", "set-euo-pipefail", "process-substitution", "mapfile", "grep-no-match"]
confidence: high
---

# `mapfile -t < <(...)` で pipefail safe な iteration を書く

## 概要

`set -euo pipefail` 配下で `grep -F ... | head -1` 系の pipeline から値を取り出すと、grep の no-match (exit 1) が pipefail で伝播し、後続の空文字列フォールバック (`|| true` / 後段 if check) より先に script 全体を silent abort させる経路がある。`mapfile -t arr < <(grep ...)` の **process substitution + mapfile builtin** に置換すると pipeline が解消され、no-match が空配列として自然に表現できるため pipefail の伝播が原理的に発生しない。同じ目的の defensive 対策である `cmd || true || v=""` の chained absorber と相補関係にあり、複数行を扱う iteration や「0 件 = 正常」シナリオでは process substitution の方が canonical。

## 詳細

### 失敗パターン（cycle 1, F-02）

`set -euo pipefail` 配下の test runner で、固定文字列マッチを集める iteration が以下のように書かれていた:

```bash
set -euo pipefail
matched=$(grep -F "$pattern" "$file" | head -1)
if [ -z "$matched" ]; then
  echo "no match"
fi
```

`grep -F` が no-match (exit 1) を返した瞬間 pipefail が pipeline 全体を exit 1 にし、`set -e` で test runner 全体が abort する。後段の `[ -z "$matched" ]` には到達しない。test reviewer が HIGH、error-handling reviewer が INFO で independent に検出 (severity gap は debate で MEDIUM に統一)。

### canonical fix

```bash
set -euo pipefail
mapfile -t matched < <(grep -F "$pattern" "$file")
if [ "${#matched[@]}" -eq 0 ]; then
  echo "no match"
fi
```

- **process substitution (`< <(...)`)** は subshell の exit code を pipeline に伝播させない (`< <(grep ...)` は grep を独立 subshell で起動し、stdout を fd 経由で `mapfile` に渡すだけ。pipeline 構文ではない)
- **`mapfile -t`** は stdin から行を読み込んで配列に格納する builtin。grep が no-match で stdout を出さなくても、空配列として完結する (exit code は影響しない)
- 0 件 / 1 件 / N 件のいずれも空配列の length check (`"${#matched[@]}"`) で統一的に扱える

### `cmd || true || v=""` chained absorber との比較

[bash-local-vs-toplevel-pipefail-asymmetry.md](../anti-patterns/bash-local-vs-toplevel-pipefail-asymmetry.md) の canonical fix は:

```bash
v=$(grep -E '^\s+schema_version:' rite-config.yml | head -1 || true) || v=""
```

これは scalar 1 件取得 + defensive 吸収の文脈で正しい。一方 process substitution + mapfile は:

| 用途 | canonical |
|------|----------|
| 0 / 1 / N 件の iteration (`for f in "${arr[@]}"`) | `mapfile -t arr < <(...)` |
| 1 件 scalar 取得 + 空文字フォールバック | `v=$(... || true) \|\| v=""` |

両者は補完関係にあり排他ではない。

### sibling test 間での pattern 再利用

起点事例の fix では同 directory の sibling test (`caller-html-literal-symmetry.test.sh`) が既に `mapfile -t < <(...)` pattern を採用していたため、新設 test ファイルにも同 pattern を移植することで一貫性を保った。「sibling site で確立済みの canonical pattern を grep で確認してから適用する」運用は、対称化 PR の review 効率にも寄与する ([small-symmetric-pr-sibling-site-grep-review.md](../heuristics/small-symmetric-pr-sibling-site-grep-review.md))。

### 検出と命名

- **検出**: `set -euo pipefail` 配下で `grep ... | head -1` / `grep ... | wc -l` / `find ... | head` 等 pipeline で grep no-match が混入しうる箇所を grep し、後段の空チェックが unreachable な経路を発見する
- **命名**: `mapfile -t arr < <(...)` を「pipefail-safe iteration pattern」と総称する (process substitution は手段、mapfile は格納先)

## 関連ページ

- [function 内 `local v=$(...)` と top-level `v=$(...)` の `set -e` 伝播差で writer/reader 非対称が偶然 mask される](../anti-patterns/bash-local-vs-toplevel-pipefail-asymmetry.md)
- [極小対称化 PR は sibling site Grep 照合で短時間・高確信レビューできる](../heuristics/small-symmetric-pr-sibling-site-grep-review.md)
- [References 抽出時は引用先 SoT の内容を Read tool で verify する](../heuristics/references-extraction-content-fidelity.md)

## ソース

- [PR #868 review (cycle 1)](../../raw/reviews/20260506T162735Z-pr-868.md)
- [PR #868 fix](../../raw/fixes/20260506T163131Z-pr-868.md)
