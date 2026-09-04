---
title: "共有 /tmp の leak 検査は count delta ではなく path 集合差分 (comm -13) で行う"
domain: "patterns"
description: "共有 `/tmp` 上の tempfile leak 検査を「実行前後のファイル数 count delta」で行うと、(a) 並列実行中の他プロセスが同 glob のファイルを削除した場合に false-fail、(b) 自テストの leak と他プロセスの削除が相殺した場合に false-PASS する。"
created: "2026-06-06T17:33:06Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260606T171726Z-pr-1295.md"
tags: ["test", "tempfile-leak", "comm-set-difference", "parallel-test-isolation", "false-fail", "false-pass"]
confidence: medium
generated: { by: "rite-wiki-ingest/unknown", at: "2026-06-06T17:33:06Z" }
---

# 共有 /tmp の leak 検査は count delta ではなく path 集合差分 (comm -13) で行う

## 概要

共有 `/tmp` 上の tempfile leak 検査を「実行前後のファイル数 count delta」で行うと、(a) 並列実行中の他プロセスが同 glob のファイルを削除した場合に false-fail、(b) 自テストの leak と他プロセスの削除が相殺した場合に false-PASS する。実行前後の **path 集合を `comm -13` で差分化** すると、自テスト実行中に新規出現した path のみを決定論的に検出でき、両方向の誤判定を構造的に排除する。helper の mktemp template が絶対 path 固定で `TMPDIR` 隔離 (ISOLATED_TMP 方式) が効かない場合の canonical 次善策。

## 詳細

### 失敗の構造 — count delta の 2 つの盲点

```bash
# 反面教材: count delta 方式
before=$(ls /tmp/rite-fix-normalized-* 2>/dev/null | wc -l)
run_test_target
after=$(ls /tmp/rite-fix-normalized-* 2>/dev/null | wc -l)
[ "$after" -eq "$before" ]  # leak なしを期待
```

| 盲点 | シナリオ | 結果 |
|------|---------|------|
| false-fail | 並列の他プロセス (別 test run / 同 helper の正常利用) が同 glob のファイルを**削除** | `after < before` で差分が負になり leak なしでも FAIL |
| false-PASS | 自テストが 1 件 leak + 他プロセスが 1 件削除 | 相殺で `after == before` となり leak が**不可視** |

count はスカラーに縮約された情報であり、「どの path が増えたか」を失う。共有 namespace では increment と decrement が独立事象として並走するため、スカラー比較は決定論性を持たない。

### Canonical 実装 — path 集合差分

```bash
# 実行前の path 集合を退避 (sort 済み)
ls /tmp/rite-fix-normalized-* 2>/dev/null | sort > "$before_list"
run_test_target
ls /tmp/rite-fix-normalized-* 2>/dev/null | sort > "$after_list"

# comm -13: after にのみ存在する path = テスト実行中に新規出現した leak 候補
leaked=$(comm -13 "$before_list" "$after_list")
[ -z "$leaked" ] || fail "tempfile leak detected: $leaked"
```

- 他プロセスの**削除**は after 集合を減らすだけで新規 path を作らないため、`comm -13` の出力に影響しない (false-fail 解消)
- 自テストの leak は他プロセスの削除と無関係に after 側へ新規 path として現れる (相殺 false-PASS も検出)

### 適用条件 — TMPDIR 隔離が使えない場合の次善策

第一選択は `TMPDIR` 隔離 (test ごとに専用 tmpdir を払い出す ISOLATED_TMP 方式) だが、検査対象 helper の mktemp template が `/tmp/rite-fix-normalized-XXXXXX` のような**絶対 path 固定**だと `TMPDIR` が無視され隔離が効かない。helper 本体を変更せずテストのみで leak 検査を成立させる必要がある場合に、本 path 集合差分方式を採用する（採用時は Issue 提示の 2 択から helper 無変更を理由に差分方式を選んだ）。

### 検出能力の実証 — 双方向 mutation

起点事例では方式置換の上位互換性を双方向 mutation で実証した:

| Mutation | 期待 | 実測 |
|----------|------|------|
| leak 注入 (正方向): テスト中に glob 一致ファイルを残す | leak として検出 → TC FAIL | FAIL (検出能力あり) |
| 他プロセス削除 (逆方向): テスト中に既存 glob ファイルを削除 | leak なし判定 → TC PASS のまま | PASS (false-fail なし) |

count delta 方式では逆方向 mutation が FAIL する (false-fail) ため、「並列削除耐性 + leak 検出力」の両立が差分方式の厳密な上位互換性として確認された。

### 残存 limitation — add-direction ambiguity

並列の**他プロセスが同じ template で新規ファイルを追加** (= 他プロセス自身の正常な mktemp 利用) した場合、自テストの leak と区別できず false-fail しうる ambiguity は残存する (helper の mktemp template が TMPDIR 非対応である限り構造的に解消不能)。起点事例の review では reviewer がこれを認識した上で non-blocking (発生窓が狭く、根治は helper 側 template の TMPDIR 対応 = 別 scope) と判断した。完全な決定論性が必要になった時点で helper 側の mktemp template を `${TMPDIR:-/tmp}` 化する follow-up に進む。

## 関連ページ

- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](./mutation-testing-test-fidelity.md)
- [ratchet test では occurrence 単位 (`grep -oE | wc -l`) を原則とし line 単位は混在させない](./test-counting-occurrence-vs-line-unit.md)

## ソース

- [レビュー結果](../../raw/reviews/20260606T171726Z-pr-1295.md)
