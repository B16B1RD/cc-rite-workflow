#!/bin/bash
# Tests for plugins/rite/hooks/control-char-neutralize.sh
#
# Purpose:
#   neutralize_ctrl は flow-state.sh (_emit_jq_err_snippet) と
#   stop-loop-continuation.sh (unknown-prefix WARNING) が共有する
#   「制御文字 → ?」規約の single source of truth。glibc の [[:cntrl:]] が
#   分類しない C1 8-bit 制御バイト (0x80-0x9f、特に CSI introducer 0x9b) を
#   バイト単位で `?` 置換することを直接 pin する (jq / state file を介さない
#   単体層 — 統合層は flow-state.test.sh TC-23 / stop-loop-continuation.test.sh
#   TC-14 が担う)。
#
# Test cases:
#   TC-1: C0 制御文字 (0x01 / TAB / ESC) → ?
#   TC-2: DEL (0x7f) → ?
#   TC-3: C1 境界 (0x80 / 0x9b CSI / 0x9f) → ? (本丸 pin)
#   TC-4: 0xa0 (C1 上限 +1) は保持される (過剰置換しない上側境界 pin)
#   TC-5: UTF-8 U+009B (0xc2 0x9b) の 0x9b バイトが ? 化され生 0x9b が残らない
#   TC-6: default モード: \n も ? 化 (旧 ${var//[[:cntrl:]]/?} の 1 行化挙動と同じ)
#   TC-7: --keep-newline: \n は保持、他の制御文字は ? (旧 sed 行指向挙動と同じ)
#   TC-8: 可読 ASCII は無傷 + 1:1 置換 (削除ではない — 長さ保存)
#   TC-9: NUL バイト (0x00) → ? (LC_ALL=C tr のバイトストリーム性 pin)
#   TC-10: --c0-only: C0 (0x01 / TAB / ESC) + DEL → ?
#   TC-11: --c0-only: C1 境界 (0x80 / 0x9b / 0x9f) は素通し (default との差分 pin)
#   TC-12: --c0-only: UTF-8 マルチバイト (日本語) が無傷 (JSON フォールバック reason 保護の本丸 pin)
#   TC-13: --c0-only: \n も ? 化 (C0 範囲 — caller は改行を先にエスケープしてから呼ぶ契約)
#   TC-14: contains_ctrl: C0 (0x01 / TAB / \n / ESC) を検出
#   TC-15: contains_ctrl: DEL (0x7f) を検出
#   TC-16: contains_ctrl: C1 境界 (0x80 / 0x9b CSI / 0x9f) を検出 (本丸 pin —
#          旧 `=~ [[:cntrl:]]` は glibc が C1 を cntrl と分類しないため素通し)
#   TC-17: contains_ctrl: 0xa0 (C1 上限 +1) / printable ASCII は clean (過剰検出しない境界 pin)
#   TC-18: contains_ctrl: UTF-8 U+009B (0xc2 0x9b) を 2 バイト目で検出
#   TC-19: contains_ctrl: empty string は clean / UTF-8 マルチバイト (日本語) は検出
#          (byte-wise 設計判断 pin — 継続バイト 0x80-0x9f 重複は accepted trade-off)
#   TC-20: contains_ctrl --c0-only: C0+DEL のみ検出・C1/日本語は clean
#          (neutralize_ctrl --c0-only と同一範囲を共有する検出側モード。UTF-8 本文を
#           検査する call site 用。未知の第 2 引数は default 範囲へ倒す fail-closed も pin)
#
# Usage: bash plugins/rite/hooks/tests/control-char-neutralize.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
HELPER="$PLUGIN_ROOT/hooks/control-char-neutralize.sh"

if [ ! -f "$HELPER" ]; then
  echo "ERROR: $HELPER not found" >&2
  exit 1
fi
# shellcheck source=../control-char-neutralize.sh
source "$HELPER"

# stdout を hex 列へ (バイト単位比較用 — od のスペース/改行を除去)
to_hex() { od -An -tx1 | tr -d ' \n'; }

echo "=== TC-1: C0 制御文字 (0x01 / TAB / ESC) → ? ==="
assert "TC-1: C0 bytes neutralized" "A?B?C?D" "$(printf 'A\x01B\tC\x1bD' | neutralize_ctrl)"

echo ""
echo "=== TC-2: DEL (0x7f) → ? ==="
assert "TC-2: DEL neutralized" "A?B" "$(printf 'A\x7fB' | neutralize_ctrl)"

echo ""
echo "=== TC-3: C1 境界 (0x80 / 0x9b CSI / 0x9f) → ? ==="
# sed [[:cntrl:]] / bash ${var//[[:cntrl:]]/?} で実装するとこの 3 バイトを素通しする
# (glibc は C/UTF-8 両ロケールで C1 を cntrl と分類しないため)。その素通し経路を guard する。
assert "TC-3: C1 range boundaries neutralized" "A?B?C?D" "$(printf 'A\x80B\x9bC\x9fD' | neutralize_ctrl)"

