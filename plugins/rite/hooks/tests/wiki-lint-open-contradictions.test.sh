#!/bin/bash
# wiki-lint-open-contradictions.test.sh
#
# Tests for wiki-lint-open-contradictions.sh (open contradiction set read from the
# latest lint entry of the committed log.md) and for the skill wiring that calls it.
#
# Coverage:
#   TC-1  same_branch: latest entry's open lines only (older section and the
#         non-lint bullet after it are not mixed in, comparison sub-bullets ignored)
#   TC-2  same date, warning then clean → the later clean wins (0 open)
#   TC-3  same date, clean then warning → the later warning wins
#   TC-4  newest date section has no lint bullet → the previous section's entry
#   TC-5  no lint entry at all → 0 open
#   TC-6  entry without the fixed-format lines and contradictions=0 (legacy sub-bullets) → 0 open
#   TC-7  entry without the fixed-format lines and contradictions>0 → exit 1, no marker block
#   TC-8  malformed open line → exit 1, no marker block
#   TC-9  contradictions=N disagrees with the number of open lines → exit 1, no marker block
#   TC-10 same_branch reads HEAD, not an uncommitted log.md
#   TC-11 separate_branch reads the wiki branch, not the working tree log.md
#   TC-12 log.md absent from the ref → exit 1
#   TC-13 placeholder residue (--branch-strategy / --wiki-branch) → exit 1, no marker block
#   TC-14 unknown branch_strategy → exit 1
#   TC-15 invocation errors → exit 2
#   TC-16 round trip: the format example written by wiki-lint SKILL.md parses
#   TC-17 static pins: wiki-lint 3.1 and wiki-ingest 8.3.r call the helper and stop on failure
#   TC-18 round trip: a line rebuilt from the helper output reads back unchanged (reason kept)
#   TC-19 a non-result lint bullet after the result bullet → the result bullet is read
#   TC-20 only older-format lint bullets without contradictions= → no record, 0 open
#   TC-21 an open line under a result bullet whose heading lost ` — ` → exit 1, no marker block
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
SCRIPT="$PLUGIN_ROOT/hooks/scripts/wiki-lint-open-contradictions.sh"
LINT_MD="$PLUGIN_ROOT/skills/wiki-lint/SKILL.md"
INGEST_MD="$PLUGIN_ROOT/skills/wiki-ingest/SKILL.md"

if [ ! -x "$SCRIPT" ]; then
  echo "ERROR: helper not executable: $SCRIPT" >&2
  exit 1
fi

TEST_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ FAIL: $1"; }

OPEN_AB='  * 未解消の矛盾: [a](pages/heuristics/a.md) ↔ [b](pages/anti-patterns/b.md) — 方針逆転: a は X を勧め b は X を避ける'
OPEN_CD='  * 未解消の矛盾: [c](pages/patterns/c.md) ↔ [d](pages/patterns/d.md) — 重複情報: 同じ結論を 2 ページが持つ'
OPEN_OLD='  * 未解消の矛盾: [e](pages/patterns/e.md) ↔ [f](pages/patterns/f.md) — タイトル衝突: 古い記録'

# Create a same_branch repo whose HEAD commit holds .rite/wiki/log.md = $2.
make_same_repo() {
  local name="$1" log="$2"
  local repo="$TEST_DIR/$name"
  mkdir -p "$repo/.rite/wiki"
  (
    cd "$repo" || exit 1
    git init -q -b main .
    git config user.email "test@example.com"
    git config user.name "Test"
    printf '%s\n' "$log" > .rite/wiki/log.md
    git add .rite/wiki/log.md && git commit -qm "wiki log"
  )
  echo "$repo"
}

run_helper() {
  local repo="$1"; shift
  local rc=0
  HELPER_STDOUT=$( (cd "$repo" && _timeout 10 bash "$SCRIPT" --repo-root "$repo" "$@") 2>"$TEST_DIR/helper_stderr" ) || rc=$?
  HELPER_RC=$rc
  HELPER_STDERR=$(cat "$TEST_DIR/helper_stderr")
  return 0
}

