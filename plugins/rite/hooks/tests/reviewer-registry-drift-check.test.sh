#!/bin/bash
# Tests for plugins/rite/hooks/scripts/reviewer-registry-drift-check.sh
# (reviewer registry 3-way sync detection). Covers the governing rationale acceptance
# criteria:
#   - T-01 (AC-1): adding a dummy reviewer agent file WITHOUT updating the
#     SKILL.md tables is detected as drift (single-check FAIL)
#   - T-03 (AC-1): a deliberate partial update (one table only) is detected
#   - T-05 (AC-2): the real repository's current registry passes (no drift)
#   - Invariant I1 reverse: a Type Identifiers row without an agent profile
#     (spawning a nonexistent subagent) is detected
#   - Invariant I3: slug/Agent cell mismatch is detected in isolation
#     (balanced swap keeps the sets intact so only I3 fires)
#   - Guard: heading change → undersized extraction → invocation error (rc=2),
#     with the extraction-guard message asserted so it isn't confused with I3's
#   - Guard: column insertion before Agent → I3 row-count guard → rc=2,
#     with the I3-guard message asserted so it isn't confused with the extraction guard
#   - Guard: missing registry directory/file (--repo-root outside the plugin
#     source tree, e.g. marketplace/consumer install) → clean skip (rc=0,
#     not applicable — the governing rationale)
#   - Arg contract: --all required; --repo-root requires a value (both rc=2)
#   - Extraction: in-section (not just out-of-section) non-pipe prose lines
#     inside Available Reviewers / Type Identifiers must not leak into the
#     token sets (kills a mutation that drops the `/^\|/` line filter)
#   - Cross-component contract: the `==> Total reviewer-registry-drift
#     findings: N` aggregate line (consumed by skills/lint/SKILL.md's
#     extraction regex) is asserted verbatim without --quiet
#   - Regression guard: a digit-bearing slug (web3) is correctly counted
#     across all 3 sync points, guarding against AGENT_RE reverting to a
#     digit-unaware pattern
#
# Portability note: fixture mutations use `awk` via the
# read→transform→write→mv pattern instead of `sed -i`. BSD sed (macOS)
# requires a mandatory backup suffix for `-i`, so GNU-style `sed -i '<expr>'`
# aborts the suite on macOS under `set -e`. The awk pattern is identical on
# GNU and BSD.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
CHECKER="$PLUGIN_ROOT/hooks/scripts/reviewer-registry-drift-check.sh"

if [ ! -f "$CHECKER" ]; then
  echo "ERROR: $CHECKER not found" >&2
  exit 1
fi

# sibling _test-helpers.sh consumers と同型の sandbox cleanup pattern。
cleanup_dirs=()
cleanup() {
  for d in "${cleanup_dirs[@]:-}"; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
}
trap 'rc=$?; cleanup; exit $rc' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

# awk read→transform→write→mv helper (BSD sed -i 非互換を避ける repo 規約)。
# 引数: <file> <awk-program>
awk_inplace() {
  local file="$1"
  local prog="$2"
  local tmp="${file}.tmp"
  awk "$prog" "$file" > "$tmp"
  mv "$tmp" "$file"
}

# 13 種のダミー reviewer slug（checker の >= 6 抽出ガードを満たす数）。
# web3 は数字入り slug : AGENT_RE が `[a-z][a-z-]*-reviewer[.]md` に
# 巻き戻った場合、この 1 件だけが 3 集合 + I3 行フィルタから静かに脱落する
# （TC-15 の回帰ガード対象）。
FIXTURE_SLUGS=(alpha bravo charlie delta echo-x foxtrot golf hotel india juliett kilo lima web3)

