---
title: "Mechanical drift gate の exit 1 は git-stash before/after 集合比較で pre-existing 判定する"
domain: "heuristics"
description: "機械的 drift gate (distributed-fix-drift-check 等) が exit 1 で drift 検出を返したとき、自分の変更起因か pre-existing detector noise (P5 false-positive 等) かを git-stash before/after の findings 集合比較 (sort + diff) で機械的に確定する。完全一致 (N=N) なら drift-neutral と確定し gate を push back して commit、AFTER > BEFORE なら新規 drift を fix。件数だけでなく正規化集合の同一性まで確認する (1 解消 + 1 新規導入の入れ替えを件数比較が見逃すため)。reason 完全性は DoD 埋め込み comm -23 で独立担保。過去のレビューにおける 4 cycle で 3 回適用し毎回 64=64 を実測。"
promote: rite-plugin
created: "2026-05-29T15:59:38Z"
updated: "2026-05-29T15:59:38Z"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260529T150155Z-pr-1201.md"
  - type: "fixes"
    ref: "raw/fixes/20260529T151834Z-pr-1201.md"
  - type: "fixes"
    ref: "raw/fixes/20260529T153627Z-pr-1201.md"
  - type: "reviews"
    ref: "raw/reviews/20260529T145515Z-pr-1201.md"
  - type: "reviews"
    ref: "raw/reviews/20260529T151325Z-pr-1201.md"
  - type: "reviews"
    ref: "raw/reviews/20260529T152911Z-pr-1201.md"
  - type: "reviews"
    ref: "raw/reviews/20260529T154822Z-pr-1201.md"
tags: [drift-check, pre-commit-gate, git-stash, revert-test, false-positive, scope-discipline, push-back]
confidence: high
---

# Mechanical drift gate の exit 1 は git-stash before/after 集合比較で pre-existing 判定する

## 概要

pre-commit drift gate (`distributed-fix-drift-check.sh` 等の機械的 lint) が `exit 1` で「drift 検出」を返したとき、その findings が **自分の変更が導入した drift** なのか **commit 前から存在する detector noise (pre-existing false-positive)** なのかを区別する手段が gate 自身にはない。両者を取り違えると、(a) pre-existing noise を「修正」しようとして scope を逸脱し fix ループが非収束になる、(b) あるいは自分が導入した drift を見逃す。`git stash` で自分の変更を一時退避し、**変更あり (HEAD+working) / 変更なし (HEAD only) の 2 状態で drift-check を実行して findings 集合を比較**することで、新規 drift 件数を機械的に確定する。集合が完全一致 (N=N) なら自分の変更は drift-neutral と確定し、gate の `exit 1` を pre-existing noise として push back できる。起点事例の 4 cycle review-fix loop で 3 回 (cycle 1/2/3 fix) 適用し、毎回 64=64 の完全一致を実測した。

## 詳細

### 失敗 mode (この heuristic が無い場合)

`distributed-fix-drift-check.sh --target ...` のような機械的 gate は、対象ファイル全体を scan して reason 表との同期や P5 列挙の網羅性を検査する。P5 (parenthesized-list 検出器) は code-fence 形式と括弧列挙形式の format mismatch で **恒常的に false-positive を吐く** ことがあり、base branch でも HEAD でも同件数 fail する pre-existing noise になる。この状態で gate が `exit 1` を返すと:

- gate の指示 (例: 「Return to ステップ 2 to fix the detected drifts」) に盲従すると、PR scope 外の pre-existing noise を「修正」しようとして scope discipline を破り、reviewer が次 cycle で新規 finding を出して fix ループが永久化する
- 逆に「全部 noise だろう」と無検証で push すると、自分が実際に導入した drift を見逃す

gate の `exit 1` は「drift がある」としか言わず、「**その drift をあなたが導入したか**」を答えない。この判定を人手の目視に委ねると、長大な findings リスト（実測では 64 件）を前に取り違えが起きる。

### canonical 手順: git-stash before/after 集合比較

```bash
# AFTER (自分の変更あり) の drift findings を正規化取得
bash "$plugin_root/hooks/scripts/distributed-fix-drift-check.sh" --target <file> --quiet 2>&1 | sort > /tmp/drift-after.txt
after_count=$(grep -c '^\[drift\]' /tmp/drift-after.txt)

# 自分の変更を一時退避し BEFORE (変更なし) を取得
git stash push -- <file>
bash "$plugin_root/hooks/scripts/distributed-fix-drift-check.sh" --target <file> --quiet 2>&1 | sort > /tmp/drift-before.txt
before_count=$(grep -c '^\[drift\]' /tmp/drift-before.txt)
git stash pop

# 件数 + 正規化集合の両方を比較
echo "before=$before_count after=$after_count"
diff /tmp/drift-before.txt /tmp/drift-after.txt && echo "(identical: 新規 drift ゼロ)"
```

