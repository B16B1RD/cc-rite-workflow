---
title: "Bash lib helper の contract は実装と同じ rigour で保証する"
domain: "patterns"
created: "2026-04-17T00:00:00+00:00"
updated: "2026-04-17T00:00:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260416T201615Z-pr-550.md"
  - type: "reviews"
    ref: "raw/reviews/20260416T214545Z-pr-550.md"
  - type: "fixes"
    ref: "raw/fixes/20260416T202213Z-pr-550.md"
  - type: "fixes"
    ref: "raw/fixes/20260416T214823Z-pr-550.md"
tags: []
confidence: high
---

# Bash lib helper の contract は実装と同じ rigour で保証する

## 概要

shared bash lib の docstring に「caller owns shell options」「caller's outer trap is restored」と書くなら、実装側で `set -e` 強制 / `trap - EXIT ...` 消去をしてはいけない。`$-` による errexit 状態保存 + `trap -p` + `eval` による outer trap 保存復元を組み合わせて、宣言通りの不変条件を実装で担保する。signal handling や nested function scope leak など bash 固有の subtle 挙動も docstring の Contract 節に明示する。

## 詳細

### Failure mode

```bash
# lib/helpers.sh
#
# Contract: caller owns shell options; caller's outer trap is preserved.
my_helper() {
  set -e                           # ← 契約違反: caller の errexit state を強制上書き
  trap 'cleanup' EXIT              # ← 契約違反: caller の outer EXIT trap を clobber
  # ... body ...
  trap - EXIT                      # ← 契約違反: caller の outer trap が復元されない
}
```

caller が helper 前に `set +e` で fail-tolerant mode に入っていても、helper 呼出で `set -e` に塗り替えられ、次の non-zero exit で silent abort する。caller が `trap 'outer_cleanup' EXIT` を設置していても helper が `trap - EXIT` で消し去り、caller の cleanup が発火しない silent regression を起こす。

### Canonical pattern

```bash
my_helper() {
  # 1. errexit 状態を保存
  local _errexit_state=0
  case $- in *e*) _errexit_state=1 ;; esac

  # 2. outer trap を保存 (trap -p は POSIX-safe な eval 入力を返す)
  local _outer_exit _outer_int _outer_term _outer_hup
  _outer_exit=$(trap -p EXIT)
  _outer_int=$(trap -p INT)
  _outer_term=$(trap -p TERM)
  _outer_hup=$(trap -p HUP)

  # 3. 復元用の private helper (nested function は caller scope に leak する)
  _my_helper_restore_state() {
    if [[ -n "$_outer_exit" ]]; then eval "$_outer_exit"; else trap - EXIT; fi
    if [[ -n "$_outer_int"  ]]; then eval "$_outer_int";  else trap - INT;  fi
    if [[ -n "$_outer_term" ]]; then eval "$_outer_term"; else trap - TERM; fi
    if [[ -n "$_outer_hup"  ]]; then eval "$_outer_hup";  else trap - HUP;  fi
    if [[ $_errexit_state -eq 1 ]]; then set -e; else set +e; fi
  }

  # 4. 自分の内部 trap を installed (caller の trap は保存済みなので上書き OK)
  trap 'rm -f "${tmp1:-}" "${tmp2:-}"' EXIT INT TERM HUP

  # 5. 全 return path で必ず _my_helper_restore_state を呼ぶ
  # ... body ...
  _my_helper_restore_state
  return 0
}
```

### Contract docstring の必須項目

```
# Contract:
#   - Does NOT toggle `set -e` / `set -u` / `set -o pipefail`. The function
#     saves errexit state via `$-` and restores before every return.
#   - Does NOT leave EXIT / INT / TERM / HUP traps installed after return.
#     The caller's outer trap is preserved via `trap -p` / `eval`.
#   - Signal-handling limitation: while this helper is running, its internal
#     trap OVERRIDES the caller's signal handlers. Callers needing
#     signal-safe rollback during helper execution should wrap in subshell.
#   - Nested function `_foo_restore_state` leaks into caller's global scope
#     (bash dynamic scoping). Underscore prefix marks it as private: callers
#     MUST NOT invoke it directly or shadow it.
```

### PR #550 での evidence

PR #550 (Issue #549) で `worktree_commit_push()` が初回実装で `set -e` 強制と `trap - EXIT` 消去をしており、caller 側で signal-safe cleanup を想定していた rollback 経路が silent に壊れる設計欠陥があった。cycle 1 fix で `$-` + `trap -p`/`eval` pattern に書き直し、cycle 2 で signal override limitation と nested function leak を docstring 化、cycle 3 で naming convention drift を comment 補強した。最終形 (`plugins/rite/hooks/scripts/lib/worktree-git.sh`) は 4 cycle を経て完成したが、初回から contract docstring の rigour を実装と揃えていれば 2-3 cycle 分の直行で済んだ。

## 関連ページ

- [`if ! cmd; then rc=$?` は常に 0 を捕捉する](../anti-patterns/bash-if-bang-rc-capture.md)

## ソース

- [PR #550 cycle 1 review findings](raw/reviews/20260416T201615Z-pr-550.md)
- [PR #550 cycle 2 re-review findings](raw/reviews/20260416T214545Z-pr-550.md)
- [PR #550 cycle 1 fix results](raw/fixes/20260416T202213Z-pr-550.md)
- [PR #550 cycle 3 fix results (LOW docstring improvements)](raw/fixes/20260416T214823Z-pr-550.md)
