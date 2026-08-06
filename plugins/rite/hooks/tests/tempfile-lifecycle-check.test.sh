#!/bin/bash
# Tests for hooks/scripts/tempfile-lifecycle-check.sh
#
# The checker is only worth having if it stays quiet on the shapes this repo
# writes on purpose, so the boundaries matter more than the detections:
#   - a path derived from a handle is a finding, whether the handle came from
#     mktemp directly or from the lib,
#   - a variable that merely shares a prefix is not (bash reads `$tmp_err` as one
#     name, so flagging it fires on ordinary code),
#   - dirname / basename expansions are not (they extract a component, they do
#     not derive a sibling),
#   - a drift-check-ignore marker suppresses either way,
#   - and a file that could not be scanned is an error, not a clean bill.
# Plus the real-repository corpus: the tree must be clean AND actually scanned,
# or the check ships already-noisy or silently looking at nothing.
#
# Convention: mktemp sandbox, no network, no gh, GNU/BSD portable. The checker
# resolves targets under --repo-root, so no git repo is needed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

SCRIPT="$SCRIPT_DIR/../scripts/tempfile-lifecycle-check.sh"
REPO_ROOT="$(_helpers_resolve_repo_root "$SCRIPT_DIR")"

echo "=== tempfile-lifecycle-check.sh tests ==="

if [ ! -f "$SCRIPT" ]; then
  echo "ERROR: $SCRIPT not found" >&2
  exit 1
fi

SANDBOX="$(make_plain_sandbox)"
# Stands in for a consumer repo that installs rite from the marketplace and has
# no plugins/rite tree of its own.
CONSUMER_SANDBOX="$(make_plain_sandbox)"
cleanup() {
  [ -n "${SANDBOX:-}" ] && chmod -R u+rwX "$SANDBOX" 2>/dev/null
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
  [ -n "${CONSUMER_SANDBOX:-}" ] && rm -rf "$CONSUMER_SANDBOX"
}
trap 'rc=$?; cleanup; exit $rc' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

FIXTURES="$SANDBOX/plugins/rite/hooks/scripts"
mkdir -p "$FIXTURES"
OUT="$SANDBOX/out.txt"

# Run the checker over one fixture and leave its stdout in $OUT. Echoes the exit code.
run_on() {
  bash "$SCRIPT" --repo-root "$SANDBOX" --quiet --target "plugins/rite/hooks/scripts/$1" >"$OUT" 2>"$SANDBOX/err.txt"
  echo $?
}

# --- T-03: the pattern is detected ------------------------------------------
cat > "$FIXTURES/bad.sh" <<'FIX'
#!/bin/bash
FINDINGS_FILE="$(mktemp)"
PART_FILE="$FINDINGS_FILE.part"
awk '{print}' input > "$PART_FILE"
FIX
rc=$(run_on bad.sh)
assert "T-03 a derived path is a finding (exit 1)" "1" "$rc"
assert_grep "T-03 the finding carries file and line" "$OUT" \
  'bad\.sh:3: mktemp-derived-path'
assert_grep "T-03 the total line is machine-readable" "$OUT" \
  '==> Total tempfile-lifecycle findings: 1'

# The derived forms the Wiki page enumerates, each on its own line.
cat > "$FIXTURES/derived-forms.sh" <<'FIX'
#!/bin/bash
tmp=$(mktemp)
cp src "${tmp}.orig"
sort "$tmp" > "${tmp%.tmp}.sorted"
FIX
rc=$(run_on derived-forms.sh)
assert "T-03b brace and prefix-strip derived forms are both detected" "1" "$rc"
assert_grep "T-03b \${tmp}.orig is a finding" "$OUT" 'derived-forms\.sh:3: mktemp-derived-path'
assert_grep "T-03b \${tmp%...} is a finding" "$OUT" 'derived-forms\.sh:4: mktemp-derived-path'

