---
title: "_SCRIPT_DIR canonicalize: cd 前に BASH_SOURCE を絶対 path 化する"
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
tags: []
confidence: high
---

# _SCRIPT_DIR canonicalize: cd 前に BASH_SOURCE を絶対 path 化する

## 概要

shell script が `cd "$repo_root"` を実行した後に `$(dirname "$0")` や `$(dirname "${BASH_SOURCE[0]}")` で sibling ライブラリを `source` すると、相対 path で invoke された場合に source path が `./scripts/lib/...` として壊れた状態で解釈される。cd より先に `_SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` で絶対 path に canonicalize する pattern が canonical。

## 詳細

### Failure mode

```bash
#!/usr/bin/env bash
cd "$repo_root"  # ← 先に cd すると $0 の相対 path は無効化される
source "$(dirname "$0")/lib/helpers.sh"  # ./scripts/foo.sh → ./scripts/lib/helpers.sh
                                          # → $repo_root/./scripts/lib/helpers.sh を探索して失敗
```

相対 path invocation (`bash ./scripts/foo.sh`) で発火する:

1. `$0` = `./scripts/foo.sh` (bash は invocation string をそのまま `$0` に保持)
2. `cd "$repo_root"` で CWD 移動
3. `$(dirname "$0")` は literal string 演算なので依然 `./scripts` を返す
4. `source` は CWD 基準で解決するため `$repo_root/./scripts/lib/helpers.sh` を探す
5. そのような path は通常存在しないため `source: No such file or directory` で失敗

### Canonical pattern

```bash
#!/usr/bin/env bash
# cd より先に BASH_SOURCE を絶対 path 化 (script header の直下で実行)
_SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$repo_root"
source "$_SCRIPT_DIR/lib/helpers.sh"  # 絶対 path なので CWD に依存しない
```

**ポイント**:

- `${BASH_SOURCE[0]}` を使う (スクリプトが source された場合でも自身の path を返すため `$0` より robust)
- `cd -P` で symlink を解決 (`-P` = physical path)
- subshell `$( ... )` 内で cd するため caller の CWD は変わらない
- 変数名に `_` prefix を付けて「script 内 private」であることを示す convention

### PR #550 での evidence

PR #550 (Issue #549) で `plugins/rite/hooks/scripts/wiki-worktree-setup.sh` / `wiki-worktree-commit.sh` / `wiki-ingest-commit.sh` が `plugins/rite/hooks/scripts/lib/wiki-config.sh` と `lib/worktree-git.sh` を `source` する refactoring で、初回実装が `cd "$repo_root"` 後の `$(dirname "${BASH_SOURCE[0]}")` 経路を使って live regression を起こした。sibling 13 scripts は既に `_SCRIPT_DIR` convention を採用しており、drift を解消するため全 3 script に統一 pattern を適用した。

**検証方法**: 相対 path invocation で回帰テスト:

```bash
cd plugins/rite/hooks
bash scripts/wiki-worktree-setup.sh
# → source が失敗すれば path canonicalization bug 再発
```

## 関連ページ

- [trap 登録 → mktemp の順序で tempfile lifecycle を守る](trap-register-before-mktemp.md)

## ソース

- [PR #550 cycle 1 review findings](raw/reviews/20260416T201615Z-pr-550.md)
- [PR #550 cycle 2 review findings (naming convention drift)](raw/reviews/20260416T214545Z-pr-550.md)
- [PR #550 cycle 1 fix results](raw/fixes/20260416T202213Z-pr-550.md)
