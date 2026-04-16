---
title: "Exit code semantic preservation: caller は case で語彙を保持する"
domain: "patterns"
created: "2026-04-16T19:37:16Z"
updated: "2026-04-16T19:37:16Z"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260415T095818Z-pr-529-fix-cycle-1.md"
  - type: "reviews"
    ref: "raw/reviews/20260415T094007Z-pr-529.md"
tags: ["bash", "exit-code", "api-contract", "sentinel"]
confidence: high
---

# Exit code semantic preservation: caller は case で語彙を保持する

## 概要

shell script の header で `Exit codes: 0=success, 2=legitimate skip, 3=real error` のように exit code の語彙を定義しても、caller が `if cmd` / `cmd || handle_error` のように non-zero を一律 failure 扱いすると、legitimate skip も false-positive incident として報告される。caller 側に case 文で exit code ごとの分岐を書くのが API 契約の完成。

## 詳細

### Anti-pattern: 一律 failure 扱い

```bash
# ❌ NG: exit 2 (legitimate skip) も failure として sentinel emit
if ! bash wiki-ingest-commit.sh; then
  echo "[CONTEXT] WORKFLOW_INCIDENT=1; type=ingest_failed"
fi
```

script が `exit 2` で skip（例: `wiki.enabled=false`）した場合も incident として報告され、false-positive が観測ダッシュボードを汚染する。

### Canonical pattern: case 文で語彙を保持

```bash
set +e
bash wiki-ingest-commit.sh
rc=$?
set -e
case "$rc" in
  0)
    echo "[CONTEXT] WIKI_INGEST=ok"
    ;;
  2)
    # legitimate skip — incident 扱いしない
    echo "[CONTEXT] WIKI_INGEST_SKIPPED=1; reason=wiki-disabled"
    ;;
  3)
    echo "ERROR: wiki-ingest-commit.sh 内部で git 操作失敗 (rc=3)" >&2
    exit 1
    ;;
  4)
    # commit landed, push failed — 非 fatal
    echo "WARNING: commit は landed したが push に失敗 (rc=4)" >&2
    echo "  手動回復: git -C .rite/wiki-worktree push origin $wiki_branch" >&2
    ;;
  *)
    echo "ERROR: 予期しない exit code ($rc)" >&2
    exit 1
    ;;
esac
```

### 双方向契約

exit code 語彙は片方向の宣言では不十分。以下の両方を揃える:

1. **script 側**: header comment に `Exit codes:` セクションを書く
2. **caller 側**: `case "$rc" in` で全 rc 値を explicit に routing

`case` に `*)` デフォルトを置いて未知の rc を fail-fast させることで、script 側が exit code を追加したときの silent OK 判定も防げる。

### sentinel emit との組み合わせ

skip 経路では `[CONTEXT] WIKI_INGEST_SKIPPED=1; reason=...` のような sentinel を emit することで、caller の caller（workflow 監視側）が incident とそうでないものを区別できる。sentinel + case の 2 層で語彙を保持する。

### `$?` 経由の 3 値コマンドとの違い

本パターンは「独自定義 exit code を持つスクリプト」を対象とする。`git diff --quiet` のような標準コマンドの 3 値 exit code (0/1/>1) も case で扱うが、そちらは [`if ! cmd` anti-pattern](anti-patterns/bash-if-bang-rc-capture.md) が別軸で混在するので区別して扱うこと。

## 関連ページ

- [`if ! cmd; then rc=$?` は常に 0 を捕捉する](anti-patterns/bash-if-bang-rc-capture.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [PR #529 fix cycle 1 (exit 2 semantic preservation)](raw/fixes/20260415T095818Z-pr-529-fix-cycle-1.md)
- [PR #529 review (6-reviewer による exit code mismatch 検出)](raw/reviews/20260415T094007Z-pr-529.md)
