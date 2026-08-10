---
type: "anti-patterns"
title: "`set -euo pipefail` 下の `var=$(cmd | jq ... 2>/dev/null)` は不正入力でテストを無言 abort させる"
domain: "anti-patterns"
description: "被テスト対象の stdout を jq でパースして変数に代入する形は、`set -euo pipefail` 下では **jq の非ゼロ終了がそのまま代入コマンドの終了ステータス**になる。"
created: "2026-07-26T01:35:00+09:00"
updated: "2026-07-26T01:35:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260725T151649Z-pr-2020.md"
  - type: "fixes"
    ref: "raw/fixes/20260725T152249Z-pr-2020.md"
tags: ["test", "pipefail", "jq", "silent-failure", "dead-branch", "diagnosis"]
confidence: high
---

# `set -euo pipefail` 下の `var=$(cmd | jq ... 2>/dev/null)` は不正入力でテストを無言 abort させる

## 概要

被テスト対象の stdout を jq でパースして変数に代入する形は、`set -euo pipefail` 下では **jq の非ゼロ終了がそのまま代入コマンドの終了ステータス**になる。不正 JSON なら jq は rc=5 で落ち、errexit が発火してスクリプトはその行で終了する。`2>/dev/null` が jq の診断も捨てるため、**出力ゼロで死ぬ**。

結果として、後段に「想定外の出力形式なら FAIL」の分岐を足しても、不正 JSON の経路では構造的に到達しない dead branch になる。runner が exit code で失敗を集計していれば silent pass にはならないが、**どのアサーションで何が起きたかは完全に失われる**。

## 詳細

### 発火の機序

```bash
set -euo pipefail
output=$(run_target)
# ❌ 不正 JSON なら jq が rc=5 → 代入コマンドの rc=5 → errexit で abort
decision=$(echo "$output" | jq -r '.field // empty' 2>/dev/null)
if [ -n "$output" ]; then   # ← 到達しない
  fail "unexpected output shape: $output"
fi
```

実測では、非 JSON を返すスタブに差し替えた時点で `PASS=0 FAIL=0` のまま rc=5 で終了し、当該テストケースについて何も表示されない。同じブロックの `rm -rf "$tmpdir"` も未実行になり、以降のテストケースも走らない。被テスト側が全入力で非 JSON を返す退行では、**ファイルの先頭付近のケースで中断**して該当ケースに到達すらしない。

### 単独代入とコマンド位置の非対称

同じコマンド置換でも、**引数位置**にあるものは errexit を発火させない。

```bash
# ✅ 引数位置: cat が失敗しても fail は実行され、errexit も発火しない
fail "hook crashed: $(cat -v "$STDERR_FILE")"

# ❌ 単独代入: 右辺の失敗が文全体の rc になり abort する
x=$(cat -v /missing)
```

診断メッセージ内のコマンド置換は安全で、値を取り出す代入だけが危険という非対称がある。

### 是正: 判定に JSON パースが要らないなら jq を外す

「permit は無出力、deny は特定文字列を含む出力」のように**形状だけで判定できる**契約なら、パースを挟む必要はない。

```bash
# ✅ 出力形状で分岐する（jq を介在させないので abort しない）
if [ -n "$output" ]; then
  case "$output" in
    *'"deny"'*) fail "wrongly denied (MUST NOT violation): $output" ;;
    *)          fail "expected no output (permit), got: $output" ;;
  esac
elif [ "$rc" != "0" ]; then
  fail "exited rc=$rc with no output: $(cat -v "$STDERR_FILE")"
else
  pass "..."
fi
```

部分一致に落とす前に、**判定に使う文字列が payload 内に 1 回だけ現れ、自由文フィールドには現れない**ことを実測で確認する。確認できれば部分一致はパースと同じ厳密さを保つ。JSON エスケープがかかるフィールド（reason 等）は仮に同じ語を含んでも `\"deny\"` になるため、この条件は将来の文言変更に対しても頑健に成立しやすい。

### パースが必要な場合の回避

値そのものが要るなら、代入の失敗を errexit から切り離す。

```bash
if decision=$(echo "$output" | jq -r '.field // empty' 2>"$jq_err"); then
  :
else
  jq_rc=$?
  fail "failed to parse output (rc=$jq_rc): $(cat "$jq_err")"
fi
```

`2>/dev/null` で診断を捨てないことが要点。捨てると「なぜ落ちたか」を再現実行なしには追えない。

### 肯定アサーションは fail-safe、否定側だけが危険とは限らない

`[ "$decision" = "deny" ]` のような**肯定**アサーションでは、`// empty` は fail-safe に働く（クラッシュ → 抽出値が空 → 不一致 → FAIL）。ただし abort そのものは肯定側でも起きるため、被害は「どのアサーションで落ちたかの診断が消える」形で残る。正しさの修復ではなく診断性の改善として、優先度を判断する。

## 関連ページ

- [否定アサーションには positive control を添える — `|| true` は唯一の crash signal を消す](../patterns/negative-assertion-positive-control.md)
- [set -euo pipefail 下の外部コマンド単独文は後続 rc 分岐を dead code 化する](./bare-statement-under-set-e-dead-code-rc-branch.md)
- [`grep -oE | wc -l` が ratchet ideal 値到達時に pipefail で silent abort](./grep-oe-wc-pipefail-silent-abort.md)

## ソース

- [PR #2020 review cycle 1 — 不正 JSON で分岐が到達不能になる機序の実測](../../raw/reviews/20260725T151649Z-pr-2020.md)
- [PR #2020 fix results — 出力形状で判定して jq を外す](../../raw/fixes/20260725T152249Z-pr-2020.md)