# Helper: create a sandbox holding a synchronized reviewer registry fixture
# (13 agent files + reviewers/SKILL.md with both tables in sync) and echo its
# repo root path. Callers push the path onto cleanup_dirs and then mutate the
# fixture to create the drift under test.
make_registry_sandbox() {
  local d
  d=$(make_plain_sandbox --soft) || return 1
  mkdir -p "$d/plugins/rite/agents" "$d/plugins/rite/skills/reviewers"

  local slug
  for slug in "${FIXTURE_SLUGS[@]}"; do
    printf '# %s reviewer fixture\n' "$slug" > "$d/plugins/rite/agents/${slug}-reviewer.md"
  done
  # 共有 principles ファイルは registry 対象外であることも fixture で表現する
  printf '# shared principles fixture\n' > "$d/plugins/rite/agents/_reviewer-base.md"

  {
    printf '# Reviewer Skills fixture\n\n'
    printf '## Available Reviewers\n\n'
    printf 'See `victor-reviewer.md` for details (in-section prose must not leak into extraction).\n\n'
    printf '| Reviewer | Agent | File Patterns (Primary) |\n'
    printf '|----------|-------|-------------------------|\n'
    for slug in "${FIXTURE_SLUGS[@]}"; do
      printf '| %s Expert | `%s-reviewer.md` | `**/%s/**` |\n' "$slug" "$slug" "$slug"
    done
    printf '\n## Reviewer Type Identifiers\n\n'
    printf 'See `whiskey-reviewer.md` for details (in-section prose must not leak into extraction).\n\n'
    printf '| reviewer_type | 日本語表示名 | Agent |\n'
    printf '|---------------|-------------|-------|\n'
    for slug in "${FIXTURE_SLUGS[@]}"; do
      printf '| %s | %s 専門家 | `%s-reviewer.md` |\n' "$slug" "$slug" "$slug"
    done
    printf '\n## Trailing Section\n\nProse mentioning `unrelated-reviewer.md` outside tables must not count.\n'
  } > "$d/plugins/rite/skills/reviewers/SKILL.md"

  echo "$d"
}

# --- TC-1: real repository registry is in sync (T-05 / AC-2) ---
echo "=== TC-1: real repository registry passes with rc=0 ==="
REPO_ROOT="$(_helpers_resolve_repo_root "$SCRIPT_DIR")"
rc=0
out=$(bash "$CHECKER" --all --quiet --repo-root "$REPO_ROOT" 2>&1) || rc=$?
if [ "$rc" -eq 0 ]; then
  pass "TC-1: real registry reports no drift"
else
  fail "TC-1: expected rc=0 on real repository, got rc=$rc"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi

# --- TC-2: synchronized fixture passes (baseline for mutation cases) ---
echo ""
echo "=== TC-2: synchronized fixture registry → rc=0 ==="
d=$(make_registry_sandbox)
cleanup_dirs+=("$d")
rc=0
out=$(bash "$CHECKER" --all --quiet --repo-root "$d" 2>&1) || rc=$?
if [ "$rc" -eq 0 ]; then
  pass "TC-2: synchronized fixture reports no drift"
else
  fail "TC-2: expected rc=0 on synchronized fixture, got rc=$rc"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi
if printf '%s\n' "$out" | grep -Fq "unrelated-reviewer.md"; then
  fail "TC-2: prose outside tables leaked into the comparison"
else
  pass "TC-2: prose outside tables correctly ignored"
fi
if printf '%s\n' "$out" | grep -Fq "_reviewer-base"; then
  fail "TC-2: shared principles file leaked into the agents set"
else
  pass "TC-2: _reviewer-base.md correctly excluded from the agents set"
fi
# in-section 非パイプ散文行（テーブル行の直前に挿入した decoy）が抽出に漏れないこと
# を確認する。TC-2 既存の "unrelated-reviewer.md" decoy は Trailing Section（セクション
# 境界外）にあり `in_sec && /^## / { in_sec = 0 }` の境界判定のみを検証しているため、
# `extract_section_rows` の `/^\|/` 行フィルタ自体（awk の pipe-prefix チェック）を
# 削除する mutation を生き残らせてしまう。本 decoy はセクション「内」の非パイプ行
# なので、行フィルタが外れると victor/whiskey が Available/Type Identifiers 双方の
# 集合に漏れ出し、agents.set に存在しないため drift finding として検出され rc が
# 1 に変わる（本 TC の rc=0 assert 自体が mutation を kill する）。
if printf '%s\n' "$out" | grep -Fq "victor-reviewer"; then
  fail "TC-2: in-section prose decoy (Available Reviewers) leaked into extraction"