# A handle taken from the lib must be tracked too — that is the spelling
# coding-principles.md mandates, so leaving it untracked would put the
# recommended form in the blind spot.
cat > "$FIXTURES/lib-derived.sh" <<'FIX'
#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/tempfile.sh"
rite_tempfile_init
rite_tempfile_new tmp "check-tmp" || exit 2
awk '{print}' input > "$tmp.part"
FIX
rc=$(run_on lib-derived.sh)
assert "T-03c a path derived from a lib handle is flagged" "1" "$rc"
assert_grep "T-03c the finding names the lib handle" "$OUT" \
  'lib-derived\.sh:6: mktemp-derived-path .*\$tmp'

# The spellings that a narrower regex would miss, including the quoted forms.
cat > "$FIXTURES/suffix-forms.sh" <<'FIX'
#!/bin/bash
tmp=$(mktemp)
cp src "$tmp-1"
cp src "${tmp}_bak"
cp src "$tmp".part
cp src "$tmp"_bak
cp src "${tmp}".part
cp src "${tmp}"-1
echo "${tmp##*/}.log"
cp src "${tmp%/*}/planted"
FIX
rc=$(run_on suffix-forms.sh)
assert "T-03d dash / braced / quoted derived forms are all flagged" "1" "$rc"
assert_grep "T-03d \$tmp-1 is a finding" "$OUT" 'suffix-forms\.sh:3: mktemp-derived-path'
assert_grep "T-03d \${tmp}_bak is a finding" "$OUT" 'suffix-forms\.sh:4: mktemp-derived-path'
assert_grep "T-03d \"\$tmp\".part is a finding" "$OUT" 'suffix-forms\.sh:5: mktemp-derived-path'
assert_grep "T-03d \"\$tmp\"_bak is a finding" "$OUT" 'suffix-forms\.sh:6: mktemp-derived-path'
# Quoting the braces must not change the verdict. Treating `"${tmp}".part`
# differently from `"$tmp".part` is the asymmetry this row exists to hold shut.
assert_grep "T-03d \"\${tmp}\".part is a finding" "$OUT" 'suffix-forms\.sh:7: mktemp-derived-path'
assert_grep "T-03d \"\${tmp}\"-1 is a finding" "$OUT" 'suffix-forms\.sh:8: mktemp-derived-path'
# A component extraction with a suffix bolted on is a sibling path by any
# reading, so the dirname / basename spellings get no carve-out.
assert_grep "T-03d \"\${tmp##*/}.log\" is a finding" "$OUT" 'suffix-forms\.sh:9: mktemp-derived-path'
assert_grep "T-03d \"\${tmp%/*}/planted\" is a finding" "$OUT" 'suffix-forms\.sh:10: mktemp-derived-path'

# Backslash continuation must not hide a derived path from the scan.
cat > "$FIXTURES/continued.sh" <<'FIX'
#!/bin/bash
tmp=$(mktemp)
cp src \
  "$tmp.part"
FIX
rc=$(run_on continued.sh)
assert "T-03e a continued line is joined before scanning" "1" "$rc"
assert_grep "T-03e the finding anchors to the first physical line" "$OUT" \
  'continued\.sh:3: mktemp-derived-path'

# --- T-04: the shapes that must stay quiet ----------------------------------
# Two handles, neither derived. The fixture must make the checker actually track
# something — a file with no handle at all would pass under any implementation.
cat > "$FIXTURES/lib-user.sh" <<'FIX'
#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/tempfile.sh"
rite_tempfile_init
rite_tempfile_new findings "check-findings" || exit 2
rite_tempfile_new part "check-part" || exit 2
awk '{print}' input > "$part"
cat "$part" >> "$findings"
FIX
rc=$(run_on lib-user.sh)
assert "T-04 two lib handles used without derivation are not flagged" "0" "$rc"

# bash reads `$tmp_err` as one name, so a sibling sharing a prefix is a separate
# variable, not a derivation.
cat > "$FIXTURES/prefix-sibling.sh" <<'FIX'
#!/bin/bash
tmp=$(mktemp)
tmp_err=$(mktemp)
some_cmd 2>"$tmp_err" > "$tmp"
echo "wrote to $tmp."
printf "wrote %s" "${tmp}."
FIX
rc=$(run_on prefix-sibling.sh)
assert "T-04b a prefix-sharing variable and a trailing-dot sentence are not flagged" "0" "$rc"

