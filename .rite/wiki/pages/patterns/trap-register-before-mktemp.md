---
title: "trap 登録 → mktemp の順序で tempfile lifecycle を守る"
domain: "patterns"
created: "2026-04-16T19:37:16Z"
updated: "2026-04-16T19:37:16Z"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260415T124218Z-pr-529-cycle-3-fix.md"
  - type: "fixes"
    ref: "raw/fixes/20260416T165559Z-pr-548.md"
  - type: "fixes"
    ref: "raw/fixes/20260416T180658Z-pr-548.md"
  - type: "reviews"
    ref: "raw/reviews/20260416T180001Z-pr-548.md"
tags: ["bash", "tempfile", "trap", "cleanup", "lifecycle"]
confidence: high
---

# trap 登録 → mktemp の順序で tempfile lifecycle を守る

## 概要

`mktemp` で tempfile を作った直後に `trap 'rm -f "$f"' EXIT ...` を登録するのでは、signal (INT/TERM/HUP) が `mktemp` 成功直後〜`trap` 登録前の窓で届いた場合に orphan tempfile が残る。canonical 順序は「空文字で変数宣言 → signal-specific trap 登録 → `mktemp` で値代入」。逆順は `mktemp → trap` race と呼ばれ、cycle 4 の PR #548 で複数箇所で検出された。

## 詳細

### Anti-pattern (mktemp → trap race)

```bash
# ❌ NG: mktemp と trap の間で INT が届くと orphan
f=$(mktemp /tmp/rite-XXXXXX) || f=""
trap 'rm -f "${f:-}"' EXIT INT TERM HUP
```

### Canonical pattern (path-declare → trap → mktemp)

```bash
# ✅ OK: trap が先、mktemp が後
f=""                                        # 1. 空文字で変数宣言
trap 'rm -f "${f:-}"' EXIT INT TERM HUP     # 2. trap install ("${f:-}" で空時も安全)
f=$(mktemp /tmp/rite-XXXXXX) || f=""        # 3. mktemp で値代入
# ...
rm -f "$f"                                  # 4. 明示 cleanup
trap - EXIT INT TERM HUP                    # 5. trap disarm（success path）
```

### Signal-specific handler で POSIX exit code を保持

signal 経由の中断で `$?` を 0 に畳まないために signal 別 handler を登録する:

```bash
_cleanup_body() { rm -f "${f:-}"; }
trap '_cleanup_body' EXIT
trap '_cleanup_body; exit 130' INT   # SIGINT
trap '_cleanup_body; exit 143' TERM  # SIGTERM
trap '_cleanup_body; exit 129' HUP   # SIGHUP
```

POSIX exit code 慣習: `128 + signal number` (INT=2, TERM=15, HUP=1)。この明示渡しをしないと caller 側が中断と通常失敗を区別できない。

### scope 限定 mini-trap

script 上部で trap 前に作られる tempfile（例: `ref_err` のような `git rev-parse` stderr 退避）は、メイン cleanup 関数とは別の scope 限定 mini-trap を書く:

```bash
# fm_err / ref_err / stage_dir 退避用 tempfile 作成箇所
ref_err=""
trap 'rm -f "${ref_err:-}"' EXIT INT TERM HUP
ref_err=$(mktemp /tmp/rite-ref-err-XXXXXX 2>/dev/null) || ref_err=""
# ... git コマンドで使用 ...
[ -n "$ref_err" ] && rm -f "$ref_err"
trap - EXIT INT TERM HUP
```

### `trap -` の最小化

`trap - EXIT INT TERM HUP` は**他の** trap も無効化する副作用を持つ。tempfile 削除直後に `var=""` で空文字代入して cleanup を no-op 化してから `trap -` を呼ぶか、そもそも signal 別 handler の重複を避ける設計にする。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](anti-patterns/asymmetric-fix-transcription.md)
- [mktemp 失敗は silent 握り潰さず WARNING を可視化する](patterns/mktemp-failure-surface-warning.md)

## ソース

- [PR #529 cycle 3 fix (tempfile lifecycle 契約)](raw/fixes/20260415T124218Z-pr-529-cycle-3-fix.md)
- [PR #548 cycle 1 fix (trap action リセット最小化)](raw/fixes/20260416T165559Z-pr-548.md)
- [PR #548 cycle 4 fix (mktemp → trap race の複数箇所修正)](raw/fixes/20260416T180658Z-pr-548.md)
- [PR #548 cycle 4 review (wiki-ingest-commit.sh worktree fast path で race 残存検出)](raw/reviews/20260416T180001Z-pr-548.md)