else
  pass "TC-2: Available Reviewers セクション内の非パイプ散文行が正しく除外された"
fi
if printf '%s\n' "$out" | grep -Fq "whiskey-reviewer"; then
  fail "TC-2: in-section prose decoy (Type Identifiers) leaked into extraction"
else
  pass "TC-2: Type Identifiers セクション内の非パイプ散文行が正しく除外された"
fi

# --- TC-3: dummy agent file added without table updates → drift (T-01) ---
echo ""
echo "=== TC-3: agent file added, tables not updated → rc=1 (I1 forward) ==="
d=$(make_registry_sandbox)
cleanup_dirs+=("$d")
printf '# dummy\n' > "$d/plugins/rite/agents/dummy-reviewer.md"
rc=0
out=$(bash "$CHECKER" --all --quiet --repo-root "$d" 2>&1) || rc=$?
if [ "$rc" -eq 1 ]; then
  pass "TC-3: drift detected with rc=1"
else
  fail "TC-3: expected rc=1, got rc=$rc"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi
if printf '%s\n' "$out" | grep -Fq "dummy-reviewer.md"; then
  pass "TC-3: finding names the missing reviewer"
else
  fail "TC-3: dummy-reviewer.md missing from findings"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi

# --- TC-4: Available Reviewers row added alone → drift (T-03, I2) ---
echo ""
echo "=== TC-4: Available Reviewers updated, Type Identifiers not → rc=1 (I2) ==="
d=$(make_registry_sandbox)
cleanup_dirs+=("$d")
# Available Reviewers 表にだけ新 reviewer 行を足す（既存行の直後に挿入し、
# セクション境界に依存しない位置で drift を作る）
awk_inplace "$d/plugins/rite/skills/reviewers/SKILL.md" '
  { print }
  /^\| alpha Expert \|/ { print "| zulu Expert | `zulu-reviewer.md` | `**/zulu/**` |" }
'
rc=0
out=$(bash "$CHECKER" --all --quiet --repo-root "$d" 2>&1) || rc=$?
if [ "$rc" -eq 1 ]; then
  pass "TC-4: partial table update detected with rc=1"
else
  fail "TC-4: expected rc=1, got rc=$rc"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi
if printf '%s\n' "$out" | grep -Fq "zulu-reviewer.md"; then
  pass "TC-4: finding names the half-registered reviewer"
else
  fail "TC-4: zulu-reviewer.md missing from findings"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi

# --- TC-5: Type Identifiers row removed alone → drift (I1 forward) ---
echo ""
echo "=== TC-5: Type Identifiers row missing for an existing agent → rc=1 ==="
d=$(make_registry_sandbox)
cleanup_dirs+=("$d")
awk_inplace "$d/plugins/rite/skills/reviewers/SKILL.md" '
  /^\| bravo \| bravo 専門家 \|/ { next }
  { print }
'
rc=0
out=$(bash "$CHECKER" --all --quiet --repo-root "$d" 2>&1) || rc=$?
if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -Fq "bravo-reviewer.md"; then
  pass "TC-5: missing Type Identifiers row detected (agents側 + Available側から双方向で浮く)"
else
  fail "TC-5: expected rc=1 with bravo-reviewer.md finding, got rc=$rc"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi

