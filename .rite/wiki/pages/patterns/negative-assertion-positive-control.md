---
type: "patterns"
title: "否定アサーションには positive control を添える — `|| true` は唯一の crash signal を消す"
domain: "patterns"
description: "「出力が空であること」「canary が作られないこと」で pass する TC では、被テストコマンドの exit code が唯一残った crash signal。`|| true` を付けると abort と正常な無言が区別できなくなり、mutation を注入しても PASS する。肯定アサーション（grep で特定文字列を要求）は crash で fail するため同じ変更でも安全 — この非対称を見落としやすい。同じ fixture で「canary が作られる」ことを先に確認する positive control を置くと、fixture 破損と検証成功が区別できる。"
created: "2026-07-25T07:05:21Z"
updated: "2026-07-25T07:05:21Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260724T175144Z-pr-2013.md"
  - type: "fixes"
    ref: "raw/fixes/20260724T180733Z-pr-2013.md"
  - type: "fixes"
    ref: "raw/fixes/20260724T184410Z-pr-2013.md"
tags: ["test", "negative-assert", "positive-control", "fail-open", "mutation-testing"]
confidence: high
---

# 否定アサーションには positive control を添える — `|| true` は唯一の crash signal を消す

## 概要

否定アサーション（「出力が空であること」「canary ファイルが作られないこと」で pass する TC）は、**被テストコマンドの exit code が唯一残った crash signal** である。ここに `|| true` を付けると、abort と「正常に何も出さなかった」が区別できなくなり、mutation を注入しても PASS する。肯定アサーション（grep で特定文字列を要求する形）は crash すれば出力が出ないので fail する — **同じ `|| true` でも肯定側は安全、否定側は致命的**という非対称があり、これを見落としやすい。

## 詳細

### 非対称の構造

```bash
# 肯定アサーション: crash しても fail する（grep がマッチしない）
out=$(target_cmd 2>&1) || true
grep -q "expected marker" <<< "$out" || fail "marker missing"

# ❌ 否定アサーション: crash が「正常な無言」と区別できない
out=$(target_cmd 2>&1) || true
[ -z "$out" ] || fail "unexpected output"     # crash でも空 → PASS
```

否定側では exit code こそが「テストが本当に走った」証拠なので、握り潰してはならない。

```bash
# ✅ exit code を assert する
out=$(target_cmd 2>&1); rc=$?
[ "$rc" -eq 0 ] || fail "target_cmd aborted (rc=$rc)"
[ -z "$out" ] || fail "unexpected output: $out"
```

### positive control で fixture 生存を確認する

「canary が作られないこと」で pass する TC は、**子プロセスがそもそも動かなかった場合も pass する**。同じ fixture で「canary が作られる」ことを先に確認する control を置くと、fixture 破損と検証成功が区別できる。

```bash
# positive control: この fixture で canary が作られることを先に示す
run_with_canary_enabled
[ -f "$canary" ] || fail "positive control failed — fixture is broken"
rm -f "$canary"

# 本命の否定アサーション
run_with_canary_disabled
[ -f "$canary" ] && fail "canary must not be created"
```

PR #2013 では cycle 1 で `|| true` による crash signal 破棄を潰しておきながら、**新規テストの fixture に同型の fail-open を持ち込んでいた**（cycle 2 で検出）。否定側は「潰したつもり」でも別の形で再発しやすい。

### fixture 構築の `|| continue` も silent skip と同じ

```bash
# ❌ ツール欠落を握り潰す
tool_path=$(command -v "$tool") || continue
```

テスト fixture は **本体コード以上に fail-closed であるべき**で、必要なツールが無いなら即 `exit 1` する。あわせて `command -v kill` はシェルビルトイン名を返すため、`ln -sf` すると自己参照 symlink になる（絶対パス検証を入れて弾く）。

### 検証は mutation で

否定アサーションの非空虚性は、**守っている挙動を実際に壊して赤くなるか** で確認する。`|| true` が入っている状態で mutation を注入しても PASS するなら、そのアサーションは何も守っていない。

## 関連ページ

- [absence pin (assert_not_grep) は「base に存在・head に不在」の両側を単一行トークンで検証する](./absence-pin-base-present-head-absent-single-line.md)
- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](./mutation-testing-test-fidelity.md)
- [テスト fixture の変異は各不変量・guard を単独で kill する配置で設計する](../heuristics/fixture-mutation-isolates-invariants.md)

## ソース

- [PR #2013 review cycle 1 — 否定アサーションに `|| true` を足すと signal がゼロになる](../../raw/reviews/20260724T175144Z-pr-2013.md)
- [PR #2013 fix results — 失敗の表面化で解く（exit code を assert する）](../../raw/fixes/20260724T180733Z-pr-2013.md)
- [PR #2013 fix results (cycle 2) — positive control / fixture の `|| continue` 禁止](../../raw/fixes/20260724T184410Z-pr-2013.md)
