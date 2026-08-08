---
type: "anti-patterns"
title: "sandbox 環境では raw な git status --porcelain が恒に非空になり clean 判定ガードが一度も発火しない"
domain: "anti-patterns"
promote: rite-plugin
description: "Claude Code の sandbox は write-block bind mount を untracked (??) エントリとして必ず表出させるため、raw な git status --porcelain は working tree が clean でも非空を返す。「clean なら skip」型のガードは一度も発火せず、dead code のまま通過する。プロジェクトに専用 helper がある場合は既存の使用箇所を grep して convention を確認してから書く。"
created: "2026-07-27T17:54:54+09:00"
updated: "2026-07-27T17:54:54+09:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260727T053017Z-pr-2036.md"
tags: []
confidence: high
---

# sandbox 環境では raw な git status --porcelain が恒に非空になり clean 判定ガードが一度も発火しない

## 概要

起点事例の cycle 2 で HIGH（repro 付き）として検出。新規追加した前置きガードが `git status --porcelain` を直接呼んでいたため、sandbox の write-block bind mount が `??` エントリとして必ず現れ、結果は恒に非空。「working tree が clean なら skip」という条件が**一度も真にならない** dead branch になっていた。

## 詳細

**症状**: sandbox 内で `git status --porcelain` を実行すると、実際には何も変更していなくても bind mount 由来の untracked エントリ（`??`）が並ぶ。したがって

```bash
if [ -z "$(git status --porcelain)" ]; then   # ← sandbox では決して真にならない
  skip
fi
```

は skip 側に入らない。テストで「clean のとき skip する」を検証していないと、ガードが機能していないことに気づけない。

**対処**: プロジェクトに専用 helper（rite では `hooks/scripts/lib/git-status-filtered.sh`）がある場合は必ずそれを経由する。helper の rc が非 0 のときは dirty 側（安全側）に倒す:

```bash
dirty=$(bash {plugin_root}/hooks/scripts/lib/git-status-filtered.sh) || dirty="__RITE_STATUS_UNKNOWN__"
if [ -z "$dirty" ]; then
  echo "[CONTEXT] GUARD=skip; reason=worktree_clean" >&2
elif [ "$dirty" = "__RITE_STATUS_UNKNOWN__" ]; then
  echo "[CONTEXT] GUARD=proceed; reason=status_unknown" >&2
else
  echo "[CONTEXT] GUARD=proceed; reason=worktree_dirty" >&2
fi
```

**一般化できる規則**:

- **既存 helper の有無を grep で先に確認する**。`git status --porcelain` を書く前に、同リポジトリ内の既存使用箇所（rite では `post-review-state-verify.sh` 等）を grep すれば convention が見える。helper が存在するのに raw を書くのは、その helper が塞いだ穴を再び開けることになる。
- **sentinel 値を導入したら実際に分岐で使う**。上記の `__RITE_STATUS_UNKNOWN__` は、reason を出し分ける分岐で消費しないと dead sentinel になる（同 PR cycle 3 で LOW 指摘として検出された）。
- **環境が状態検出の前提を壊すケースは他にもある**。sandbox は `git worktree remove` を "Device or resource busy" で構造的に失敗させ、SSH 経由の push/ls-remote を askpass 不在で失敗させる。「環境依存で恒に同じ結果を返す判定」は、テストで両方の分岐を通せるかを確認する。

## 関連ページ

- [worktree 運用の git 状態検出は .git 直書きせず git rev-parse --git-path で解決する](../patterns/worktree-aware-git-state-detection.md)
- [「invariant は logic 上成立」を信頼せず empirical reproduction で verify する](../heuristics/empirical-reproduction-over-invariant-reasoning.md)

## ソース

- [PR #2036 fix results (cycle 2)](../../raw/fixes/20260727T053017Z-pr-2036.md)