# --- TC-6: slug/Agent balanced swap → I3 fires in isolation ---
echo ""
echo "=== TC-6: Type Identifiers slug/Agent balanced swap → rc=1 (I3 only) ==="
d=$(make_registry_sandbox)
cleanup_dirs+=("$d")
# charlie 行と delta 行の Agent セルを相互に入れ替える（均衡入替）。集合としては
# 両ファイル名とも存在し続けるため I1/I2 の集合差分は発火せず、I3 の行内整合
# チェックのみが検出できる drift になる（真に I3-isolated なテスト）
awk_inplace "$d/plugins/rite/skills/reviewers/SKILL.md" '
  $0 == "| charlie | charlie 専門家 | `charlie-reviewer.md` |" { print "| charlie | charlie 専門家 | `delta-reviewer.md` |"; next }
  $0 == "| delta | delta 専門家 | `delta-reviewer.md` |" { print "| delta | delta 専門家 | `charlie-reviewer.md` |"; next }
  { print }
'
rc=0
out=$(bash "$CHECKER" --all --quiet --repo-root "$d" 2>&1) || rc=$?
if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -Fq "slug charlie expects charlie-reviewer.md"; then
  pass "TC-6: slug/Agent mismatch detected via I3 row check"
else
  fail "TC-6: expected rc=1 with slug mismatch finding, got rc=$rc"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi
# 均衡入替により集合は保存されるため、I1/I2 の集合差分 finding（"only in ..."）が
# 混入していないことを assert する（I3 の固有価値を分離検証）
if printf '%s\n' "$out" | grep -Fq "only in"; then
  fail "TC-6: set-difference findings leaked — swap was not balanced (I3 not isolated)"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
else
  pass "TC-6: I1/I2 set differences silent — I3 isolated as intended"
fi

# --- TC-7: heading change → undersized extraction → invocation error ---
echo ""
echo "=== TC-7: renamed section heading → rc=2 (extraction guard) ==="
d=$(make_registry_sandbox)
cleanup_dirs+=("$d")
awk_inplace "$d/plugins/rite/skills/reviewers/SKILL.md" '
  $0 == "## Reviewer Type Identifiers" { print "## Renamed Identifiers"; next }
  { print }
'
rc=0
out=$(bash "$CHECKER" --all --quiet --repo-root "$d" 2>&1) || rc=$?
if [ "$rc" -eq 2 ]; then
  pass "TC-7: heading drift fails fast as invocation error (not a huge diff report)"
else
  fail "TC-7: expected rc=2, got rc=$rc"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi
# rc=2 は「>= 6 抽出ガード」「I3 行数ガード」の 2 経路で発火しうる。本 TC は見出し
# 変更による抽出崩壊が狙いなので、発火元が抽出ガードであることを文言で特定する
# （どちらのガードが落ちたのか未検証のまま rc=2 だけ見ると、実装が別ガードで
# 偶然 rc=2 を返す regression を見逃す）。
# BSD/macOS `wc` right-justifies the count with leading spaces, so the script's
# message reads "extracted only        0 reviewers" — match with a whitespace
# class instead of a fixed single space (the governing rationale; same BSD wc padding as TC-15).
if printf '%s\n' "$out" | grep -qE "extracted only[[:space:]]+0 reviewers"; then
  pass "TC-7: fired via the >= 6 extraction guard (not the I3 row-count guard)"
else
  fail "TC-7: rc=2 but not via the extraction guard — unexpected message"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi

# --- TC-8: --all is required ---
echo ""
echo "=== TC-8: missing --all → rc=2 ==="
rc=0
bash "$CHECKER" --repo-root "$REPO_ROOT" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then
  pass "TC-8: --all contract enforced"
else
  fail "TC-8: expected rc=2 without --all, got rc=$rc"
fi

