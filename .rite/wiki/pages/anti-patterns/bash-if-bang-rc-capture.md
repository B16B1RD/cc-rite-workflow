---
title: "`if ! cmd; then rc=$?` は常に 0 を捕捉する"
domain: "anti-patterns"
promote: rite-plugin
created: "2026-04-16T19:37:16Z"
updated: "2026-07-21T18:30:00Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260721T171603Z-pr-1959.md"
  - type: "reviews"
    ref: "raw/reviews/20260517T221249Z-pr-1032.md"
  - type: "fixes"
    ref: "raw/fixes/20260415T095818Z-pr-529-fix-cycle-1.md"
  - type: "fixes"
    ref: "raw/fixes/20260415T124218Z-pr-529-cycle-3-fix.md"
  - type: "fixes"
    ref: "raw/fixes/20260416T172110Z-pr-548.md"
  - type: "fixes"
    ref: "raw/fixes/20260416T173607Z-pr-548-cycle3.md"
  - type: "reviews"
    ref: "raw/reviews/20260416T171008Z-pr-548.md"
  - type: "reviews"
    ref: "raw/reviews/20260416T173035Z-pr-548.md"
  - type: "reviews"
    ref: "raw/reviews/20260427T154519Z-pr-688.md"
tags: ["bash", "rc-capture", "silent-failure"]
confidence: high
---

# `if ! cmd; then rc=$?` は常に 0 を捕捉する

## 概要

bash の `!` 演算子は直前コマンドの exit status を boolean で反転するため、`if ! cmd; then ...` ブロック内での `$?` は `!` の結果 (= 0) を返す。診断目的で書いた `rc=$?` capture は常に `0` となり、実際の非ゼロ exit code は失われる。また、`case` 文による 3 値分離 (rc=0 / rc=1 / rc>1) を破壊する。

## 詳細

### 実証

```bash
$ bash -c 'if ! (exit 5); then rc=$?; echo "captured rc=$rc"; fi'
captured rc=0    # 期待: 5 / 実際: 0
```

### 影響する exit code 3 値コマンド

以下のコマンドは rc=0 / rc=1 / rc>1 で異なる語彙を持つため、`if !` で wrap すると real error が silent に正常ケースに丸まる:

| コマンド | rc=0 | rc=1 | rc>1 |
|---------|------|------|------|
| `git diff --quiet` | 差分なし | 差分あり（正常） | real error |
| `grep` | マッチあり | マッチなし（正常） | real error |
| `diff` | 一致 | 不一致（正常） | real error |

例: `if ! git diff --quiet` パターンは rc=1 (has-diff、正常) と rc>1 (real error) を両方 `has_changes=true` に丸める。

### Canonical Fix

```bash
# ❌ NG: 3 値が binary に畳まれ、rc も常に 0
if ! cmd; then
  rc=$?  # 常に 0
  handle_error "$rc"
fi

# ✅ OK: 明示的な rc capture + case による 3 値分離
set +e
cmd
rc=$?
set -e
case "$rc" in
  0) ;;           # success
  1) ;;           # expected non-zero (no-diff / no-match etc.)
  *)              # real error
    handle_error "$rc"
    ;;
esac
```

### Detection Heuristic

