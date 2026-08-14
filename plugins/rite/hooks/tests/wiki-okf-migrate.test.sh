#!/bin/bash
# wiki-okf-migrate.test.sh
#
# Tests for wiki-okf-migrate.sh (OKF v0.2 one-shot bundle migration).
#
# Coverage:
#   T-01  v0.1 fixture: ref→resource, updated→generated, okf_version, SCHEMA, log
#   T-05  書換え不能ページ → exit 1 + okf_version 非 bump + 再実行で完走
#   T-06  raw/** の source_ref はバイト単位で不変
#   T-08  okf_version: "0.2" は冪等 skip・ファイル不変
#   T-07  wiki-ingest SKILL.md は wiki.enabled=false 早期 return の後にだけ migrate を呼ぶ
#   T-10  plugins/rite 実装参照にページ frontmatter の sources[].ref / updated 読取りが残らない
#         （本ファイルでは helper 自身と呼び出し契約。残りは wiki-okf-v02-consumers.test.sh）
#
# Invocation / fail-fast:
#   TC-inv-1  --wiki-root 欠落 → exit 2
#   TC-inv-2  index.md 不在 → exit 1
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
SCRIPT="$PLUGIN_ROOT/hooks/scripts/wiki-okf-migrate.sh"

if [ ! -x "$SCRIPT" ]; then
  chmod +x "$SCRIPT" 2>/dev/null || true
fi
if [ ! -x "$SCRIPT" ]; then
  echo "ERROR: helper not executable: $SCRIPT" >&2
  exit 1
fi

cleanup_dirs=()
tmp_files=()
cleanup() {
  local p
  for p in "${cleanup_dirs[@]:-}"; do [ -n "$p" ] && rm -rf "$p"; done
  for p in "${tmp_files[@]:-}"; do [ -n "$p" ] && rm -f "$p"; done
}
trap cleanup EXIT

make_v01_bundle() {
  local root="$1"
  mkdir -p "$root/pages/heuristics" "$root/raw/reviews"
  cat > "$root/index.md" <<'EOF'
# Wiki Index

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
EOF
  cat > "$root/SCHEMA.md" <<'EOF'
# Wiki Schema -- 蓄積規約

このファイルは規約です。
EOF
  cat > "$root/log.md" <<'EOF'
# Directory Update Log

## 2026-01-01

* **init** — Wiki を初期化しました
EOF
  cat > "$root/pages/heuristics/example.md" <<'EOF'
---
type: "heuristics"
title: "Example"
domain: "heuristics"
description: "desc"
created: "2026-06-26T00:00:00+09:00"
updated: "2026-07-20T12:00:00+09:00"
sources:
  - type: "review"
    ref: "raw/reviews/20260720T000000Z.md"
tags: []
confidence: medium
---

# Example

body mentions ref: only in prose
EOF
  cat > "$root/pages/heuristics/legacy.md" <<'EOF'
---
type: "heuristics"
title: "Legacy"
updated: "2026-07-01T00:00:00Z"
sources:
- ref: "raw/reviews/legacy.md"
---
body
EOF
  printf '%s\n' '---' 'type: review' 'source_ref: "pr-1143"' 'ingested: false' '---' 'raw body' \
    > "$root/raw/reviews/20260720T000000Z.md"
}

echo "=== TC-inv-1: --wiki-root 欠落 ==="
outf=$(mktemp); tmp_files+=("$outf")
rc=0
bash "$SCRIPT" >"$outf" 2>&1 || rc=$?
assert "TC-inv-1 exit 2" "2" "${rc:-0}"
assert_grep "TC-inv-1 usage" "$outf" 'wiki-root は必須'

echo "=== TC-inv-2: index.md 不在 ==="
sbx=$(mktemp -d); cleanup_dirs+=("$sbx")
mkdir -p "$sbx/empty"
outf=$(mktemp); tmp_files+=("$outf")
rc=0
bash "$SCRIPT" --wiki-root "$sbx/empty" >"$outf" 2>&1 || rc=$?
assert "TC-inv-2 exit 1" "1" "$rc"
assert_grep "TC-inv-2 index missing" "$outf" 'index.md'

echo "=== T-01: v0.1 fixture 一括移行 ==="
sbx=$(mktemp -d); cleanup_dirs+=("$sbx")
make_v01_bundle "$sbx/wiki"
raw_before=$(cksum "$sbx/wiki/raw/reviews/20260720T000000Z.md")
outf=$(mktemp); tmp_files+=("$outf")
rc=0
bash "$SCRIPT" --wiki-root "$sbx/wiki" >"$outf" 2>&1 || rc=$?
assert "T-01 exit 0" "0" "$rc"
assert_grep "T-01 migrated marker" "$outf" 'WIKI_OKF_MIGRATE=migrated'
assert_grep "T-01 pages=2" "$outf" 'pages=2'
assert_grep "T-01 example resource" "$sbx/wiki/pages/heuristics/example.md" 'resource: "raw/reviews/20260720T000000Z.md"'
assert_not_grep "T-01 example に ref キーなし" "$sbx/wiki/pages/heuristics/example.md" '^[[:space:]]+ref:'
assert_grep "T-01 example generated.by unknown" "$sbx/wiki/pages/heuristics/example.md" 'rite-wiki-ingest/unknown'
assert_grep "T-01 example generated.at は旧 updated" "$sbx/wiki/pages/heuristics/example.md" '2026-07-20T12:00:00\+09:00'
assert_not_grep "T-01 example に updated キーなし" "$sbx/wiki/pages/heuristics/example.md" '^updated:'
assert_grep "T-01 created 維持" "$sbx/wiki/pages/heuristics/example.md" 'created: "2026-06-26T00:00:00\+09:00"'
assert_grep "T-01 legacy resource" "$sbx/wiki/pages/heuristics/legacy.md" 'resource: "raw/reviews/legacy.md"'
assert_grep "T-01 okf_version" "$sbx/wiki/index.md" 'okf_version: "0.2"'
assert_grep "T-01 SCHEMA type" "$sbx/wiki/SCHEMA.md" 'type: Reference'
assert_grep "T-01 log 記録" "$sbx/wiki/log.md" 'OKF v0.2'
assert "T-01 raw 不変" "$raw_before" "$(cksum "$sbx/wiki/raw/reviews/20260720T000000Z.md")"