判定:

| 比較結果 | 解釈 | アクション |
|---------|------|-----------|
| `diff` が空 (集合完全一致、N=N) | 自分の変更は drift-neutral | gate の exit 1 を pre-existing noise として push back し commit |
| AFTER に BEFORE 非含有の行が出現 | 自分の変更が新規 drift を導入 | その行を fix (gate の指示が正当) |
| AFTER < BEFORE (drift 減少) | 自分の変更が既存 drift を解消 | commit (改善) |

**件数だけでなく `sort` した行集合を `diff` で比較する**のが要点。件数一致 (64=64) でも内訳が入れ替わっている (1 件解消 + 1 件新規導入) ケースを件数比較だけでは見逃すため、正規化集合の同一性まで確認する。

### push back の正当化

集合が完全一致したら、gate の `exit 1` は機械的 false-positive と確定する。このとき CLAUDE.md の「スコープを越えない」「押し返すべきときは押し返す」に従い、gate の指示 (Step 2 に戻って drift を fix) に盲従せず、**before/after 比較の実測を根拠に push back して commit する**。push back の根拠は commit message / fix raw に「64=64 の集合一致を git-stash before/after で実測、全て pre-existing P5 detector noise、PR が follow-up 明示済み」と記録し、後続 reviewer が同じ判定を再現できるようにする。

### reason 完全性の独立担保

drift gate の P5/P2 noise が信頼できない場合でも、reason 表の完全性 (emit される全 reason が表に存在するか) は **DoD 埋め込みの `comm -23` スクリプト**で独立に担保できる（実測では fix.md ステップ 5.1 の DoD 検証スクリプトが空出力 = WM_UPDATE_FAILED reason ⊆ 表 を保証した）。「機械的 gate の exit code」と「契約の完全性」を別レイヤーで検証することで、gate の noise に判断を引きずられない。

### 関連 anti-pattern との区別

| pattern | 焦点 |
|---------|------|
| **本 heuristic** | 機械的 gate の exit 1 が自分起因か pre-existing かを before/after 集合比較で判定 |
| [累積対策 PR の review-fix loop で fix 自体が drift を導入する](../anti-patterns/fix-induced-drift-in-cumulative-defense.md) | fix が **実際に** 新規 drift を導入する失敗 mode (本 heuristic の before/after 比較が AFTER > BEFORE を返すケース) |
| [`rejected(scope-creep)` judgment は cross-validation + empirical revert test で gate する](./scope-creep-rejection-empirical-gate.md) | reviewer の scope-creep 棄却判定を empirical revert test で gate |

本 heuristic は「tooling gate の false-positive を実測で discriminate する」具体手順。fix-induced-drift は本手順が陽性 (新規 drift あり) を返すケース、scope-creep-rejection は reviewer 判断レイヤーの empirical gate。

## 関連ページ

- [累積対策 PR の review-fix loop で fix 自体が drift を導入する](../anti-patterns/fix-induced-drift-in-cumulative-defense.md)
- [`rejected(scope-creep)` judgment は cross-validation + empirical revert test で gate する](./scope-creep-rejection-empirical-gate.md)
- [「invariant は logic 上成立」を信頼せず empirical reproduction で verify する](./empirical-reproduction-over-invariant-reasoning.md)

## ソース

- [PR #1201 fix cycle 1 (comment rot 修正 + 64=64 実測)](../../raw/fixes/20260529T150155Z-pr-1201.md)
- [PR #1201 fix cycle 2 (stderr capture 追加 + 64=64 実測)](../../raw/fixes/20260529T151834Z-pr-1201.md)
- [PR #1201 fix cycle 3 (用語定義表 stale 同期 + 64=64 実測)](../../raw/fixes/20260529T153627Z-pr-1201.md)
- [PR #1201 review cycle 1 (drift-check pre-existing noise + DoD comm -23)](../../raw/reviews/20260529T145515Z-pr-1201.md)
- [PR #1201 review cycle 2 (P2/P5 64 件 pre-existing 判定)](../../raw/reviews/20260529T151325Z-pr-1201.md)
- [PR #1201 review cycle 3 (revert test で pre-existing 切り分け)](../../raw/reviews/20260529T152911Z-pr-1201.md)
- [PR #1201 review cycle 4 (git-stash before/after 戦略の収束記録)](../../raw/reviews/20260529T154822Z-pr-1201.md)