# --- TC-9: Type Identifiers row without agent profile → drift (I1 reverse) ---
echo ""
echo "=== TC-9: orphan Type Identifiers row (no agent profile) → rc=1 (I1 reverse) ==="
d=$(make_registry_sandbox)
cleanup_dirs+=("$d")
# Type Identifiers 表にだけ mike 行を追加する（agents/ ファイルも Available 行も
# 作らない）。spawn 時に存在しない subagent を解決しようとする failure mode を
# 検出する I1 reverse 方向（identifiers → agents/）を単独で発火させる
awk_inplace "$d/plugins/rite/skills/reviewers/SKILL.md" '
  { print }
  /^\| alpha \| alpha 専門家 \|/ { print "| mike | mike 専門家 | `mike-reviewer.md` |" }
'
rc=0
out=$(bash "$CHECKER" --all --quiet --repo-root "$d" 2>&1) || rc=$?
# ヘッダ行（方向ラベル）と finding 行（ファイル名）は別行のため独立に assert する
if [ "$rc" -eq 1 ] \
  && printf '%s\n' "$out" | grep -Fq "only in Type Identifiers table" \
  && printf '%s\n' "$out" | grep -Fq "mike-reviewer.md"; then
  pass "TC-9: reverse direction (identifiers row without profile) detected"
else
  fail "TC-9: expected rc=1 with 'only in Type Identifiers table' finding for mike-reviewer.md, got rc=$rc"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi

# --- TC-10: column inserted before Agent → I3 row-count guard → rc=2 ---
echo ""
echo "=== TC-10: Type Identifiers table gains a column before Agent → rc=2 (I3 guard) ==="
d=$(make_registry_sandbox)
cleanup_dirs+=("$d")
# Type Identifiers セクションのデータ行だけ Agent セルの前に EXTRA 列を挿入する。
# Agent トークンが $4 から $5 へずれ、位置依存の I3 が全行 skip → 検査行数ガードが
# rc=2 で fail fast することを検証する（silent false pass の遮断）。
# データ行のみバッククォートを含むため、最初の "| `" を "| EXTRA | `" に置換する。
awk_inplace "$d/plugins/rite/skills/reviewers/SKILL.md" '
  /^## Reviewer Type Identifiers$/ { in_sec = 1 }
  in_sec && /^## Trailing Section$/ { in_sec = 0 }
  in_sec && /^\|.*`/ { sub(/\| `/, "| EXTRA | `") }
  { print }
'
rc=0
out=$(bash "$CHECKER" --all --quiet --repo-root "$d" 2>&1) || rc=$?
if [ "$rc" -eq 2 ]; then
  pass "TC-10: I3 row-count guard fails fast on column shift (no silent rc=0)"
else
  fail "TC-10: expected rc=2, got rc=$rc (I3 must not silently no-op on format change)"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi
# TC-7 と対称の guard 特定 assert。列挿入は正規表現ベースの set 抽出（>= 6 ガード）
# 自体は通過し、位置依存の I3 行数ガードだけが落ちるはずなので、その guard 固有の
# 文言で発火元を特定する（抽出ガードで落ちていたら列シフト検知の意図が壊れている）。
if printf '%s\n' "$out" | grep -Fq "I3 slug check evaluated only 0 rows"; then
  pass "TC-10: fired via the I3 row-count guard (not the >= 6 extraction guard)"
else
  fail "TC-10: rc=2 but not via the I3 guard — unexpected message"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi

# --- TC-11: --repo-root without a value → rc=2 ---
echo ""
echo "=== TC-11: --repo-root with missing value → rc=2 (exit code contract) ==="
rc=0
bash "$CHECKER" --all --repo-root >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then
  pass "TC-11: bad args stay on exit 2 (not misclassified as drift rc=1)"
else
  fail "TC-11: expected rc=2 for --repo-root without value, got rc=$rc"
fi

