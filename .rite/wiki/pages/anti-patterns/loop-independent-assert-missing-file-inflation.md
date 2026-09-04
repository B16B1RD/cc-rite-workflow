---
title: "loop 内の独立 assert は missing file で fail message が assertion 数倍に膨張する"
domain: "anti-patterns"
description: "per-iteration ループ内で `assert_grep` / `assert_not_grep` のような file 引数を取る assertion helper を **同一 file に対して独立に複数回呼ぶ** パターンは、当該 file が不在の場合 1 iteration = N fail message (N = assertion 数) に膨張する。"
created: "2026-05-19T05:50:00+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260518T203629Z-pr-1050.md"
  - type: "reviews"
    resource: "raw/reviews/20260519T023807Z-pr-1052.md"
tags: ["bash", "test-helpers", "assert-grep", "loop-pattern", "fail-message", "premature-abstraction"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-05-19T11:50:00+09:00" }
---

# loop 内の独立 assert は missing file で fail message が assertion 数倍に膨張する

## 概要

per-iteration ループ内で `assert_grep` / `assert_not_grep` のような file 引数を取る assertion helper を **同一 file に対して独立に複数回呼ぶ** パターンは、当該 file が不在の場合 1 iteration = N fail message (N = assertion 数) に膨張する。原本実装で「1 iteration = 1 fail」だった挙動を refactor で失う典型経路。loop の先頭で `if [ ! -f "$f" ]; then fail "..."; continue; fi` の missing-file guard を明示することで原本挙動を回復できる。

## 詳細

### refactor PR → 回復 PR で実証された failure mode

T-1 (`reviewer-scope-column-symmetry.test.sh`) を `_test-helpers.sh` API ベースに refactor した際、reviewer ファイル不在時の fail message が原本の 2 倍に膨張した:

| 状態 | per-reviewer の処理 | reviewer 不在時の fail 出力 |
|------|------------------|------------------------|
| 原本実装 | `if [ ! -f "$f" ]; then fail; continue; fi` で early-exit | 1 reviewer = 1 fail message |
| refactor PR 適用後 | `assert_grep` + `assert_not_grep` を独立に呼ぶ | 1 reviewer = 2 fail message |

回復 PR で per-reviewer loop の先頭に missing-file guard を再追加し原本挙動を回復した。

### 失敗判定そのものは正しい — 可読性のみが劣化

assertion 数倍 fail でも `FAIL > 0` で `exit 1` する判定は変わらないため、test の正誤は保たれる。**問題は将来 reviewer .md を削除する PR が発生したとき fail message が膨張して読み取り混乱を招くこと**。13 reviewer 全件不在では 13 → 26 行に増える計算。

### canonical 修正 pattern

loop 先頭で missing-file guard を明示する:

```bash
for r in api code-quality database ...; do
  f="$REVIEWERS_DIR/$r.md"
  if [ ! -f "$f" ]; then
    fail "$r.md (file not found: $f)"
    continue
  fi
  assert_grep "$f" "expected-pattern-A"
  assert_not_grep "$f" "forbidden-pattern-B"
done
```

guard を付けると assertion helper は file 存在を前提にできるため、fail message は「1 reviewer = 1 fail」に収束する。

### 横展開の判定基準 — guard 共通化を premature にしない

同パターンが他 reviewer-loop test (T-2/T-3/T-4) にも存在するが、対象 file が単一固定 (`$BASE_FILE` / `$SEVERITY_FILE` のような scalar) の場合は loop-times の inflation を起こさないため横展開は不要。**guard を一律 helper に組み込む / `_test-helpers.sh` に `assert_file_exists_or_fail` を追加する判断は、同種パターンが複数 test に再発した時点で初めて Lean に実施する**。

判定マトリクス:

| 状況 | 対応 |
|------|------|
| 単一 file への複数 assertion (1 file × N assert) | inline guard 1 行で足りる |
| loop × file への複数 assertion (N file × M assert) — **本ケース** | loop 先頭に guard、helper 化は保留 |
| 3+ test に同パターン再発 | shared helper への抽出を検討 (`_test-helpers.sh`) |

> **後続実証**: `_test-helpers.sh` に `assert_file_exists_or_fail` を抽出した時点では同パターン適用 test は T-1 のみ (1 test) で、3+ test 閾値には到達していなかった。それでも helper 化を採用したのは「将来 T-2/T-3/T-4 や他テストで同パターンが発生した際の予防策」として test-reviewer が回復 PR の review 時に**推奨事項として明示提案**したため。3+ 閾値は厳密な必須条件ではなく、reviewer の判断で 1 test 段階の **preventive extraction** も Lean と認められる経路があることが実測された。判定は (a) 該当パターンの再発予測可能性、(b) helper 化のコスト (LOC / TC 追加負荷)、(c) reviewer による明示推奨の有無、の 3 因子で行う。

### 関連 anti-pattern

[[asymmetric-fix-transcription]] と接続する側面がある: T-1 のみ修正して T-2/T-3/T-4 への横展開を判定せずに進めると、後続 PR で同 anti-pattern が再発する経路を残す。本ケースは「対象 file の cardinality が異なる」ことを判定基準として明示することで、premature な対称化を避けつつ将来再発時の guard 化判断を構造化できる。

## 関連ページ

- [shell script の共通 helper は再発時点で抽出する (Lean shared lib extraction)](../heuristics/shell-script-shared-lib-extraction.md)
- [Silent guard contract — pre-condition guard は pass() を呼ばずに silent return する](../patterns/silent-guard-contract-for-precondition-helpers.md)

## ソース

- [0 findings, 経験則記録のみ](../../raw/reviews/20260518T203629Z-pr-1050.md)
- [0 findings、helper 抽出の実装 PR、Silent guard contract + Excluded-with-rationale 経験則](../../raw/reviews/20260519T023807Z-pr-1052.md)