echo ""
echo "=== TC-4: 0xa0 (C1 上限 +1) は保持 (過剰置換しない境界 pin) ==="
assert "TC-4: byte just above C1 preserved" "41a042" "$(printf 'A\xa0B' | neutralize_ctrl | to_hex)"

echo ""
echo "=== TC-5: UTF-8 U+009B (0xc2 0x9b) の 0x9b が ? 化される ==="
# valid UTF-8 の U+009B は jq の JSON 読み書きを素通りして call site まで届く
# 現実の攻撃バイト列 (xterm 等は UTF-8 モードでも C1 を制御文字として解釈する)。
# バイト単位置換は 2 バイト目の 0x9b を潰すため、出力に生 0x9b が残らない。
_tc5_hex=$(printf 'X\xc2\x9bY' | neutralize_ctrl | to_hex)
assert "TC-5: U+009B second byte neutralized (0xc2 remains, harmless)" "58c23f59" "$_tc5_hex"

echo ""
echo "=== TC-6: default モード — \\n も ? 化 (1 行 WARNING 埋め込み用) ==="
assert "TC-6: newline neutralized in default mode" "l1?l2" "$(printf 'l1\nl2' | neutralize_ctrl)"

echo ""
echo "=== TC-7: --keep-newline — \\n は保持、他は ? (行構造保持 snippet 用) ==="
assert "TC-7: newline preserved, others neutralized" "6c313f0a6c323f0a" "$(printf 'l1\x9b\nl2\x1b\n' | neutralize_ctrl --keep-newline | to_hex)"

echo ""
echo "=== TC-8: 可読 ASCII 無傷 + 1:1 置換 (長さ保存 — 空削除への revert を catch) ==="
assert "TC-8: printable ASCII untouched" "readable TEXT-123_ok" "$(printf 'readable TEXT-123_ok' | neutralize_ctrl)"
# `wc -c` right-justifies its count with leading spaces on BSD/macOS (GNU emits
# the bare number). `$( )` strips the trailing newline but not the leading pad,
# so strip whitespace before the string comparison .
assert "TC-8: 1:1 replacement preserves byte length" "3" "$(printf 'A\x9bB' | neutralize_ctrl | wc -c | tr -d ' ')"

echo ""
echo "=== TC-9: NUL バイト (0x00) → ? (バイトストリーム性 pin) ==="
assert "TC-9: NUL neutralized" "413f42" "$(printf 'A\x00B' | neutralize_ctrl | to_hex)"

echo ""
echo "=== TC-10: --c0-only — C0 (0x01 / TAB / ESC) + DEL → ? ==="
assert "TC-10: C0 bytes neutralized" "A?B?C?D?E" "$(printf 'A\x01B\tC\x1bD\x7fE' | neutralize_ctrl --c0-only)"

echo ""
echo "=== TC-11: --c0-only — C1 境界 (0x80 / 0x9b / 0x9f) は素通し (default との差分 pin) ==="
# RFC 8259 が JSON 文字列内で生バイトを禁じるのは C0 のみで、--c0-only は 0x80 以上に
# 触れない (default は ? 化する)。jq と対称なのは valid UTF-8 の C1 (0xc2 0x9b) のみ —
# 本 TC の raw 8-bit 単独 C1 は jq なら U+FFFD に置換されるため、素通しは --c0-only 固有。
assert "TC-11: C1 range preserved (hex)" "4180429b439f44" "$(printf 'A\x80B\x9bC\x9fD' | neutralize_ctrl --c0-only | to_hex)"

echo ""
echo "=== TC-12: --c0-only — UTF-8 マルチバイト (日本語) が無傷 (本丸 pin) ==="
# default モードは「停」(0xe5 0x81 0x9c) の継続バイト 0x81/0x9c を ? 化して本文を破壊する。
# --c0-only は 0x80 以上に触れないため、JSON フォールバック reason の日本語指示文が保持される。
assert "TC-12: Japanese text untouched" "停止せず継続" "$(printf '停止せず継続' | neutralize_ctrl --c0-only)"

echo ""
echo "=== TC-13: --c0-only — \\n も ? 化 (C0 範囲 — caller は改行を先にエスケープする契約) ==="
assert "TC-13: newline neutralized in c0-only mode" "l1?l2" "$(printf 'l1\nl2' | neutralize_ctrl --c0-only)"

# contains_ctrl の rc を assert 可能な文字列へ (rc 0 = detected / rc 1 = clean)
ctrl_verdict() { if contains_ctrl "$1"; then echo detected; else echo clean; fi; }

echo ""
echo "=== TC-14: contains_ctrl — C0 (0x01 / TAB / \\n / ESC) を検出 ==="
assert "TC-14: SOH (0x01) detected" "detected" "$(ctrl_verdict $'a\x01b')"
assert "TC-14: TAB detected" "detected" "$(ctrl_verdict $'a\tb')"
assert "TC-14: newline detected" "detected" "$(ctrl_verdict $'a\nb')"
assert "TC-14: ESC (0x1b) detected" "detected" "$(ctrl_verdict $'a\x1bb')"