cat > "$FIXTURES/marker.sh" <<'FIX'
#!/bin/bash
tmp=$(mktemp)
cp src "$tmp.orig"   # drift-check-ignore
# drift-check-ignore
cp src "$tmp.bak"
FIX
rc=$(run_on marker.sh)
assert "T-04d drift-check-ignore suppresses both on-line and line-above" "0" "$rc"

# A handle named only in a comment must not seed state — otherwise a usage
# example in a docstring makes every unrelated `$x.log` in the file a finding.
cat > "$FIXTURES/comment-only.sh" <<'FIX'
#!/bin/bash
# Usage example: out=$(mktemp) then write to "$out.part"
out="$1"
cp src "$out.bak"
FIX
rc=$(run_on comment-only.sh)
assert "T-04e a handle mentioned only in a comment does not seed the registry" "0" "$rc"

# `x=$(mktemp 2>/dev/null) || x=""` is the sanctioned stderr-slot idiom; a
# warning there would be noise at a volume that gets the whole check ignored.
cat > "$FIXTURES/silenced-idiom.sh" <<'FIX'
#!/bin/bash
jq_err=$(mktemp 2>/dev/null) || jq_err=""
jq . input 2>"${jq_err:-/dev/null}"
FIX
rc=$(run_on silenced-idiom.sh)
assert "T-04f the silenced stderr-slot idiom is deliberately out of contract" "0" "$rc"

# --- Real repository corpus: clean AND actually scanned ---------------------
# Neither --quiet nor --skip-if-no-target here. Both would let "scanned nothing"
# satisfy the same assertions as "scanned everything and found nothing".
real_rc=$(bash "$SCRIPT" --repo-root "$REPO_ROOT" --all >"$SANDBOX/real.txt" 2>"$SANDBOX/real_err.txt"; echo $?)
if [ "$real_rc" -ne 0 ]; then
  fail "real repo tree has findings or unscannable files — the check would ship already-noisy:"
  cat "$SANDBOX/real.txt"
  cat "$SANDBOX/real_err.txt"
else
  pass "real repo hooks/ and scripts/ trees are clean (exit 0)"
fi
assert_grep "real repo run emits the count line" "$SANDBOX/real.txt" \
  '==> Total tempfile-lifecycle findings: 0'
assert_grep "real repo run actually scanned files (not a zero-target no-op)" "$SANDBOX/real_err.txt" \
  'Scanning [0-9][0-9]+ file\(s\)'
# Both scan dirs must be walked. Asserting a file under the second dir is
# *scannable* proves nothing — `--all --target x` is satisfied by the explicit
# target alone, so narrowing SCAN_DIRS to the first dir leaves it green. Plant a
# real defect under the second dir inside the sandbox and require the walk to
# surface it: that fails the moment the dir drops out of the list.
mkdir -p "$SANDBOX/plugins/rite/scripts"
cat > "$SANDBOX/plugins/rite/scripts/zz-planted.sh" <<'FIX'
#!/bin/bash
tmp=$(mktemp)
cp src "$tmp.part"
FIX
walk_rc=$(bash "$SCRIPT" --repo-root "$SANDBOX" --all >"$SANDBOX/walk.txt" 2>/dev/null; echo $?)
assert "--all walks the second scan dir too (exit 1 from the planted defect)" "1" "$walk_rc"
assert_grep "the finding under plugins/rite/scripts/ is reported" "$SANDBOX/walk.txt" \
  'plugins/rite/scripts/zz-planted\.sh:3: mktemp-derived-path'
rm -f "$SANDBOX/plugins/rite/scripts/zz-planted.sh"

# --- CLI contract ------------------------------------------------------------
assert "--all without a scan dir exits 2 by default" "2" \
  "$(bash "$SCRIPT" --repo-root "$CONSUMER_SANDBOX" --quiet --all >/dev/null 2>&1; echo $?)"