# --- TC-12: aggregate log line contract (no --quiet) ---
echo ""
echo "=== TC-12: aggregate log line exact match without --quiet (skills/lint contract) ==="
# skills/lint/SKILL.md Phase 3.5 チェック表 (Count line 列) は "==> Total reviewer-registry-drift findings: N"
# を抽出 regex で消費する cross-component 契約。他の全 TC は --quiet を付けて実行して
# おり文言の drift を検出できないため、本 TC だけ --quiet なしで実行し完全一致で
# assert する（TC-3 と同じ 1 finding 固定ミューテーションを再利用）。
d=$(make_registry_sandbox)
cleanup_dirs+=("$d")
printf '# dummy\n' > "$d/plugins/rite/agents/dummy-reviewer.md"
rc=0
out=$(bash "$CHECKER" --all --repo-root "$d" 2>&1) || rc=$?
if [ "$rc" -eq 1 ]; then
  pass "TC-12: drift detected with rc=1 (same fixture as TC-3)"
else
  fail "TC-12: expected rc=1, got rc=$rc"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi
if printf '%s\n' "$out" | grep -Fxq "==> Total reviewer-registry-drift findings: 1"; then
  pass "TC-12: aggregate log line matches the skills/lint extraction contract exactly"
else
  fail "TC-12: aggregate log line missing or drifted from 'Total reviewer-registry-drift findings: N'"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi

# --- TC-13: missing registry dir/file → clean skip (rc=0, not applicable) ---
echo ""
echo "=== TC-13: --repo-root without a registry (missing dir/file) → rc=0 (not applicable) ==="
empty_dir=$(make_plain_sandbox)
cleanup_dirs+=("$empty_dir")
rc=0
out=$(bash "$CHECKER" --all --repo-root "$empty_dir" 2>&1) || rc=$?
if [ "$rc" -eq 0 ]; then
  pass "TC-13: missing plugins/rite/agents and reviewers/SKILL.md (consumer/marketplace install) correctly no-ops with rc=0"
else
  fail "TC-13: expected rc=0, got rc=$rc"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi
if printf '%s\n' "$out" | grep -Fq "not applicable"; then
  pass "TC-13: not-applicable skip message present"
else
  fail "TC-13: expected 'not applicable' message in output"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi

# --- TC-14: asymmetric absence (partial checkout) exits 2, NOT clean skip ---
# TC-13 only proves the AND-gated clean-skip fires when NEITHER sync point
# exists. It cannot detect an AND→OR regression in the guard (the governing rationale
# cycle3 review: doc-heavy has this asymmetric-absence coverage via Test 7b,
# but reviewer-registry did not — this closes that family-wide gap). A
# targeted-deletion attack removing only one sync point must still surface as
# an invocation error (rc=2), distinct from the legitimate both-absent skip.
echo ""
echo "=== TC-14a: only plugins/rite/agents/ present (reviewers/SKILL.md missing) → rc=2 ==="
d=$(make_registry_sandbox)
cleanup_dirs+=("$d")
rm -f "$d/plugins/rite/skills/reviewers/SKILL.md"
rc=0
out=$(bash "$CHECKER" --all --quiet --repo-root "$d" 2>&1) || rc=$?
if [ "$rc" -eq 2 ]; then
  pass "TC-14a: asymmetric absence (SKILL.md missing) correctly fails with rc=2"
else
  fail "TC-14a: expected rc=2, got rc=$rc"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi
if printf '%s\n' "$out" | grep -Fq "not applicable"; then
  fail "TC-14a: asymmetric absence incorrectly treated as clean skip (not applicable)"
else
  pass "TC-14a: asymmetric absence not confused with the clean-skip path"
fi
# Needle pins the full path of the MISSING sync point — a bare "SKILL.md"
# would pass even if the diagnostic named the wrong file.
if printf '%s\n' "$out" | grep -Fq "reviewers/SKILL.md"; then
  pass "TC-14a: names reviewers/SKILL.md as the missing sync point"
else
  fail "TC-14a: expected output to name reviewers/SKILL.md"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi

echo ""
echo "=== TC-14b: only reviewers/SKILL.md present (plugins/rite/agents/ missing) → rc=2 ==="
d=$(make_registry_sandbox)
cleanup_dirs+=("$d")
rm -rf "$d/plugins/rite/agents"
rc=0
out=$(bash "$CHECKER" --all --quiet --repo-root "$d" 2>&1) || rc=$?
if [ "$rc" -eq 2 ]; then
  pass "TC-14b: asymmetric absence (agents/ missing) correctly fails with rc=2"
else
  fail "TC-14b: expected rc=2, got rc=$rc"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi
if printf '%s\n' "$out" | grep -Fq "not applicable"; then
  fail "TC-14b: asymmetric absence incorrectly treated as clean skip (not applicable)"
else
  pass "TC-14b: asymmetric absence not confused with the clean-skip path"
fi
if printf '%s\n' "$out" | grep -Fq "plugins/rite/agents"; then
  pass "TC-14b: names plugins/rite/agents as the missing sync point"
else
  fail "TC-14b: expected output to name plugins/rite/agents"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi

# --- TC-15: numeric slug (web3) synced fixture → rc=0, correctly counted in
# all 3 sync points (regression guard for AGENT_RE digit support, the governing rationale) ---
# The observed review run extended AGENT_RE from `[a-z][a-z-]*-reviewer[.]md` to
# `[a-z][a-z0-9-]*-reviewer[.]md` so digit-bearing slugs (e.g. web3) are
# extracted instead of silently dropping out of all 3 sets + the I3 row
# filter. A plain rc=0 assertion on a fully-synced fixture would NOT catch a
# regression here: if AGENT_RE reverted, web3-reviewer.md would simply be
# excluded from every set, so the fixture would still trivially report rc=0
# (in sync) for the wrong reason. Asserting the reported per-source counts
# equal the full FIXTURE_SLUGS length (13) instead of 12 is what actually
# distinguishes "correctly counted" from "silently dropped" — the log line
# only prints its count with --quiet omitted, hence no --quiet here.
echo ""
echo "=== TC-15: numeric slug (web3) synced fixture → rc=0, counted in all 3 sync points ==="
d=$(make_registry_sandbox)
cleanup_dirs+=("$d")
expected_count=${#FIXTURE_SLUGS[@]}
rc=0
out=$(bash "$CHECKER" --all --repo-root "$d" 2>&1) || rc=$?
if [ "$rc" -eq 0 ]; then
  pass "TC-15: numeric-slug fixture reports no drift"
else
  fail "TC-15: expected rc=0, got rc=$rc"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi
# The `[[:space:]]*` after the colon tolerates BSD/macOS `wc -l` output, which
# right-justifies its count with leading spaces (the checker interpolates that
# count into these log lines). AGENT_RE itself is already digit-aware and
# portable — the count still asserts web3-reviewer.md is not dropped .
if printf '%s\n' "$out" | grep -qE "agents/ profiles[[:space:]]*:[[:space:]]*${expected_count} reviewers"; then
  pass "TC-15: agents/ profiles count includes web3-reviewer.md (not silently dropped by AGENT_RE)"
else
  fail "TC-15: expected agents/ profiles count to be ${expected_count} (web3 must not be excluded by a digit-unaware AGENT_RE)"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi
if printf '%s\n' "$out" | grep -qE "Available Reviewers table[[:space:]]*:[[:space:]]*${expected_count} reviewers"; then
  pass "TC-15: Available Reviewers table count includes web3-reviewer.md"
else
  fail "TC-15: expected Available Reviewers table count to be ${expected_count}"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi
if printf '%s\n' "$out" | grep -qE "Type Identifiers table[[:space:]]*:[[:space:]]*${expected_count} reviewers"; then
  pass "TC-15: Type Identifiers table count includes web3-reviewer.md"
else
  fail "TC-15: expected Type Identifiers table count to be ${expected_count}"
  echo "--- output ---"; printf '%s\n' "$out"; echo "--- end ---"
fi

# --- Summary ---
echo ""
if ! print_summary "$(basename "$0")" "reviewer registry 3-way sync"; then
  exit 1
fi