fix 直後に全 *.md/*.sh で anti-pattern をスキャン:

```bash
grep -nE 'if ! .*; then' --include='*.md' --include='*.sh' -r .
```

### Asymmetric Transcription との複合悪化

同型 pattern が複数箇所にある場合、片方だけ fix すると Asymmetric Fix Transcription の温床となる。2 site 同時事例では `ingest.md Phase 1.3` と `init.md Phase 3.5` の両方に本 anti-pattern があり、cycle 2 fix は前者のみ修正し cycle 3 で後者が triple cross-validation で検出された。fix 時は関連する全スクリプト・全 phase を grep で網羅的に確認すること。

### 累積 14 回目の cycle 35: 同 commit 内 4 site 同時播種 (累積 13 回目 + self-referential)

cycle 35 commit message が learned 節で「累積 12 回目の Asymmetric Fix Transcription」を **明記しながら**、同じ commit 内の F-07 修正で同型 `if !` anti-pattern を新規 4 site (`state-read.sh:139-145, 155-161` / `flow-state-update.sh:170-176, 185-191`) に同時播種した self-referential failure mode が cycle 36 で実測された。実機検証:

```bash
$ set -euo pipefail; if ! bash -c 'exit 7'; then emit_rc=$?; echo $emit_rc; fi
0  # 期待 7
```

production の sentinel emit failure 経路で operator に false `rc=0` を表示する silent regression。caller migration / refactor で同型 pattern を複数 site に同時導入する PR では、commit 直前に `grep -nE 'if ! .*; then.*rc=\$\?' --include='*.sh' -r .` で全 site self-check が必須。

→ 「learned 節で言及した直後の同 commit で再演する」特殊 self-referential pattern は累積 35+ cycle 越えで初観測 ([`fix-induced-drift-in-cumulative-defense.md`](fix-induced-drift-in-cumulative-defense.md) に詳述)。

### bash semantics 版の cycle 1: format 同期 refactor で新 SoT の bash 構造を見落とした再発

ある PR は `plugins/rite/commands/pr/fix.md` L797-L802 の `mktemp_failure_find_err` 経路を、先行 PR が導入した新 SoT (L1147-L1150 `mktemp_failure_norm_tmp`) と format 同期する小規模 refactor。元の `|| find_err=""` silent fallback を WARNING-emit 構造に書き換える際、**新 SoT は `if cmd; then ... else rc=$?` 形式**で実装されていたにもかかわらず、本 PR cycle 1 では `if ! cmd; then rc=$?; ...; fi` 形式で実装し本 anti-pattern を新規導入。reviewer 2 名 (prompt-engineer / code-quality) が cross-validation 一致で CRITICAL 検出。

**累積再発要因の独自観点**: 「**format 同期 (WARNING wording / CONTEXT emit token 一致)**」と「**structural / runtime semantics 同期 (bash の if-else 構造そのものを SoT と完全一致)**」を区別する責務が confused。同じ wording を異なる bash 構造で実装すると、`if !` boolean 反転による rc 常時 0 化 silent regression を新規 introduce する。本 PR は累積 34 回目 Asymmetric Fix Transcription (`asymmetric-fix-transcription.md` 累積 34 回目セクション参照) の起点となり、「**format token symmetry / bash structure symmetry / runtime semantics symmetry の三層対称化義務**」doctrine を Wiki に確立した。

→ SoT を rebrand する際は WARNING wording / CONTEXT emit format だけでなく、bash の if-else 構造そのものを SoT と完全一致させること。小規模な format 同期 PR ほど reviewer 注意が runtime semantics 層に届きにくいため、本 anti-pattern の発火リスクが高い。

### 姉妹型: `set -e` 下の裸 `$?` 読み `var=$(cmd); rc=$?` は rc 行に到達しない

`if !` 反転とは別の同族罠として、`set -euo pipefail` 下で `var=$(失敗コマンド); rc=$?` と書くと、**代入コマンド自体が errexit を発火してスクリプト（またはループ）全体が abort し、`rc=$?` 行は dead code になる**。errexit 事例の Gate 3（`_st_out=$(git status ...); _st_rc=$?`）では、この形が「status rc≠0 → conservative skip」分岐を実質到達不能にしており、broken worktree 入力（このゲートが守るべきまさにその入力）で reap ループごと停止していた。正しい形は既存 canonical fix と同型:

```bash
# ✅ OK: 代入の失敗を || で吸収して rc を捕捉（set -e 下でも abort しない）
rc=0
var=$(cmd) || rc=$?
```

`if !` 型（rc が常に 0 になる）と裸 `$?` 型（rc 行に到達せず abort する）は症状が異なるが、いずれも「`rc=0; var=$(cmd) || rc=$?` 形式」が共通の canonical fix である。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [累積対策 PR の review-fix loop で fix 自体が drift を導入する](../anti-patterns/fix-induced-drift-in-cumulative-defense.md)
- [function 内 `local v=$(...)` と top-level `v=$(...)` の `set -e` 伝播差](../anti-patterns/bash-local-vs-toplevel-pipefail-asymmetry.md)

## ソース

- [PR #529 fix cycle 1 (rollback safety)](../../raw/fixes/20260415T095818Z-pr-529-fix-cycle-1.md)
- [PR #529 cycle 3 fix (git diff --quiet 3 値区別)](../../raw/fixes/20260415T124218Z-pr-529-cycle-3-fix.md)
- [PR #548 cycle 2 fix (if ! bash gotcha 網羅検出)](../../raw/fixes/20260416T172110Z-pr-548.md)
- [PR #548 cycle 3 fix (init.md 対称位置検出)](../../raw/fixes/20260416T173607Z-pr-548-cycle3.md)
- [PR #548 cycle 2 review (17 findings)](../../raw/reviews/20260416T171008Z-pr-548.md)
- [PR #548 cycle 3 review (triple cross-validation)](../../raw/reviews/20260416T173035Z-pr-548.md)
- [PR #688 cycle 36 review — self-referential 4 site 同時播種 (累積 13 回目)](../../raw/reviews/20260427T154519Z-pr-688.md)
- [PR #1032 cycle 1 review (format 同期 refactor で `if ! cmd; then rc=$?` 形式を新規導入、累積 34 回目 Asymmetric Fix Transcription の起点、三層対称化義務 doctrine 確立)](../../raw/reviews/20260517T221249Z-pr-1032.md)
- [PR #1959 review cycle 1 (set -e 下の裸 `$?` 読みが Gate 3 conservative skip を dead code 化)](../../raw/reviews/20260721T171603Z-pr-1959.md)