echo ""
echo "=== TC-15: contains_ctrl — DEL (0x7f) を検出 ==="
assert "TC-15: DEL detected" "detected" "$(ctrl_verdict $'a\x7fb')"

echo ""
echo "=== TC-16: contains_ctrl — C1 境界 (0x80 / 0x9b CSI / 0x9f) を検出 (本丸) ==="
# 旧 `=~ [[:cntrl:]]` (flow-state.sh / wiki-ingest-trigger.sh の reject 経路) は
# glibc が C/UTF-8 両ロケールで C1 を cntrl と分類しないためこの 3 バイトを素通ししていた。
assert "TC-16: C1 lower bound (0x80) detected" "detected" "$(ctrl_verdict $'a\x80b')"
assert "TC-16: CSI introducer (0x9b) detected" "detected" "$(ctrl_verdict $'a\x9bb')"
assert "TC-16: C1 upper bound (0x9f) detected" "detected" "$(ctrl_verdict $'a\x9fb')"

echo ""
echo "=== TC-17: contains_ctrl — 0xa0 / printable ASCII は clean (過剰検出しない境界 pin) ==="
assert "TC-17: byte just above C1 (0xa0) clean" "clean" "$(ctrl_verdict $'a\xa0b')"
assert "TC-17: printable ASCII clean" "clean" "$(ctrl_verdict 'pr-123 TEXT_ok~')"

echo ""
echo "=== TC-18: contains_ctrl — UTF-8 U+009B (0xc2 0x9b) を 2 バイト目で検出 ==="
# valid UTF-8 の U+009B は jq / YAML パーサを素通りして call site まで届く現実の攻撃
# バイト列 (TC-5 と同じ脅威モデルの検出側 pin)。
assert "TC-18: U+009B detected via second byte" "detected" "$(ctrl_verdict $'x\xc2\x9by')"

echo ""
echo "=== TC-19: contains_ctrl — empty は clean / 日本語は検出 (byte-wise 設計判断 pin) ==="
assert "TC-19: empty string clean" "clean" "$(ctrl_verdict '')"
# UTF-8 継続バイト (0x80-0x9f 重複) の検出は accepted trade-off (設計判断)。
# この assert が fail し始めたら byte-wise 契約自体が変わったことを意味する。
assert "TC-19: multibyte (Japanese) detected via continuation bytes" "detected" "$(ctrl_verdict 'あ')"

echo ""
echo "=== TC-20: contains_ctrl --c0-only — 範囲は neutralize_ctrl --c0-only と同一 ==="
# UTF-8 本文 (日本語 title 等) を検査する call site 用モード。default 範囲との差分は
# C1 (0x80-0x9f) の扱いのみで、そこが継続バイトを巻き込む false positive の発生源。
# neutralize_ctrl --c0-only (TC-10〜13) と同じ範囲を共有していることを両側で pin する。
ctrl_verdict_c0() { if contains_ctrl "$1" --c0-only; then echo detected; else echo clean; fi; }
assert "TC-20: C0 (SOH) detected in --c0-only" "detected" "$(ctrl_verdict_c0 $'a\x01b')"
assert "TC-20: TAB detected in --c0-only" "detected" "$(ctrl_verdict_c0 $'a\tb')"
assert "TC-20: newline detected in --c0-only" "detected" "$(ctrl_verdict_c0 $'a\nb')"
assert "TC-20: DEL detected in --c0-only" "detected" "$(ctrl_verdict_c0 $'a\x7fb')"
# 本モードの存在意義: default が detected を返す日本語が clean になる (TC-19 と対の差分 pin)
assert "TC-20: multibyte (Japanese) clean in --c0-only" "clean" "$(ctrl_verdict_c0 'あ')"
assert "TC-20: C1 (0x9b CSI) clean in --c0-only" "clean" "$(ctrl_verdict_c0 $'a\x9bb')"
assert "TC-20: printable ASCII clean in --c0-only" "clean" "$(ctrl_verdict_c0 'a-b_c.d')"
assert "TC-20: empty string clean in --c0-only" "clean" "$(ctrl_verdict_c0 '')"
# 未知の第 2 引数は default 範囲へ倒す (typo を silent に緩い判定へ落とさない fail-closed 側)
assert "TC-20: unknown 2nd arg falls back to default range" "detected" "$(ctrl_verdict_c0_typo() { if contains_ctrl "$1" --c0only; then echo detected; else echo clean; fi; }; ctrl_verdict_c0_typo 'あ')"

if ! print_summary "$(basename "$0")" "control-char-neutralize.sh — C0+DEL+C1 byte-wise neutralization + detection shared helper"; then
  exit 1
fi
