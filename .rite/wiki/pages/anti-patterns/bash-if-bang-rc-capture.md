---
title: "`if ! cmd; then rc=$?` は常に 0 を捕捉する"
domain: "anti-patterns"
created: "2026-04-16T19:37:16Z"
updated: "2026-04-16T19:37:16Z"
sources:
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

同型 pattern が複数箇所にある場合、片方だけ fix すると Asymmetric Fix Transcription の温床となる。PR #548 では `ingest.md Phase 1.3` と `init.md Phase 3.5` の両方に本 anti-pattern があり、cycle 2 fix は前者のみ修正し cycle 3 で後者が triple cross-validation で検出された。fix 時は関連する全スクリプト・全 phase を grep で網羅的に確認すること。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [PR #529 fix cycle 1 (rollback safety)](raw/fixes/20260415T095818Z-pr-529-fix-cycle-1.md)
- [PR #529 cycle 3 fix (git diff --quiet 3 値区別)](raw/fixes/20260415T124218Z-pr-529-cycle-3-fix.md)
- [PR #548 cycle 2 fix (if ! bash gotcha 網羅検出)](raw/fixes/20260416T172110Z-pr-548.md)
- [PR #548 cycle 3 fix (init.md 対称位置検出)](raw/fixes/20260416T173607Z-pr-548-cycle3.md)
- [PR #548 cycle 2 review (17 findings)](raw/reviews/20260416T171008Z-pr-548.md)
- [PR #548 cycle 3 review (triple cross-validation)](raw/reviews/20260416T173035Z-pr-548.md)
