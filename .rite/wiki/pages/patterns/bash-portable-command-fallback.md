---
title: "cross-platform bash コマンドは fallback chain で portable 化する"
domain: "patterns"
created: "2026-04-17T04:30:00+00:00"
updated: "2026-04-17T04:30:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260417T035556Z-pr-559.md"
tags: []
confidence: high
---

# cross-platform bash コマンドは fallback chain で portable 化する

## 概要

Linux coreutils と macOS BSD userland でコマンド可用性が異なる bash ユーティリティ (sha1sum / readlink -f / date -Iseconds 等) は、`command -v` による存在確認を連鎖させた fallback chain で portable 化する。`rite-config.yml` で `language: auto` / multi-platform を想定する plugin では、単一コマンド直書きは silent "command not found" regression の発生源になる。

## 詳細

### PR #559 の実例

旧実装は `printf '%s' "..." | sha1sum | awk '{print $1}'` を直書きしていた。macOS では `sha1sum` がデフォルトインストールされておらず、`shasum` (Perl script 同梱) が慣例。この状態で実行すると `command not found: sha1sum` で silent skip に落ちていた。

### canonical fallback pattern

```bash
sha1_portable() {
  if command -v sha1sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha1sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 1 | awk '{print $1}'
  else
    printf '%s' "$1" | python3 -c 'import hashlib,sys; print(hashlib.sha1(sys.stdin.buffer.read()).hexdigest())'
  fi
}
```

### 3 段 fallback の設計理由

| 優先度 | コマンド | 代表環境 | 選好理由 |
|--------|----------|----------|----------|
| 1 | `sha1sum` | Linux (coreutils) | GNU 標準、最速 |
| 2 | `shasum -a 1` | macOS (Perl 同梱) | プリインストール、外部依存なし |
| 3 | `python3 -m hashlib` | 最終防衛 | 両 OS で Python 3 が標準的に存在 |

### 他の要 portable 化ユーティリティ

類似パターンで fallback が必要なコマンド:

| コマンド | Linux | macOS | Fallback |
|---------|-------|-------|----------|
| `sha1sum` | ✅ | ❌ | `shasum -a 1` / `python3 hashlib` |
| `md5sum` | ✅ | ❌ | `md5 -q` / `python3 hashlib` |
| `readlink -f` | ✅ | ❌ (`realpath` 相当) | `cd "$(dirname)" && pwd && basename` |
| `date -Iseconds` | ✅ | ❌ | `date +'%Y-%m-%dT%H:%M:%S%z'` |
| `stat -c '%Y'` | ✅ | ❌ (`-f '%m'`) | GNU/BSD 両対応は困難、`find -printf` 等で代替 |

### 検出方法

- プラグイン全体を `grep -rn 'sha1sum\|md5sum\|readlink -f\|date -Iseconds'` で走査し、裸呼び出しを検出
- CI で macOS runner を最低限 smoke test に含める

## 関連ページ

- [jq -n create mode: 既存値を読み取ってから再構築する](jq-create-mode-preserve-existing.md)

## ソース

- [PR #559 review results](../../raw/reviews/20260417T035556Z-pr-559.md)