expect_block() {
  local label="$1" expected="$2"
  if [ "$HELPER_RC" = "0" ] && [ "$HELPER_STDOUT" = "$expected" ]; then
    pass "$label"
  else
    fail "$label (rc=$HELPER_RC): stdout=$HELPER_STDOUT / stderr=$HELPER_STDERR"
  fi
}

expect_stop() {
  local label="$1" rc="$2" stderr_pattern="$3"
  if [ "$HELPER_RC" = "$rc" ] && ! grep -q 'open_contradictions_begin' <<<"$HELPER_STDOUT" \
     && grep -q -- "$stderr_pattern" <<<"$HELPER_STDERR"; then
    pass "$label"
  else
    fail "$label (rc=$HELPER_RC): stdout=$HELPER_STDOUT / stderr=$HELPER_STDERR"
  fi
}

EMPTY_BLOCK='---open_contradictions_begin---
---open_contradictions_end---
n_open=0'

echo "=== wiki-lint-open-contradictions.sh tests ==="

echo "TC-1: latest entry only"
repo=$(make_same_repo tc1 "# Directory Update Log

## 2026-10-11

* **Create**: [x](pages/patterns/x.md) — レビュー結果を新規ページ化
* **lint:warning** — contradictions=2, stale=0, orphans=0, missing_concept=0, unregistered_raw=0, broken_refs=0
  * 比較: [a](pages/heuristics/a.md) ↔ [b](pages/anti-patterns/b.md) — 矛盾。方針逆転
$OPEN_AB
  * 除外: 論点が異なる組
$OPEN_CD
* **Update**: [y](pages/patterns/y.md) — fix 結果を統合
$OPEN_OLD

## 2026-10-10

* **lint:warning** — contradictions=1, stale=0, orphans=0, missing_concept=0, unregistered_raw=0, broken_refs=0
$OPEN_OLD")
run_helper "$repo" --branch-strategy same_branch
expect_block "2 open lines of the latest entry, in order" '---open_contradictions_begin---
.rite/wiki/pages/heuristics/a.md|.rite/wiki/pages/anti-patterns/b.md|方針逆転|a は X を勧め b は X を避ける
.rite/wiki/pages/patterns/c.md|.rite/wiki/pages/patterns/d.md|重複情報|同じ結論を 2 ページが持つ
---open_contradictions_end---
n_open=2'

echo "TC-2: same date, warning then clean"
repo=$(make_same_repo tc2 "# Directory Update Log

## 2026-10-11

* **lint:warning** — contradictions=1, stale=0, orphans=0, missing_concept=0, unregistered_raw=0, broken_refs=0
$OPEN_AB
* **lint:clean** — contradictions=0, stale=0, orphans=0, missing_concept=0, unregistered_raw=0, broken_refs=0")
run_helper "$repo" --branch-strategy same_branch
expect_block "later clean entry wins" "$EMPTY_BLOCK"

echo "TC-3: same date, clean then warning"
repo=$(make_same_repo tc3 "# Directory Update Log

## 2026-10-11

* **lint:clean** — contradictions=0, stale=0, orphans=0, missing_concept=0, unregistered_raw=0, broken_refs=0
* **lint:warning** — contradictions=1, stale=0, orphans=0, missing_concept=0, unregistered_raw=0, broken_refs=0
$OPEN_CD")
run_helper "$repo" --branch-strategy same_branch
expect_block "later warning entry wins" '---open_contradictions_begin---
.rite/wiki/pages/patterns/c.md|.rite/wiki/pages/patterns/d.md|重複情報|同じ結論を 2 ページが持つ
---open_contradictions_end---
n_open=1'

echo "TC-4: newest section without lint bullet"
repo=$(make_same_repo tc4 "# Directory Update Log

## 2026-10-12

* **Skip**: [r](raw/reviews/r.md) — 新しい経験則なし

## 2026-10-11

* **lint:warning** — contradictions=1, stale=0, orphans=0, missing_concept=0, unregistered_raw=0, broken_refs=0
$OPEN_AB")
run_helper "$repo" --branch-strategy same_branch
expect_block "previous section's entry is used" '---open_contradictions_begin---
.rite/wiki/pages/heuristics/a.md|.rite/wiki/pages/anti-patterns/b.md|方針逆転|a は X を勧め b は X を避ける
---open_contradictions_end---
n_open=1'

echo "TC-5: no lint entry"
repo=$(make_same_repo tc5 "# Directory Update Log

## 2026-10-11

* **init** — Wiki を初期化しました")
run_helper "$repo" --branch-strategy same_branch
expect_block "0 open" "$EMPTY_BLOCK"

echo "TC-6: legacy entry with contradictions=0"
repo=$(make_same_repo tc6 "# Directory Update Log

## 2026-10-11

* **lint:clean** — contradictions=0, stale=0, orphans=0, missing_concept=0, unregistered_raw=0, broken_refs=0
  - WIKI_CONTRADICTION_CHECK=complete; changed=1; screened=1; candidates=1; excluded=0; compared=1
  - page_a=\`.rite/wiki/pages/patterns/c.md\`; page_b=\`.rite/wiki/pages/patterns/d.md\`; decision=compared; reason=矛盾なし")
run_helper "$repo" --branch-strategy same_branch
expect_block "legacy sub-bullets read as 0 open" "$EMPTY_BLOCK"

echo "TC-7: legacy entry with contradictions>0"
repo=$(make_same_repo tc7 "# Directory Update Log

## 2026-10-11

* **lint:warning** — contradictions=3, stale=0, orphans=0, missing_concept=0, unregistered_raw=0, broken_refs=0
  * 比較: [a](pages/heuristics/a.md) ↔ [b](pages/anti-patterns/b.md) — 矛盾。方針逆転")
run_helper "$repo" --branch-strategy same_branch
expect_stop "count mismatch stops and asks for a manual lint" 1 'wiki-lint（--auto なし）'

echo "TC-8: malformed open line"
repo=$(make_same_repo tc8 "# Directory Update Log

## 2026-10-11

* **lint:warning** — contradictions=1, stale=0, orphans=0, missing_concept=0, unregistered_raw=0, broken_refs=0
  * 未解消の矛盾: [a](pages/heuristics/a.md) ↔ [b](pages/anti-patterns/b.md) — 見かけの対立: 分類が規定外")
run_helper "$repo" --branch-strategy same_branch
expect_stop "unknown subcategory is rejected" 1 '固定書式に一致しません'

echo "TC-9: count mismatch"
repo=$(make_same_repo tc9 "# Directory Update Log

## 2026-10-11

* **lint:warning** — contradictions=2, stale=0, orphans=0, missing_concept=0, unregistered_raw=0, broken_refs=0
$OPEN_AB")
run_helper "$repo" --branch-strategy same_branch
expect_stop "contradictions=2 with 1 line stops" 1 'contradictions=2 と未解消の矛盾の行数 1'

echo "TC-10: same_branch ignores uncommitted log.md"
repo=$(make_same_repo tc10 "# Directory Update Log

## 2026-10-11

* **lint:clean** — contradictions=0, stale=0, orphans=0, missing_concept=0, unregistered_raw=0, broken_refs=0")
printf '%s\n' "# Directory Update Log" "" "## 2026-10-11" "" \
  "* **lint:warning** — contradictions=1, stale=0, orphans=0, missing_concept=0, unregistered_raw=0, broken_refs=0" \
  "$OPEN_AB" > "$repo/.rite/wiki/log.md"
run_helper "$repo" --branch-strategy same_branch
expect_block "HEAD content is used" "$EMPTY_BLOCK"

echo "TC-11: separate_branch reads the wiki branch"
repo="$TEST_DIR/tc11"
git init -q -b main "$repo"
(
  cd "$repo" || exit 1
  git config user.email "test@example.com"
  git config user.name "Test"
  echo base > base.txt
  git add base.txt && git commit -qm "init"
  git checkout -q --orphan wiki
  git rm -qrf . 2>/dev/null || true
  mkdir -p .rite/wiki
  printf '%s\n' "# Directory Update Log" "" "## 2026-10-11" "" \
    "* **lint:warning** — contradictions=1, stale=0, orphans=0, missing_concept=0, unregistered_raw=0, broken_refs=0" \
    "$OPEN_CD" > .rite/wiki/log.md
  git add .rite/wiki/log.md && git commit -qm "wiki log"
  git checkout -q main
  mkdir -p .rite/wiki
  printf '%s\n' "# Directory Update Log" "" "## 2026-10-11" "" \
    "* **lint:clean** — contradictions=0, stale=0, orphans=0, missing_concept=0, unregistered_raw=0, broken_refs=0" > .rite/wiki/log.md
)
run_helper "$repo" --branch-strategy separate_branch --wiki-branch wiki
expect_block "wiki branch content is used" '---open_contradictions_begin---
.rite/wiki/pages/patterns/c.md|.rite/wiki/pages/patterns/d.md|重複情報|同じ結論を 2 ページが持つ
---open_contradictions_end---
n_open=1'

echo "TC-12: log.md absent from the ref"
repo="$TEST_DIR/tc12"
git init -q -b main "$repo"
(cd "$repo" && git config user.email t@e && git config user.name T && git commit -q --allow-empty -m init)
run_helper "$repo" --branch-strategy same_branch
expect_stop "unreadable log.md stops" 1 'commit 済みの log.md を読めません'

echo "TC-13: placeholder residue"
repo=$(make_same_repo tc13 "# Directory Update Log")
run_helper "$repo" --branch-strategy "{branch_strategy}"
expect_stop "{branch_strategy} residue" 1 'placeholder'
run_helper "$repo" --branch-strategy separate_branch --wiki-branch "{wiki_branch}"
expect_stop "{wiki_branch} residue" 1 'placeholder'

echo "TC-14: unknown branch_strategy"
run_helper "$repo" --branch-strategy other_branch
expect_stop "unknown strategy" 1 '未知の branch_strategy'

echo "TC-15: invocation errors"
run_helper "$repo"
[ "$HELPER_RC" = "2" ] && pass "missing --branch-strategy → 2" || fail "missing --branch-strategy (rc=$HELPER_RC)"
run_helper "$repo" --branch-strategy separate_branch
[ "$HELPER_RC" = "2" ] && pass "separate_branch without --wiki-branch → 2" || fail "separate_branch without --wiki-branch (rc=$HELPER_RC)"

echo "TC-16: round trip with the wiki-lint SKILL.md format example"
example=$(grep -m 1 -E '^  \* 未解消の矛盾: \[' "$LINT_MD" || true)
if [ -z "$example" ]; then
  fail "format example line not found in wiki-lint SKILL.md"
else
  repo=$(make_same_repo tc16 "# Directory Update Log

## 2026-10-11

* **lint:warning** — contradictions=1, stale=0, orphans=0, missing_concept=0, unregistered_raw=0, broken_refs=0
$example")
  run_helper "$repo" --branch-strategy same_branch
  if [ "$HELPER_RC" = "0" ] && grep -q '^n_open=1$' <<<"$HELPER_STDOUT" \
     && [ "$(sed -n '2p' <<<"$HELPER_STDOUT" | grep -cE '^\.rite/wiki/pages/[a-z-]+/[^|]+\.md\|\.rite/wiki/pages/[a-z-]+/[^|]+\.md\|(タイトル衝突|方針逆転|重複情報)\|.+$')" = "1" ]; then
    pass "SKILL example is accepted by the helper"
  else
    fail "SKILL example rejected (rc=$HELPER_RC): stdout=$HELPER_STDOUT / stderr=$HELPER_STDERR"
  fi
fi

echo "TC-17: skill wiring"
# section bodies: from the heading to the next heading of the same or higher level
lint_31=$(awk '/^### 3\.1 /{f=1;print;next} f&&/^##+ /{exit} f' "$LINT_MD")
ingest_83r=$(awk '/^### 8\.3\.r /{f=1;print;next} f&&/^##+ /{exit} f' "$INGEST_MD")
if grep -q 'wiki-lint-open-contradictions.sh --branch-strategy "{branch_strategy}" --wiki-branch "{wiki_branch}"' <<<"$lint_31" \
   && grep -q 'reason=open_contradictions_unreadable' <<<"$lint_31"; then
  pass "wiki-lint 3.1 calls the helper and stops when it fails"
else
  fail "wiki-lint 3.1 wiring is missing"
fi
# the stop pins use literals only the helper-failure stop carries; the section's
# other stop sentences (comparison not finished, re-run failed) must not satisfy them
if grep -q 'wiki-lint-open-contradictions.sh --branch-strategy "{branch_strategy}" --wiki-branch "{wiki_branch}"' <<<"$ingest_83r" \
   && grep -q '1 回だけ' <<<"$ingest_83r" \
   && grep -q 'reason=open_contradictions_unreadable' <<<"$ingest_83r" \
   && grep -q '`n_open=` が 8.3 の `n_contradictions` と一致しない場合' <<<"$ingest_83r"; then
  pass "wiki-ingest 8.3.r calls the helper, re-runs lint once, and stops on helper failure or count mismatch"
else
  fail "wiki-ingest 8.3.r wiring is missing"
fi

echo "TC-18: round trip through the helper output"
# rebuild the 8.1 line from the helper output only and read it again: a carried
# pair must come back with the same pages, subcategory and reason
repo=$(make_same_repo tc18 "# Directory Update Log

## 2026-10-11

* **lint:warning** — contradictions=1, stale=0, orphans=0, missing_concept=0, unregistered_raw=0, broken_refs=0
  * 未解消の矛盾: [a](pages/heuristics/a.md) ↔ [b](pages/anti-patterns/b.md) — 方針逆転: a は X を勧め b は | X を避ける")
run_helper "$repo" --branch-strategy same_branch
first="$HELPER_STDOUT"
row=$(sed -n '2p' <<<"$first")
IFS='|' read -r page_a page_b subcategory reason <<<"$row"
rebuilt="  * 未解消の矛盾: [x](${page_a#.rite/wiki/}) ↔ [y](${page_b#.rite/wiki/}) — ${subcategory}: ${reason}"
printf '%s\n' "# Directory Update Log" "" "## 2026-10-12" "" \
  "* **lint:warning** — contradictions=1, stale=0, orphans=0, missing_concept=0, unregistered_raw=0, broken_refs=0" \
  "$rebuilt" > "$repo/.rite/wiki/log.md"
(cd "$repo" && git add .rite/wiki/log.md && git commit -qm "carried")
run_helper "$repo" --branch-strategy same_branch
if [ "$HELPER_RC" = "0" ] && [ "$HELPER_STDOUT" = "$first" ] && [ "$reason" = "a は X を勧め b は | X を避ける" ]; then
  pass "carried pair keeps pages, subcategory and reason"
else
  fail "round trip changed the pair (rc=$HELPER_RC): first=$first / second=$HELPER_STDOUT"
fi

echo "TC-19: a non-result lint bullet after the result bullet"
repo=$(make_same_repo tc19 "# Directory Update Log

## 2026-10-11

* **lint:warning** — contradictions=1, stale=0, orphans=0, missing_concept=0, unregistered_raw=0, broken_refs=0
$OPEN_CD
* **lint:scope** — 今回ページ変更なし。全ページのタイトル衝突なし")
run_helper "$repo" --branch-strategy same_branch
expect_block "the result bullet before it is read" '---open_contradictions_begin---
.rite/wiki/pages/patterns/c.md|.rite/wiki/pages/patterns/d.md|重複情報|同じ結論を 2 ページが持つ
---open_contradictions_end---
n_open=1'

echo "TC-20: only older-format lint bullets without contradictions="
repo=$(make_same_repo tc20 "# Directory Update Log

## 2026-10-11

* **lint:clean**: 矛盾 0 / 孤児 0 / 欠落 0")
run_helper "$repo" --branch-strategy same_branch
expect_block "no record, 0 open" "$EMPTY_BLOCK"

echo "TC-21: an open line under a result bullet whose heading lost the separator"
# Skipping the newest bullet would silently fall back to the older record and drop
# the open pair, so the read has to stop instead
repo=$(make_same_repo tc21 "# Directory Update Log

## 2026-10-12

* **lint:warning**: contradictions=1, stale=0, orphans=0, missing_concept=0, unregistered_raw=0, broken_refs=0
$OPEN_AB

## 2026-10-11

* **lint:clean** — contradictions=0, stale=0, orphans=0, missing_concept=0, unregistered_raw=0, broken_refs=0")
run_helper "$repo" --branch-strategy same_branch
expect_stop "open line under a non-result lint bullet stops" 1 '6 フィールドの結果行でない lint bullet の下に未解消の矛盾の行があります'

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
