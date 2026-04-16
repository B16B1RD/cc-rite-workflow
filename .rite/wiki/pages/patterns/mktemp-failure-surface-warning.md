---
title: "mktemp 失敗は silent 握り潰さず WARNING を可視化する"
domain: "patterns"
created: "2026-04-16T19:37:16Z"
updated: "2026-04-16T19:37:16Z"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260416T165559Z-pr-548.md"
  - type: "reviews"
    ref: "raw/reviews/20260416T171008Z-pr-548.md"
tags: ["bash", "mktemp", "disk-full", "inode-exhaustion", "observability"]
confidence: medium
---

# mktemp 失敗は silent 握り潰さず WARNING を可視化する

## 概要

`mktemp ... || echo ""` パターンは disk full / inode 枯渇 / permission denied を silent に握り潰し、後続の stderr capture 機能が無効化されたことを操作者に気付かせない。`if ! var=$(mktemp ...); then WARNING; var=""; fi` 形式で WARNING を stderr に surface する。

## 詳細

### Anti-pattern

```bash
# ❌ NG: mktemp 失敗を silent に握り潰す
git_err=$(mktemp /tmp/rite-git-err-XXXXXX 2>/dev/null) || git_err=""

# この時点で git_err=="" だと
git cmd 2>"${git_err:-/dev/null}"  # stderr は捨てられる（silent）
```

- disk full や inode 枯渇は low-frequency だが high-severity な障害
- silent 握り潰しにより、後続の `head -3 "$git_err"` による詳細 surface が機能しないまま運用が続く
- 根本原因（ディスク満杯）への気付きが遅れる

### Canonical pattern

```bash
# ✅ OK: 失敗を WARNING で可視化
if ! git_err=$(mktemp /tmp/rite-git-err-XXXXXX); then
  echo "WARNING: git stderr 退避用 tempfile の mktemp に失敗しました。stderr 詳細は失われます" >&2
  echo "  対処: /tmp の inode 枯渇 / read-only filesystem / permission 拒否を確認してください" >&2
  echo "[CONTEXT] FALLBACK=1; reason=mktemp_failure" >&2
  git_err=""
fi
```

- 操作者に root cause を伝える（inode / FS / permission の 3 候補）
- `[CONTEXT]` sentinel で機械可読な failure flag を emit する
- `git_err=""` で後続の fallback 経路は維持（best-effort continuation）

### `exec 9>...` の hard fail との区別

`set -euo pipefail` 配下では `exec 9>file` の I/O 失敗も script 全体を hard fail させる。advisory lock のような best-effort リソースでは subshell guard で test してから本命 `exec` に進む:

```bash
# ✅ 2 段階パターン
if ( exec 9>"$lockfile" ) 2>/dev/null; then
  exec 9>"$lockfile"
  flock -n 9 || { echo "WARNING: lock taken, skipping" >&2; exit 0; }
fi
```

### Detection Heuristic

```bash
# 全 *.sh で anti-pattern をスキャン
grep -nE 'mktemp[^|]*\|\|[[:space:]]*[a-z_]+=""' --include='*.sh' -r .
```

## 関連ページ

- [trap 登録 → mktemp の順序で tempfile lifecycle を守る](patterns/trap-register-before-mktemp.md)
- [stderr ノイズ削減: truncate ではなく selective surface で解く](heuristics/stderr-selective-surface-over-truncate.md)

## ソース

- [PR #548 cycle 1 fix (mktemp 失敗の silent 握り潰し禁止)](raw/fixes/20260416T165559Z-pr-548.md)
- [PR #548 cycle 2 review (stderr suppression pattern の網羅検出)](raw/reviews/20260416T171008Z-pr-548.md)
