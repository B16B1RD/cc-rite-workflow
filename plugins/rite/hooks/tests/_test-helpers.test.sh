#!/bin/bash
# Self-test for _test-helpers.sh
#
# Each test case runs in a subshell that re-sources _test-helpers.sh,
# so we can observe how the helpers mutate the PASS / FAIL / FAILED_NAMES
# counters in isolation without polluting our own outer counters.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPERS="$SCRIPT_DIR/_test-helpers.sh"

# Outer-test counters (use plain integers to avoid colliding with helper counters
# loaded inside subshells under test).
OUTER_PASS=0
OUTER_FAIL=0
OUTER_FAILED=()

outer_pass() { OUTER_PASS=$((OUTER_PASS + 1)); echo "  ✅ $1"; }
outer_fail() { OUTER_FAIL=$((OUTER_FAIL + 1)); OUTER_FAILED+=("$1"); echo "  ❌ $1"; }

if [ ! -f "$HELPERS" ]; then
  # Output convention: Hard precondition (missing executable) → stderr
  echo "FATAL: $HELPERS not found" >&2
  exit 1
fi

# === TC-1: path resolvers ===
echo "TC-1: _helpers_resolve_plugin_root / _helpers_resolve_repo_root"

expected_plugin_root=$(cd "$SCRIPT_DIR/../.." && pwd)
expected_repo_root=$(cd "$SCRIPT_DIR/../../../.." && pwd)

actual_plugin_root=$(bash -c "source '$HELPERS' && _helpers_resolve_plugin_root '$SCRIPT_DIR'")
if [ "$actual_plugin_root" = "$expected_plugin_root" ]; then
  outer_pass "TC-1.1: _helpers_resolve_plugin_root returns plugins/rite"
else
  outer_fail "TC-1.1: expected='$expected_plugin_root' actual='$actual_plugin_root'"
fi

actual_repo_root=$(bash -c "source '$HELPERS' && _helpers_resolve_repo_root '$SCRIPT_DIR'")
if [ "$actual_repo_root" = "$expected_repo_root" ]; then
  outer_pass "TC-1.2: _helpers_resolve_repo_root returns repo root"
else
  outer_fail "TC-1.2: expected='$expected_repo_root' actual='$actual_repo_root'"
fi

# === TC-2: pass / fail mutate counters ===
echo
echo "TC-2: pass / fail counter mutation"