echo "=== T-06: raw source_ref 非汚染 ==="
# covered by T-01 cksum; also assert the field text
assert_grep "T-06 source_ref 残存" "$sbx/wiki/raw/reviews/20260720T000000Z.md" 'source_ref: "pr-1143"'

echo "=== T-08: 既移行 bundle の冪等 skip ==="
before=$(find "$sbx/wiki" -type f -exec cksum {} \; | LC_ALL=C sort)
outf=$(mktemp); tmp_files+=("$outf")
rc=0
bash "$SCRIPT" --wiki-root "$sbx/wiki" >"$outf" 2>&1 || rc=$?
after=$(find "$sbx/wiki" -type f -exec cksum {} \; | LC_ALL=C sort)
assert "T-08 exit 0" "0" "$rc"
assert_grep "T-08 skipped marker" "$outf" 'already_v0.2'
assert "T-08 ファイル不変" "$before" "$after"

echo "=== T-05: 書換え不能ページは fail-loud + 再実行完走 ==="
sbx=$(mktemp -d); cleanup_dirs+=("$sbx")
make_v01_bundle "$sbx/wiki"
chmod a-w "$sbx/wiki/pages/heuristics/legacy.md"
rc=0
out=$(bash "$SCRIPT" --wiki-root "$sbx/wiki" 2>&1) || rc=$?
assert "T-05 初回 exit 1" "1" "$rc"
assert_not_grep "T-05 okf_version 非 bump" "$sbx/wiki/index.md" 'okf_version: "0.2"'
chmod u+w "$sbx/wiki/pages/heuristics/legacy.md"
rc=0
out=$(bash "$SCRIPT" --wiki-root "$sbx/wiki" 2>&1) || rc=$?
assert "T-05 再実行 exit 0" "0" "$rc"
assert_grep "T-05 再実行で version bump" "$sbx/wiki/index.md" 'okf_version: "0.2"'
assert_grep "T-05 再実行で resource" "$sbx/wiki/pages/heuristics/legacy.md" 'resource:'

echo "=== T-07: wiki-ingest は enabled=false 早期 return の後にだけ migrate を呼ぶ ==="
ingest="$PLUGIN_ROOT/skills/wiki-ingest/SKILL.md"
assert_file_exists_or_fail "T-07 ingest SKILL 存在" "$ingest"
# enabled=false 早期 return が migrate 呼び出しより前にあること
false_line=$(grep -n 'wiki_enabled=false' "$ingest" | head -1 | cut -d: -f1)
migrate_line=$(grep -n 'wiki-okf-migrate.sh' "$ingest" | head -1 | cut -d: -f1)
assert "T-07 false 早期 return 行がある" "1" "$([ -n "$false_line" ] && echo 1 || echo 0)"
assert "T-07 migrate 呼び出し行がある" "1" "$([ -n "$migrate_line" ] && echo 1 || echo 0)"
if [ -n "$false_line" ] && [ -n "$migrate_line" ]; then
  if [ "$false_line" -lt "$migrate_line" ]; then
    pass "T-07 migrate は enabled=false 早期 return より後"
  else
    fail "T-07 migrate が enabled=false 早期 return より前 (false=$false_line migrate=$migrate_line)"
  fi
fi

echo "=== T-10: consumer 実装が page frontmatter の旧キーを読まない ==="
# migrate helper / その fixture / wiki-promotions（ページ実体）は旧キーを書いてよい。
# 読取り実装（hooks の awk/sed）に `^updated:` や sources[].ref 抽出が残っていないこと。
consumer_hits=$(grep -RIn --exclude='wiki-okf-migrate.sh' --exclude='wiki-okf-migrate.test.sh' \
  -e 'sources\[\]\.ref' \
  -e '/^updated:' \
  "$PLUGIN_ROOT/hooks" "$PLUGIN_ROOT/skills" "$PLUGIN_ROOT/templates" 2>/dev/null \
  | grep -v '/wiki-promotions/' || true)
if [ -z "$consumer_hits" ]; then
  pass "T-10 旧キー読取り実装なし"
else
  fail "T-10 旧キー読取りが残っている"
  printf '%s\n' "$consumer_hits"
fi

print_summary "$(basename "$0")" "wiki-okf-migrate.sh の冪等・fail-loud・raw 非汚染契約を崩すと AC-3/5/6/7/8 が回帰する"
