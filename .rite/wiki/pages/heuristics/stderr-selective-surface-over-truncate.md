---
title: "stderr ノイズ削減: truncate ではなく selective surface で解く"
domain: "heuristics"
created: "2026-04-16T19:37:16Z"
updated: "2026-04-16T19:37:16Z"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260415T095818Z-pr-529-fix-cycle-1.md"
  - type: "fixes"
    ref: "raw/fixes/20260415T124218Z-pr-529-cycle-3-fix.md"
  - type: "reviews"
    ref: "raw/reviews/20260415T121203Z-pr-529-cycle-3.md"
tags: ["bash", "stderr", "observability", "noise-reduction"]
confidence: high
---

# stderr ノイズ削減: truncate ではなく selective surface で解く

## 概要

success path で git などのコマンドが出す stderr の「ノイズ」を抑えたい場面で、`2>/dev/null` や無条件 truncate を使うと legitimate な warning（`unable to rmdir` / remote hook advice など）まで silent drop してしまう。正しい設計は「情報量を減らす」ではなく「ノイズと警告を分離する」— git 側の `-q` / `--quiet` で informational を抑え、helper で warning/hint/error 行のみ selective surface する。

## 詳細

### Anti-pattern: 全 truncate

```bash
# ❌ NG: cycle 2 fix で導入された silent regression
dump_git_err() {
  # success path でも無条件 truncate
  : > "$git_err"
}
```

この解決は cycle 1 で出た「`Switched to branch 'wiki'` ノイズ」を消す動機で書かれたが、反面 legitimate warning (`hint: ...` / `unable to ...`) まで silent drop し、cycle 3 で silent regression として再検出された。

### Canonical pattern: selective surface

```bash
# ✅ OK: warning/hint/error 行のみ filter surface
surface_git_warnings() {
  local err_file="$1"
  [ -s "$err_file" ] || return 0
  head -n 10 "$err_file" | grep -iE '^(warning|hint|error):' >&2 || true
}

# 呼び出し側
git cmd 2>"$git_err"
rc=$?
if [ "$rc" -eq 0 ]; then
  surface_git_warnings "$git_err"  # success でも warning は残す
else
  head -3 "$git_err" | sed 's/^/  git: /' >&2
fi
```

### 責務分離の原則

stderr に出力される情報を以下の 2 責務に分ける:

| 責務 | 分類 | 対処 |
|------|------|------|
| informational (消してよい) | `Switched to branch` / `Already up to date` | `git <cmd> -q` / `--quiet` で上流抑制 |
| warning (消してはいけない) | `warning:` / `hint:` / `error:` | helper で selective surface |

「情報過多の解決」と「warning の silent loss」を同じツール（truncate）で扱わない。後者の fail mode を増やすだけ。

### `surface_git_warnings` の実装要点

- `head -n 10`: 大量 stderr で context を埋めない
- `grep -iE '^(warning|hint|error):`: 先頭タグで filter（git 出力のフォーマット安定性に依拠）
- `|| true`: grep no-match (rc=1) で script 全体を abort させない
- `>&2`: stdout への混入防止（parser 依存パイプラインを保護）

## 関連ページ

- [`if ! cmd; then rc=$?` は常に 0 を捕捉する](anti-patterns/bash-if-bang-rc-capture.md)

## ソース

- [PR #529 fix cycle 1 (git stderr tempfile 退避の副作用)](raw/fixes/20260415T095818Z-pr-529-fix-cycle-1.md)
- [PR #529 cycle 3 fix (success path で selective surface 導入)](raw/fixes/20260415T124218Z-pr-529-cycle-3-fix.md)
- [PR #529 cycle 3 review (全 truncate の silent regression 検出)](raw/reviews/20260415T121203Z-pr-529-cycle-3.md)
