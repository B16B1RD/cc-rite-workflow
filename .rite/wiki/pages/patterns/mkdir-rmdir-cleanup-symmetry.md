---
title: "mkdir -p で作成した directory は rmdir で対称 cleanup する (probe file 単独削除は pollution 残留)"
domain: "patterns"
created: "2026-04-19T01:10:00+00:00"
updated: "2026-04-19T01:10:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260419T004413Z-pr-585.md"
  - type: "fixes"
    ref: "raw/fixes/20260419T004921Z-pr-585.md"
tags: []
confidence: high
---

# mkdir -p で作成した directory は rmdir で対称 cleanup する (probe file 単独削除は pollution 残留)

## 概要

健全性チェックや verification のために `mkdir -p` で一時 directory を作って probe file を置いた場合、cleanup 関数は probe file の `rm -f` だけでは不十分で、`rmdir` による親 directory の対称削除をセットにする必要がある。`rmdir` は directory が非空なら失敗するため、他ファイルが存在する場合は fail-safe に残る。対称性を欠くと workspace pollution が残留し、次回実行時に `.rite-lint-probe` 等の内部サフィックスを持つ空 directory が accumulate する silent failure になる。

## 詳細

### PR #585 の実例

`gitignore-health-check.sh` は `.rite/wiki/raw/.rite-lint-probe` を作成して `git check-ignore` / `git add --dry-run` で `.gitignore` ルールを verify する。初版は probe file の `rm -f` のみを cleanup 関数に登録していたが、`mkdir -p "$(dirname "$probe")"` で作成した親 directory (例: `.rite/wiki/raw/`) が実行後に空 directory として残留する経路があった。

複数 reviewer (HIGH x 2) が同時検出し、fix で `rmdir` による対称 cleanup を追加した:

```bash
probe_dir="$(dirname "$probe_file")"
_cleanup() {
  rm -f "$probe_file"
  # rmdir は非空なら fail するため fail-safe (他 raw source ファイルが同居している場合は残す)
  rmdir "$probe_dir" 2>/dev/null || true
}
trap _cleanup EXIT INT TERM HUP
```

### canonical rule

- `mkdir -p "$dir"` で作成した directory は **対称な `rmdir "$dir" 2>/dev/null || true`** を cleanup 関数に含めること
- `rmdir` の非空失敗は silent に許容する (`2>/dev/null || true`) — 他の正当なファイルが同居する場合の誤削除を防ぐ
- probe file の削除だけで cleanup を終える設計は review で必ず検出されるように symmetric pair check を習慣化する

### 適用範囲

| 状況 | 対称 cleanup |
|------|-------------|
| `mkdir -p` で作成 | `rmdir 2>/dev/null || true` |
| probe file 単独作成 (既存 directory に投入) | `rm -f` のみで OK (directory は作っていないため削除責務なし) |
| 一時 subdirectory を作って複数ファイル投入 | `rm -f` でファイル削除 → `rmdir` で directory 削除 (非空 fail-safe) |

### 検出方法

`mkdir -p` と `rm -f` の対を grep で照合:

```bash
grep -rn 'mkdir -p' plugins/rite/hooks/scripts/ \
  | while read -r line; do
      script=$(echo "$line" | cut -d: -f1)
      if ! grep -q 'rmdir' "$script"; then
        echo "MISSING rmdir cleanup: $script"
      fi
    done
```

## 関連ページ

- [trap 登録 → mktemp の順序で tempfile lifecycle を守る](trap-register-before-mktemp.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [PR #585 review results](../../raw/reviews/20260419T004413Z-pr-585.md)
- [PR #585 fix results](../../raw/fixes/20260419T004921Z-pr-585.md)
