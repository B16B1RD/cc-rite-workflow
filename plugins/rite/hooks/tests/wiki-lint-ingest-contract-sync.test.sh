#!/bin/bash
# wiki-lint-ingest-contract-sync.test.sh
#
# `skills/wiki-lint/SKILL.md` (producer) と `skills/wiki-ingest/SKILL.md` (consumer) の
# `--auto` モード sentinel 出力契約 (n 行構造) が同期していることを assert する meta-test。
#
# 背景 — Asymmetric Fix Transcription anti-pattern:
#   producer (lint.md ステップ 9.2 / 1.1 / 1.3) の出力行数を「3 行出力」へ拡張した際、
#   consumer (ingest.md ステップ 8.2) の参照宣言が「2 行出力」のまま残る drift は自動検出経路が
#   無く人手レビューに依存していた。同型 drift の再発を構造的に予防するため、
#   producer 側の line-count 宣言と consumer 側の参照宣言を行数で照合する。
#
# 検出する drift:
#   (a) lint.md が「N 行出力」と宣言しているのに ingest.md が異なる行数を仮定している
#   (b) lint.md / ingest.md のどちらか一方で line-count 記述が壊れた / 削除された
#
# 検出しない drift (本 test の scope 外、他 hook が担当):
#   - sentinel literal (`[lint:returned-to-caller:auto]`) の rename 漏れ → CHANGELOG + grep で別途検出
#   - disambiguator marker の adjacency 違反 → create-md-invocation-symmetry.test.sh TC-7 で別途検出
#   - HTML コメント形式 / bare bracket 形式の混在 → 別 test で対応
#
# When this test fails:
#   lint.md と ingest.md のいずれかが片方に追従していない可能性が高い。両ファイルの
#   sentinel 出力契約セクション (lint.md ステップ 9.2 / ingest.md ステップ 8.2) を確認し、
#   行数記述を同期させる。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
LINT_MD="$PLUGIN_ROOT/skills/wiki-lint/SKILL.md"
INGEST_MD="$PLUGIN_ROOT/skills/wiki-ingest/SKILL.md"

if [ ! -f "$LINT_MD" ]; then
  echo "ERROR: $LINT_MD not found" >&2
  exit 1
fi
if [ ! -f "$INGEST_MD" ]; then
  echo "ERROR: $INGEST_MD not found" >&2
  exit 1
fi

# ──────────────────────────────────────────────────────────────────────
# TC-1: lint.md 側の line-count 宣言が抽出可能
# ──────────────────────────────────────────────────────────────────────
# lint.md ステップ 9.2 が `stdout は次の N 行 (...)` または `stdout は次の N 行を出力する`
# 形式で出力契約を **declarative に宣言** する SoT 行。本 test はこの SoT 行のみを assert する。
# 早期 return path (ステップ 1.1 / 1.3) は SoT に従って 3 行 echo を実行するが、行数を
# declarative に宣言する記述ではなく `# ステップ 9.2 contract: ...3 行を出力` の inline コメント
# のみで参照する形のため、本 regex (`stdout は次の N 行`) はマッチせず assert 対象外。
# 最初に出現した N を採用する (SoT は ステップ 9.2 の 1 site のみのため head -1 で十分)。
lint_n=$(grep -oE 'stdout は次の [0-9]+ 行' "$LINT_MD" 2>/dev/null \
  | head -1 \
  | grep -oE '[0-9]+' \
  || true)

if [ -n "$lint_n" ]; then
  pass "TC-1 lint.md から line-count 宣言を抽出: $lint_n 行"
else
  fail "TC-1 lint.md から 'stdout は次の N 行' パターンが見つかりません (drift suspected: lint.md ステップ 9.2 の declarative 出力契約宣言が削除/破損された可能性。ステップ 1.1 / 1.3 早期 return path は ステップ 9.2 contract を参照するのみで本 regex の検出対象外)"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-1b: lint.md 側の declarative 宣言 site 数が単一であることを assert
# ──────────────────────────────────────────────────────────────────────
# TC-1 は `head -1` で最初の出現のみを採用する設計のため、lint.md に 2 site 目の
# declarative 宣言が誤って追加された場合 (例: ステップ 9.2 を修正中に ステップ 1.1 / 1.3 の
# 早期 return path も declarative 形式に書き換え、各 path で異なる行数を宣言したケース)、
# TC-1 はその drift を検出できず最初の site のみ assert する silent gap が生じる。
# 本 TC-1b は `grep -c = 1` で SoT 出現件数を機械検証し、複数 site 化を早期検出する。
lint_n_count=$(grep -cE 'stdout は次の [0-9]+ 行' "$LINT_MD" 2>/dev/null || true)

if [ "$lint_n_count" = "1" ]; then
  pass "TC-1b lint.md の declarative 宣言 site 数が単一 ($lint_n_count 件)"
else
  fail "TC-1b SoT site count != 1 (count=$lint_n_count)。count=0 は ステップ 9.2 の declarative 宣言行の削除/破損、count>=2 は複数 site 化を示します。後者の場合 TC-1 が最初の 1 site のみ assert する silent drift リスクが生じます (ステップ 9.2 を SoT として保ち、ステップ 1.1 / 1.3 早期 return path は inline コメントで contract を参照するのみに留めてください)"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-2: ingest.md 側の consumer spec 参照が抽出可能
# ──────────────────────────────────────────────────────────────────────
# ingest.md ステップ 8.2 は `HTML コメント sentinel の N 行を出力する` 形式で
# producer 側の出力行数を参照宣言する (consumer spec)。
ingest_n=$(grep -oE 'HTML コメント sentinel の [0-9]+ 行を出力する' "$INGEST_MD" 2>/dev/null \
  | head -1 \
  | grep -oE '[0-9]+' \
  || true)

if [ -n "$ingest_n" ]; then
  pass "TC-2 ingest.md から consumer spec の line-count 参照を抽出: $ingest_n 行"
else
  fail "TC-2 ingest.md から 'HTML コメント sentinel の N 行を出力する' パターンが見つかりません (drift suspected: ingest.md ステップ 8.2 の consumer spec 宣言が削除/破損された可能性)"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-3: lint.md と ingest.md の line-count が一致 (Asymmetric Fix Transcription 検出)
# ──────────────────────────────────────────────────────────────────────
# 両者の数値が一致しない場合、producer / consumer の一方が他方に追従していない drift。
# Asymmetric Fix Transcription drift を機械的に検出する。
if [ -n "$lint_n" ] && [ -n "$ingest_n" ]; then
  if [ "$lint_n" = "$ingest_n" ]; then
    pass "TC-3 lint.md ($lint_n 行) と ingest.md ($ingest_n 行) の line-count contract が一致"
  else
    fail "TC-3 contract drift: lint.md=$lint_n 行 / ingest.md=$ingest_n 行 (Asymmetric Fix Transcription suspected)"
  fi
else
  # TC-1 / TC-2 のいずれかが既に fail しているため、TC-3 は skip (重複 fail を避ける)
  skip "TC-3 skipped (TC-1 または TC-2 の抽出失敗のため比較不能)"
fi

if ! print_summary "wiki-lint-ingest-contract-sync.test.sh" "drift hint: lint.md ステップ 9.2 (declarative 宣言行) と ingest.md ステップ 8.2 の line-count 宣言を同期させてください (本 test は ステップ 9.2 の SoT 行のみを assert。ステップ 1.1 / 1.3 早期 return path は ステップ 9.2 contract を参照するのみで本 test の対象外)"; then
  exit 1
fi