# capture inner PASS / FAIL / FAILED_NAMES state in subshell
inner_state=$(bash -c "
  source '$HELPERS'
  pass 'sample-pass'   >/dev/null
  pass 'sample-pass-2' >/dev/null
  fail 'sample-fail'   >/dev/null
  echo \"PASS=\$PASS\"
  echo \"FAIL=\$FAIL\"
  echo \"FAILED_COUNT=\${#FAILED_NAMES[@]}\"
  echo \"FAILED_HEAD=\${FAILED_NAMES[0]:-}\"
")

inner_pass=$(echo "$inner_state" | grep '^PASS=' | cut -d= -f2)
inner_fail=$(echo "$inner_state" | grep '^FAIL=' | cut -d= -f2)
inner_failed_count=$(echo "$inner_state" | grep '^FAILED_COUNT=' | cut -d= -f2)
inner_failed_head=$(echo "$inner_state" | grep '^FAILED_HEAD=' | cut -d= -f2)

if [ "$inner_pass" = "2" ]; then
  outer_pass "TC-2.1: pass() increments PASS to 2"
else
  outer_fail "TC-2.1: expected PASS=2 got PASS=$inner_pass"
fi

if [ "$inner_fail" = "1" ]; then
  outer_pass "TC-2.2: fail() increments FAIL to 1"
else
  outer_fail "TC-2.2: expected FAIL=1 got FAIL=$inner_fail"
fi

if [ "$inner_failed_count" = "1" ] && [ "$inner_failed_head" = "sample-fail" ]; then
  outer_pass "TC-2.3: fail() appends label to FAILED_NAMES"
else
  outer_fail "TC-2.3: expected count=1 head='sample-fail' got count=$inner_failed_count head='$inner_failed_head'"
fi

# === TC-3: assert ===
echo
echo "TC-3: assert (equality)"

assert_state=$(bash -c "
  source '$HELPERS'
  assert 'eq-match'  'foo' 'foo' >/dev/null
  assert 'eq-mismatch' 'foo' 'bar' >/dev/null
  echo \"PASS=\$PASS\"
  echo \"FAIL=\$FAIL\"
")
ap=$(echo "$assert_state" | grep '^PASS=' | cut -d= -f2)
af=$(echo "$assert_state" | grep '^FAIL=' | cut -d= -f2)
if [ "$ap" = "1" ] && [ "$af" = "1" ]; then
  outer_pass "TC-3.1: assert passes on equal, fails on unequal"
else
  outer_fail "TC-3.1: expected PASS=1 FAIL=1 got PASS=$ap FAIL=$af"
fi

# === TC-4: assert_grep / assert_not_grep ===
echo
echo "TC-4: assert_grep / assert_not_grep"

tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT
printf 'hello world\nfoo bar\n' > "$tmpfile"

grep_state=$(bash -c "
  source '$HELPERS'
  assert_grep     'present'   '$tmpfile' 'hello'   >/dev/null
  assert_grep     'absent'    '$tmpfile' 'missing' >/dev/null
  assert_not_grep 'absent-ok' '$tmpfile' 'missing' >/dev/null
  assert_not_grep 'present-bad' '$tmpfile' 'hello' >/dev/null
  echo \"PASS=\$PASS\"
  echo \"FAIL=\$FAIL\"
")
gp=$(echo "$grep_state" | grep '^PASS=' | cut -d= -f2)
gf=$(echo "$grep_state" | grep '^FAIL=' | cut -d= -f2)
if [ "$gp" = "2" ] && [ "$gf" = "2" ]; then
  outer_pass "TC-4.1: assert_grep / assert_not_grep route correctly"
else
  outer_fail "TC-4.1: expected PASS=2 FAIL=2 got PASS=$gp FAIL=$gf"
fi

# TC-4.2 / TC-4.3: file-not-found path emits "file not found" diagnostic
missing_state=$(bash -c "
  source '$HELPERS'
  assert_grep     'missing-grep'     '/nonexistent/path/xyz' 'pattern' 2>&1
  assert_not_grep 'missing-not-grep' '/nonexistent/path/xyz' 'pattern' 2>&1
  echo \"FAIL=\$FAIL\"
")
mfail=$(echo "$missing_state" | grep '^FAIL=' | cut -d= -f2)
if [ "$mfail" = "2" ]; then
  outer_pass "TC-4.2: file-not-found increments FAIL for both assert_grep and assert_not_grep"
else
  outer_fail "TC-4.2: expected FAIL=2 got FAIL=$mfail"
fi
if echo "$missing_state" | grep -q 'file not found'; then
  outer_pass "TC-4.3: file-not-found diagnostic message is emitted"
else
  outer_fail "TC-4.3: 'file not found' diagnostic missing in output"
fi

# === TC-5: print_summary return code ===
echo
echo "TC-5: print_summary return code"

# All-pass case → exit 0
if bash -c "source '$HELPERS'; pass 'x' >/dev/null; print_summary 'self-test' >/dev/null"; then
  outer_pass "TC-5.1: print_summary returns 0 when FAIL=0"
else
  outer_fail "TC-5.1: print_summary returned non-zero on all-pass"
fi

# Any-fail case → exit 1
if bash -c "source '$HELPERS'; fail 'x' >/dev/null; print_summary 'self-test' >/dev/null"; then
  outer_fail "TC-5.2: print_summary returned 0 on FAIL>0 (expected non-zero)"
else
  outer_pass "TC-5.2: print_summary returns non-zero when FAIL>0"
fi

# === TC-6: drift hint is echoed in summary ===
echo
echo "TC-6: print_summary drift hint propagation"

summary_output=$(bash -c "source '$HELPERS'; fail 'sample' >/dev/null; print_summary 'self-test' 'CUSTOM-DRIFT-HINT' || true")
if echo "$summary_output" | grep -q 'CUSTOM-DRIFT-HINT'; then
  outer_pass "TC-6.1: drift hint text appears in summary output"
else
  outer_fail "TC-6.1: drift hint not found in: $summary_output"
fi

# === TC-7: make_sandbox basic ===
echo
echo "TC-7: make_sandbox default invocation → git-init + commit"

sbx_default=$(bash -c "source '$HELPERS'; make_sandbox")
if [ -d "$sbx_default" ] && [ -d "$sbx_default/.git" ]; then
  outer_pass "TC-7.1: make_sandbox returns an existing path with a .git directory"
else
  outer_fail "TC-7.1: make_sandbox path '$sbx_default' missing .git or directory"
fi

# Initial commit reachable via `git log` (any non-zero output proves commit landed).
log_output=$(cd "$sbx_default" 2>/dev/null && git log --oneline 2>/dev/null || true)
if [ -n "$log_output" ]; then
  outer_pass "TC-7.2: make_sandbox produced an initial commit (git log non-empty)"
else
  outer_fail "TC-7.2: make_sandbox did not produce an initial commit (git log empty)"
fi
rm -rf "$sbx_default"

# === TC-8: make_sandbox --branch ===
echo
echo "TC-8: make_sandbox --branch <name> → HEAD on requested branch"

sbx_branch=$(bash -c "source '$HELPERS'; make_sandbox --branch fix/issue-687-test")
head_branch=$(cd "$sbx_branch" 2>/dev/null && git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
if [ "$head_branch" = "fix/issue-687-test" ]; then
  outer_pass "TC-8.1: HEAD is on the requested branch (fix/issue-687-test)"
else
  outer_fail "TC-8.1: expected HEAD on fix/issue-687-test, got '$head_branch'"
fi
rm -rf "$sbx_branch"

# F-08: TC-8.2 / TC-8.3 — option-parse error variants (return 2).
# Pins the explicit `if [ $# -lt 2 ] || [ -z "$2" ]` guard so a regression that
# changes `shift 2` to `shift` (and silently accepts `--branch` with no value)
# is caught.
# `|| rc=$?` 形式: set -e の下で非ゼロ exit が abort を起こさないよう短絡。
rc_empty=0
bash -c "source '$HELPERS'; make_sandbox --branch '' 2>/dev/null" || rc_empty=$?
if [ "$rc_empty" = "2" ]; then
  outer_pass "TC-8.2: --branch \"\" returns rc=2 (option parse error)"
else
  outer_fail "TC-8.2: expected rc=2 for --branch \"\", got rc=$rc_empty"
fi

rc_missing=0
bash -c "source '$HELPERS'; make_sandbox --branch 2>/dev/null" || rc_missing=$?
if [ "$rc_missing" = "2" ]; then
  outer_pass "TC-8.3: --branch with no argument returns rc=2 (option parse error)"
else
  outer_fail "TC-8.3: expected rc=2 for --branch with no argument, got rc=$rc_missing"
fi

# === TC-9: make_sandbox --soft ===
echo
echo "TC-9: make_sandbox --soft → success returns sandbox, failure returns rc=1 (no exit)"

# Success path: --soft must not change the success-side contract.
sbx_soft=$(bash -c "source '$HELPERS'; make_sandbox --soft")
if [ -d "$sbx_soft/.git" ]; then
  outer_pass "TC-9.1: make_sandbox --soft returns a working sandbox on success path"
else
  outer_fail "TC-9.1: make_sandbox --soft missing .git (path: '$sbx_soft')"
fi
rm -rf "$sbx_soft"

# TC-9.2 — failure path: --soft の存在意義 (infrastructure 失敗時に exit ではなく return 1) を pin。
# Cycle 2 F-05 修正: 旧コメントは「git 失敗時に return 1」と主張していたが、`mktemp` は GNU coreutils
# の外部コマンド (bash builtin ではない) のため、`PATH=/dev/null` 下では `mktemp -d` (helper line 216
# 相当) が先に失敗し soft-fail return が発火する。git init/commit 失敗の soft-fail branch (helper
# line 245 相当) は untested のまま。TC-9.3 で git 失敗 path を別途 pin する。
# `|| rc=$?` 形式: set -e の下で非ゼロ exit が abort を起こさないよう短絡。
rc_soft_fail=0
bash -c "source '$HELPERS'; PATH=/dev/null make_sandbox --soft 2>/dev/null" || rc_soft_fail=$?
if [ "$rc_soft_fail" = "1" ]; then
  outer_pass "TC-9.2: make_sandbox --soft returns rc=1 on mktemp failure (does NOT exit)"
else
  outer_fail "TC-9.2: expected rc=1 (soft-fail on mktemp failure), got rc=$rc_soft_fail"
fi

# TC-9.3 — failure path: git unreachable but mktemp reachable。
# git shim 経由で git init/commit を強制失敗させ、helper の soft-fail return branch
# (subshell 内 `git init -q ...` 失敗 → 外側 if ! で `return 1`) を実際に exercise する。
#
# Cycle 3 F-03 (claim 縮小): 旧コメントは「mutation で return 1 → exit 1 に書き換えると test が
# 失敗する」と主張していたが、production caller (TC-016 等) はすべて `$(make_sandbox --soft)` の
# command substitution 経由で呼び出すため、`return 1` も `exit 1` も subshell rc=1 として観測され
# 区別不能。本テストの契約は「git failure → 親に rc=1 が伝わり caller が `if !` で受けられる」
# ことに縮小する (return/exit semantic 区別は本契約の本質ではない)。
#
# Cycle 3 F-05/F-07 (trap quartet): 既存の line 111 `trap 'rm -f "$tmpfile"' EXIT` を破壊せず、
# tc93_dir cleanup を加算した結合 trap を signal quartet 全 (EXIT/INT/TERM/HUP) に設定する。
# Cycle 3 F-08 (command -v guard): `command -v mktemp` empty で broken symlink を作る silent
# failure 経路を fail-fast guard で塞ぐ。
# Cycle 3 F-09 (stderr verify): git shim ERROR を tempfile に capture し shim 実行を assert する
# (PATH ordering 退行で real git が解決される regression を構造的に検出可能化)。
# Cycle 3 F-10 (rm -rf check): cleanup は trap 経由で確実に実行されるため、明示 rm -rf は不要。
tc93_dir=$(mktemp -d) || { echo "FATAL: TC-9.3 mktemp -d failed" >&2; exit 1; }
# 既存 line 111 trap (`trap 'rm -f "$tmpfile"' EXIT`) を破壊せず、tc93_dir cleanup を加算 + quartet 化。
trap 'rm -rf "$tc93_dir"; rm -f "$tmpfile"' EXIT
trap 'rm -rf "$tc93_dir"; rm -f "$tmpfile"; exit 130' INT
trap 'rm -rf "$tc93_dir"; rm -f "$tmpfile"; exit 143' TERM
trap 'rm -rf "$tc93_dir"; rm -f "$tmpfile"; exit 129' HUP

# command -v mktemp guard (F-08): empty 結果 (mktemp 不在環境) で broken symlink を作る silent
# failure を防ぐ。empty なら fail-fast。
mktemp_path=$(command -v mktemp || true)
if [ -z "$mktemp_path" ]; then
  echo "FATAL: TC-9.3 requires mktemp on PATH but command -v mktemp returned empty" >&2
  exit 1
fi
ln -sf "$mktemp_path" "$tc93_dir/mktemp"

# git invalidator: PATH に置いた shim が本物の git より優先される。
cat > "$tc93_dir/git" <<'GIT_SHIM_EOF'
#!/bin/sh
echo "ERROR: git shim invoked (TC-9.3 force-failure)" >&2
exit 127
GIT_SHIM_EOF
chmod +x "$tc93_dir/git"

# F-09: shim invocation を観測可能にするため stderr を tempfile に capture (2>/dev/null では
# PATH ordering 退行を構造的に検出できない)。
shim_stderr="$tc93_dir/shim-stderr.log"
rc_git_fail=0
bash -c "source '$HELPERS'; PATH='$tc93_dir':/usr/bin:/bin make_sandbox --soft" \
  2>"$shim_stderr" || rc_git_fail=$?

if [ "$rc_git_fail" = "1" ]; then
  outer_pass "TC-9.3: make_sandbox --soft returns rc=1 on git failure (soft-fail contract)"
else
  outer_fail "TC-9.3: expected rc=1 (soft-fail on git failure), got rc=$rc_git_fail"
fi

# F-09: shim が実際に invoke されたことを assert (PATH ordering 退行検出)。
if grep -q "git shim invoked" "$shim_stderr"; then
  outer_pass "TC-9.3.shim: git shim was invoked (PATH ordering correct)"
else
  outer_fail "TC-9.3.shim: git shim was NOT invoked — PATH ordering may have changed (stderr: $(head -3 "$shim_stderr"))"
fi

# Restore trap to original (line 111) form for the remaining TCs.
# tc93_dir は本 block 後に不要 (assertion 完了) のため EXIT までは trap chain で保持しても問題なし、
# ただし後続 TC で tc93_dir 参照は発生しないため EXIT trap を simple form に戻して理解しやすくする。
rm -rf "$tc93_dir"
trap 'rm -f "$tmpfile"' EXIT
trap - INT TERM HUP

# === TC-10: make_sandbox unknown option → return 2 ===
echo
echo "TC-10: make_sandbox unknown option → return 2 (option parse error)"

# F-06: rc=2 specific assertion. The previous test only verified non-zero exit,
# which would not catch a regression that changes `return 2` to `return 1` (the
# soft-fail code) or `exit 1` (hard-fail). Pin the specific contract.
# `|| rc=$?` 形式: set -e の下で非ゼロ exit が abort を起こさないよう短絡。
rc_bogus=0
bash -c "source '$HELPERS'; make_sandbox --bogus 2>/dev/null" || rc_bogus=$?
if [ "$rc_bogus" = "2" ]; then
  outer_pass "TC-10.1: make_sandbox --bogus returns rc=2 (option parse error)"
else
  outer_fail "TC-10.1: expected rc=2 for unknown option, got rc=$rc_bogus"
fi

# === TC-11: make_plain_sandbox ===
echo
echo "TC-11: make_plain_sandbox → bare mktemp -d (no .git)"

sbx_plain=$(bash -c "source '$HELPERS'; make_plain_sandbox")
if [ -d "$sbx_plain" ] && [ ! -e "$sbx_plain/.git" ]; then
  outer_pass "TC-11.1: make_plain_sandbox returns a bare directory without .git"
else
  outer_fail "TC-11.1: make_plain_sandbox unexpected layout at '$sbx_plain'"
fi
rm -rf "$sbx_plain"

# Cycle 2 F-03: TC-11.2 / TC-11.3 — API symmetry with make_sandbox.
# `make_plain_sandbox` exposes the same --soft / option-parse contract; pin both contracts here
# (parallels TC-9.2 / TC-10.1 for make_sandbox).
sbx_plain_soft=$(bash -c "source '$HELPERS'; make_plain_sandbox --soft")
if [ -d "$sbx_plain_soft" ] && [ ! -e "$sbx_plain_soft/.git" ]; then
  outer_pass "TC-11.2: make_plain_sandbox --soft returns a working sandbox on success path"
else
  outer_fail "TC-11.2: make_plain_sandbox --soft unexpected layout at '$sbx_plain_soft'"
fi
rm -rf "$sbx_plain_soft"

rc_plain_bogus=0
bash -c "source '$HELPERS'; make_plain_sandbox --bogus 2>/dev/null" || rc_plain_bogus=$?
if [ "$rc_plain_bogus" = "2" ]; then
  outer_pass "TC-11.3: make_plain_sandbox --bogus returns rc=2 (option parse error)"
else
  outer_fail "TC-11.3: expected rc=2 for unknown option, got rc=$rc_plain_bogus"
fi

# Cycle 3 F-04: TC-11.4 — make_plain_sandbox --soft failure path (TC-9.2 と対称)。
# make_plain_sandbox の --soft contract は make_sandbox と同型 (mktemp 失敗時に exit ではなく
# rc=1 で return)。Mutation で `[ "$soft_fail" -eq 1 ] && return 1` を `exit 1` に書き換えると
# このテストが失敗する保証は (return/exit semantic の説明は TC-9.3 と同じ理由で subshell 経由
# のため部分的) が、少なくとも mktemp failure → rc=1 contract を pin する。
rc_plain_soft_fail=0
bash -c "source '$HELPERS'; PATH=/dev/null make_plain_sandbox --soft 2>/dev/null" || rc_plain_soft_fail=$?
if [ "$rc_plain_soft_fail" = "1" ]; then
  outer_pass "TC-11.4: make_plain_sandbox --soft returns rc=1 on mktemp failure"
else
  outer_fail "TC-11.4: expected rc=1 (soft-fail on mktemp failure), got rc=$rc_plain_soft_fail"
fi

# === TC-12: assert_grep_in_section ===
echo
echo "TC-12: assert_grep_in_section"

# TC-12 fixture: 3 sections (h3 start anchor + h2 end anchor mirrors T-2/T-3/T-4 usage pattern)
tc12_fixture=$(mktemp)
trap 'rm -f "$tc12_fixture" "$tmpfile"' EXIT
cat > "$tc12_fixture" <<'FIXTURE_EOF'
## Top heading

### Subsection Alpha
alpha-keyword
alpha-only

### Subsection Beta
beta-keyword
beta-only

## Next top heading
gamma-keyword
FIXTURE_EOF

# TC-12.1: matching pattern within bounded section → PASS
# start: h3 heading (Alpha), end: h2 heading boundary (won't match the start line itself)
grep_in_section_state=$(bash -c "
  source '$HELPERS'
  assert_grep_in_section 'match-in-alpha' '$tc12_fixture' '^### Subsection Alpha\$' '^## [^#]' 'alpha-keyword' >/dev/null
  echo \"PASS=\$PASS FAIL=\$FAIL\"
")
gp=$(echo "$grep_in_section_state" | grep -oE 'PASS=[0-9]+' | cut -d= -f2)
gf=$(echo "$grep_in_section_state" | grep -oE 'FAIL=[0-9]+' | cut -d= -f2)
if [ "$gp" = "1" ] && [ "$gf" = "0" ]; then
  outer_pass "TC-12.1: assert_grep_in_section matches pattern within bounded section"
else
  outer_fail "TC-12.1: expected PASS=1 FAIL=0 got PASS=$gp FAIL=$gf"
fi

# TC-12.2: pattern outside section (in Beta) when scoped to Alpha → FAIL with section bounds diagnostic
# Note: the awk range terminates at the next h3 (Beta) line by also matching `^### ` boundary
out_of_scope_state=$(bash -c "
  source '$HELPERS'
  assert_grep_in_section 'beta-from-alpha' '$tc12_fixture' '^### Subsection Alpha\$' '^### Subsection B' 'beta-only' 2>&1
  echo \"FAIL=\$FAIL\"
")
oof=$(echo "$out_of_scope_state" | grep -oE 'FAIL=[0-9]+' | tail -1 | cut -d= -f2)
if [ "$oof" = "1" ] && echo "$out_of_scope_state" | grep -q 'pattern not found in section'; then
  outer_pass "TC-12.2: pattern outside section fails with section-bound diagnostic"
else
  outer_fail "TC-12.2: expected FAIL=1 + 'pattern not found in section' diagnostic, got '$out_of_scope_state'"
fi

# TC-12.3: file not found → FAIL with file diagnostic
missing_file_state=$(bash -c "
  source '$HELPERS'
  assert_grep_in_section 'missing-section' '/nonexistent/xyz' '## Anything' '^## ' 'pattern' 2>&1
  echo \"FAIL=\$FAIL\"
")
mff=$(echo "$missing_file_state" | grep -oE 'FAIL=[0-9]+' | tail -1 | cut -d= -f2)
if [ "$mff" = "1" ] && echo "$missing_file_state" | grep -q 'file not found'; then
  outer_pass "TC-12.3: file-not-found path emits diagnostic and increments FAIL"
else
  outer_fail "TC-12.3: expected FAIL=1 + 'file not found' got '$missing_file_state'"
fi

# TC-12.4: empty section (start_pattern matches no line) → FAIL with empty-section diagnostic
empty_section_state=$(bash -c "
  source '$HELPERS'
  assert_grep_in_section 'never-matches' '$tc12_fixture' '^### Never Appears In Fixture$' '^## ' 'anything' 2>&1
  echo \"FAIL=\$FAIL\"
")
ess=$(echo "$empty_section_state" | grep -oE 'FAIL=[0-9]+' | tail -1 | cut -d= -f2)
if [ "$ess" = "1" ] && echo "$empty_section_state" | grep -q 'empty section'; then
  outer_pass "TC-12.4: empty section distinguished from pattern-not-found with explicit diagnostic"
else
  outer_fail "TC-12.4: expected FAIL=1 + 'empty section' diagnostic, got '$empty_section_state'"
fi

# === TC-13: assert_file_exists_or_fail ===
echo
echo "TC-13: assert_file_exists_or_fail"

# TC-13.1: file present → PASS=0 FAIL=0 RC=0 (silent guard — NOT an assertion).
# The helper is a pre-condition guard, not a positive assertion: on success it
# must remain silent so it does not inflate the PASS count of the assertions
# it protects (the real assertions invoked after `|| continue` own the PASS
# accounting). The caller's `|| continue` only depends on RC=0.
tc13_existing=$(mktemp)
trap 'rm -f "$tc13_existing" "$tc12_fixture" "$tmpfile"' EXIT
printf 'present\n' > "$tc13_existing"

present_state=$(bash -c "
  source '$HELPERS'
  if assert_file_exists_or_fail 'present-file' '$tc13_existing' >/dev/null; then
    rc=0
  else
    rc=\$?
  fi
  echo \"PASS=\$PASS FAIL=\$FAIL RC=\$rc\"
")
pp=$(echo "$present_state" | grep -oE 'PASS=[0-9]+' | cut -d= -f2)
pf=$(echo "$present_state" | grep -oE 'FAIL=[0-9]+' | cut -d= -f2)
prc=$(echo "$present_state" | grep -oE 'RC=[0-9]+' | cut -d= -f2)
if [ "$pp" = "0" ] && [ "$pf" = "0" ] && [ "$prc" = "0" ]; then
  outer_pass "TC-13.1: existing file → PASS=0 FAIL=0 RC=0 (silent guard, caller proceeds)"
else
  outer_fail "TC-13.1: expected PASS=0 FAIL=0 RC=0 got PASS=$pp FAIL=$pf RC=$prc"
fi

# TC-13.2: file missing → FAIL=1, helper returns 1, "file not found" diagnostic emitted
missing_state=$(bash -c "
  source '$HELPERS'
  if assert_file_exists_or_fail 'missing-file' '/nonexistent/path/xyz' 2>&1; then
    rc=0
  else
    rc=\$?
  fi
  echo \"PASS=\$PASS FAIL=\$FAIL RC=\$rc\"
")
mp=$(echo "$missing_state" | grep -oE 'PASS=[0-9]+' | tail -1 | cut -d= -f2)
mf=$(echo "$missing_state" | grep -oE 'FAIL=[0-9]+' | tail -1 | cut -d= -f2)
mrc=$(echo "$missing_state" | grep -oE 'RC=[0-9]+' | tail -1 | cut -d= -f2)
if [ "$mp" = "0" ] && [ "$mf" = "1" ] && [ "$mrc" = "1" ] && echo "$missing_state" | grep -q 'file not found'; then
  outer_pass "TC-13.2: missing file → FAIL=1 RC=1 + 'file not found' diagnostic (caller skips via || continue)"
else
  outer_fail "TC-13.2: expected PASS=0 FAIL=1 RC=1 + diagnostic, got PASS=$mp FAIL=$mf RC=$mrc state='$missing_state'"
fi

# Cycle 3 G-H03: TC-14 — the sandbox roots are canonicalized.
#
# The canonicalization exists because macOS puts $TMPDIR under /var/folders, a
# symlink to /private/var, while production resolves paths through git rev-parse /
# realpath — so a raw mktemp path fails every path-equality assertion. That is
# unobservable on Linux by default, which means reverting both call sites leaves
# the whole hooks suite at 103/103 and the macOS leg is `continue-on-error`. Point
# $TMPDIR at a symlink so the difference becomes visible on the blocking gate too.
#
# The fixture root itself must be canonical before it can serve as the expected
# prefix: on macOS $TMPDIR already lives under /var/folders, a symlink to
# /private/var, so a raw `mktemp -d` here would produce an uncanonical path and
# the helper's own canonicalization would resolve past it — the assertion would
# fail on exactly the platform the feature exists for.
tc14_real=$(mktemp -d) || exit 1
tc14_real=$(cd "$tc14_real" && pwd -P) || exit 1
tc14_link="${tc14_real}-link"
if ln -s "$tc14_real" "$tc14_link" 2>/dev/null; then
  sbx_canon=$(TMPDIR="$tc14_link" bash -c "source '$HELPERS'; make_plain_sandbox")
  case "$sbx_canon" in
    "$tc14_link"/*)
      outer_fail "TC-14.1: make_plain_sandbox returned an uncanonicalized path under the symlink ($sbx_canon) — pwd -P canonicalization lost?" ;;
    "$tc14_real"/*)
      outer_pass "TC-14.1: make_plain_sandbox canonicalizes the sandbox root through a symlinked TMPDIR" ;;
    *)
      outer_fail "TC-14.1: unexpected sandbox path '$sbx_canon' (expected under $tc14_real)" ;;
  esac
  rm -rf "$sbx_canon"
  sbx_canon_git=$(TMPDIR="$tc14_link" bash -c "source '$HELPERS'; make_sandbox")
  case "$sbx_canon_git" in
    "$tc14_link"/*)
      outer_fail "TC-14.2: make_sandbox returned an uncanonicalized path under the symlink ($sbx_canon_git) — pwd -P canonicalization lost?" ;;
    "$tc14_real"/*)
      outer_pass "TC-14.2: make_sandbox canonicalizes the sandbox root through a symlinked TMPDIR" ;;
    *)
      outer_fail "TC-14.2: unexpected sandbox path '$sbx_canon_git' (expected under $tc14_real)" ;;
  esac
  rm -rf "$sbx_canon_git"
  rm -f "$tc14_link"
else
  outer_fail "TC-14: could not create the symlink fixture at $tc14_link — canonicalization would go unverified"
fi
rm -rf "$tc14_real"

# Cycle 3 G-H05: TC-15 — skip() counts and print_summary reports it.
#
# Without this, dropping the `SKIP=$((SKIP + 1))` from skip() would go unnoticed:
# the ⏭️ line would still print and every suite would still be green, which is the
# exact "green says nothing about what did not run" failure skip() was added for.
skip_state=$(bash -c "source '$HELPERS'; skip TC-dummy >/dev/null; skip TC-dummy2 >/dev/null; print_summary skip-probe")
if echo "$skip_state" | grep -qx 'SKIP: 2'; then
  outer_pass "TC-15.1: skip() increments SKIP and print_summary reports it"
else
  outer_fail "TC-15.1: expected 'SKIP: 2' in print_summary output, got: $skip_state"
fi
no_skip_state=$(bash -c "source '$HELPERS'; print_summary skip-probe-zero")
if echo "$no_skip_state" | grep -q 'SKIP:'; then
  outer_fail "TC-15.2: print_summary printed a SKIP line with SKIP=0 (should be omitted): $no_skip_state"
else
  outer_pass "TC-15.2: print_summary omits the SKIP line when nothing was skipped"
fi

# === Summary ===
echo
echo "─── $(basename "$0") summary ──────────────────────"
echo "PASS: $OUTER_PASS"
echo "FAIL: $OUTER_FAIL"

if [ "$OUTER_FAIL" -ne 0 ]; then
  echo "Failed assertions:"
  for n in "${OUTER_FAILED[@]}"; do
    echo "  - $n"
  done
  exit 1
fi
exit 0