assert "--skip-if-no-target turns that into a clean skip" "0" \
  "$(bash "$SCRIPT" --repo-root "$CONSUMER_SANDBOX" --quiet --all --skip-if-no-target >/dev/null 2>&1; echo $?)"
assert "an unknown argument exits 2" "2" \
  "$(bash "$SCRIPT" --repo-root "$SANDBOX" --nope >/dev/null 2>&1; echo $?)"
assert "no targets at all exits 2" "2" \
  "$(bash "$SCRIPT" --repo-root "$SANDBOX" --quiet >/dev/null 2>&1; echo $?)"
assert "--target with no value exits 2 instead of scanning an empty path" "2" \
  "$(bash "$SCRIPT" --repo-root "$SANDBOX" --quiet --target >/dev/null 2>&1; echo $?)"
assert "--repo-root with no value exits 2 instead of falling back to cwd" "2" \
  "$(bash "$SCRIPT" --quiet --repo-root >/dev/null 2>&1; echo $?)"

# --- Unscannable files are an error, not a clean bill -----------------------
assert "a missing --target exits 2 (did not look != found nothing)" "2" \
  "$(bash "$SCRIPT" --repo-root "$SANDBOX" --quiet --target no/such/file.sh >/dev/null 2>&1; echo $?)"
bash "$SCRIPT" --repo-root "$SANDBOX" --quiet --target no/such/file.sh >/dev/null 2>"$SANDBOX/unscannable.txt" || true
assert_grep "the unscannable run says so explicitly" "$SANDBOX/unscannable.txt" \
  'not a clean bill'
# Findings win the exit code, so a normal detection run is not reported to lint
# as an invocation error.
assert "findings win over unscannable (exit 1, not 2)" "1" \
  "$(bash "$SCRIPT" --repo-root "$SANDBOX" --quiet --target plugins/rite/hooks/scripts/bad.sh --target no/such/file.sh >/dev/null 2>&1; echo $?)"

# An unreadable directory under --all must reach the exit code, not just stderr.
# The lint check table calls this script with --all and nothing else, so a walk
# that silently lost files is the whole "clean bill" failure mode.
#
# The sandbox is a fresh one, not $SANDBOX: with findings present, exit 1 wins
# regardless of what the walk lost, so the assertion could not fail. Nothing
# clean here but the unreadable dir, which makes exit 2 the only way through.
CLEAN_SANDBOX="$(make_plain_sandbox)"
mkdir -p "$CLEAN_SANDBOX/plugins/rite/hooks/scripts"
printf '%s\n' '#!/bin/bash' 'echo fine' > "$CLEAN_SANDBOX/plugins/rite/hooks/scripts/ok.sh"
UNREADABLE="$CLEAN_SANDBOX/plugins/rite/hooks/scripts/locked"
mkdir -p "$UNREADABLE"
cp "$FIXTURES/bad.sh" "$UNREADABLE/inner.sh"
if chmod 000 "$UNREADABLE" 2>/dev/null && [ ! -r "$UNREADABLE" ]; then
  all_rc=$(bash "$SCRIPT" --repo-root "$CLEAN_SANDBOX" --quiet --all >/dev/null 2>"$CLEAN_SANDBOX/all_err.txt"; echo $?)
  assert "--all with an unreadable directory exits 2, not a clean 0" "2" "$all_rc"
  # Split, not alternated: the WARNING alone is satisfied by a walk that reports
  # the failure and still counts nothing, which is the bug this row guards.
  assert_grep "--all names the failed enumeration" "$CLEAN_SANDBOX/all_err.txt" \
    'enumeration failed'
  assert_grep "--all counts it as unscannable rather than a clean bill" "$CLEAN_SANDBOX/all_err.txt" \
    'not a clean bill'
  chmod 755 "$UNREADABLE" 2>/dev/null
else
  skip "--all unreadable-directory case (chmod 000 not effective, likely running as root)"
  chmod 755 "$UNREADABLE" 2>/dev/null
fi
rm -rf "$CLEAN_SANDBOX"

print_summary "$(basename "$0")"
