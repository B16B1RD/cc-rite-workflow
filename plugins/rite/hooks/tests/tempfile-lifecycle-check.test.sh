#!/bin/bash
# Tests for hooks/scripts/tempfile-lifecycle-check.sh (Issue #2117)
#
# The checker is only worth having if it stays quiet on the shapes this repo
# writes on purpose, so the boundaries matter more than the detections:
#   - a derived mktemp path and a stream-headed `grep -q` are findings,
#   - a printf/echo-headed `grep -q` is not (15 of 16 call sites are that shape;
#     flagging them would bury the one real finding),
#   - the same pipeline in a file without pipefail is not,
#   - code that goes through the tempfile lib is not,
#   - and a drift-check-ignore marker suppresses either pattern.
# Plus the real-repository corpus: the tree must be clean, or the check ships
# already-noisy and gets ignored.
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

# --- T-03: both patterns are detected ---------------------------------------
cat > "$FIXTURES/bad.sh" <<'FIX'
#!/bin/bash
set -uo pipefail
FINDINGS_FILE="$(mktemp)"
PART_FILE="$FINDINGS_FILE.part"
awk '{print}' input > "$PART_FILE"
if git log --oneline | grep -q "marker"; then
  echo hit
fi
FIX
rc=$(run_on bad.sh)
assert "T-03 a fixture with both patterns exits 1" "1" "$rc"
assert_grep "T-03 mktemp-derived-path is reported with its line" "$OUT" \
  'bad\.sh:4: mktemp-derived-path'
assert_grep "T-03 pipefail-grep-q-stream names the producer" "$OUT" \
  'bad\.sh:6: pipefail-grep-q-stream .*`git`'
assert_grep "T-03 the total line is machine-readable" "$OUT" \
  '==> Total tempfile-lifecycle findings: 2'

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

# A backslash-continued pipeline must not hide its consumer from the scan.
cat > "$FIXTURES/continued.sh" <<'FIX'
#!/bin/bash
set -euo pipefail
gh api "repos/o/r/issues" \
  | jq -r '.[].number' \
  | grep -q "^42$"
FIX
rc=$(run_on continued.sh)
assert "T-03c a continued pipeline is joined before scanning" "1" "$rc"
assert_grep "T-03c the finding anchors to the first physical line" "$OUT" \
  'continued\.sh:3: pipefail-grep-q-stream'

# --- T-04: the shapes that must stay quiet ----------------------------------
cat > "$FIXTURES/printf-head.sh" <<'FIX'
#!/bin/bash
set -euo pipefail
if printf '%s\n' "$haystack" | grep -qxF -- "$needle"; then
  echo found
fi
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qE ':[0-9]+:'; then
  echo found
fi
echo "$line" | grep -q marker || true
FIX
rc=$(run_on printf-head.sh)
assert "T-04 printf/echo feeding grep -q directly is not flagged" "0" "$rc"

# The exemption is about the stage that actually dies, so an intermediate stage
# between printf and grep -q must NOT inherit printf's pass.
cat > "$FIXTURES/multi-stage.sh" <<'FIX'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$body" | head -20 | grep -qE '^ingested:' || true
FIX
rc=$(run_on multi-stage.sh)
assert "T-03d a stage between printf and grep -q is flagged" "1" "$rc"
assert_grep "T-03d the finding names the immediate producer, not the pipeline head" "$OUT" \
  'multi-stage\.sh:3: pipefail-grep-q-stream .*`head`'

cat > "$FIXTURES/no-pipefail.sh" <<'FIX'
#!/bin/bash
set -u
if git log --oneline | grep -q "marker"; then
  echo hit
fi
FIX
rc=$(run_on no-pipefail.sh)
assert "T-04b the same pipeline without pipefail is not flagged" "0" "$rc"

cat > "$FIXTURES/marker.sh" <<'FIX'
#!/bin/bash
set -euo pipefail
tmp=$(mktemp)
cp src "$tmp.orig"   # drift-check-ignore
# drift-check-ignore
if git log --oneline | grep -q "marker"; then
  echo hit
fi
FIX
rc=$(run_on marker.sh)
assert "T-04c drift-check-ignore suppresses both on-line and line-above" "0" "$rc"

# Two handles from the lib, neither derived. The fixture has to make the checker
# actually track something — a file with no tracked handle at all would pass
# under any implementation, including one that flags every derived path.
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
assert "T-04d two lib handles used without derivation are not flagged" "0" "$rc"

# Negative control for the above: the same lib handle, derived. If the checker
# stopped tracking lib handles, T-04d would still pass but this would not.
cat > "$FIXTURES/lib-derived.sh" <<'FIX'
#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/tempfile.sh"
rite_tempfile_init
rite_tempfile_new tmp "check-tmp" || exit 2
awk '{print}' input > "$tmp.part"
FIX
rc=$(run_on lib-derived.sh)
assert "T-03e a path derived from a lib handle is flagged" "1" "$rc"
assert_grep "T-03e the finding names the lib handle" "$OUT" \
  'lib-derived\.sh:6: mktemp-derived-path .*\$tmp'

# The spellings that a raw-mktemp-only regex would miss.
cat > "$FIXTURES/suffix-forms.sh" <<'FIX'
#!/bin/bash
tmp=$(mktemp)
cp src "$tmp-1"
cp src "${tmp}_bak"
cp src "$tmp".part
FIX
rc=$(run_on suffix-forms.sh)
assert "T-03f dash / braced-underscore / quote-then-dot forms are all flagged" "1" "$rc"
assert_grep "T-03f \$tmp-1 is a finding" "$OUT" 'suffix-forms\.sh:3: mktemp-derived-path'
assert_grep "T-03f \${tmp}_bak is a finding" "$OUT" 'suffix-forms\.sh:4: mktemp-derived-path'
assert_grep "T-03f \"\$tmp\".part is a finding" "$OUT" 'suffix-forms\.sh:5: mktemp-derived-path'

# A sibling variable that merely shares a prefix is not a derivation: bash reads
# `$tmp_err` as one name, so flagging it would fire on ordinary code.
cat > "$FIXTURES/prefix-sibling.sh" <<'FIX'
#!/bin/bash
tmp=$(mktemp)
tmp_err=$(mktemp)
some_cmd 2>"$tmp_err" > "$tmp"
FIX
rc=$(run_on prefix-sibling.sh)
assert "T-04f a variable sharing a prefix is not treated as a derivation" "0" "$rc"

# `x=$(mktemp 2>/dev/null) || x=""` is the sanctioned stderr-slot idiom at 88
# sites in this repo; a warning there would be noise, so it is out of contract.
cat > "$FIXTURES/silenced-idiom.sh" <<'FIX'
#!/bin/bash
set -uo pipefail
jq_err=$(mktemp 2>/dev/null) || jq_err=""
jq . input 2>"${jq_err:-/dev/null}"
FIX
rc=$(run_on silenced-idiom.sh)
assert "T-04e the silenced stderr-slot idiom is deliberately out of contract" "0" "$rc"

# --- Real repository corpus: the check must ship clean ----------------------
# Neither --quiet nor --skip-if-no-target here. Both would let "scanned nothing"
# satisfy the same two assertions as "scanned everything and found nothing": the
# flag turns a missing scan dir into exit 0 with a zero count, and --quiet hides
# the line that says how many files were read. The scan dirs always exist in this
# repo, so their absence should fail loudly.
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
  'Scanning [1-9][0-9]* file\(s\)'

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
unscannable_err="$(bash "$SCRIPT" --repo-root "$SANDBOX" --quiet --target no/such/file.sh 2>&1 >/dev/null || true)"
printf '%s' "$unscannable_err" > "$SANDBOX/unscannable.txt"
assert_grep "the unscannable run says so explicitly" "$SANDBOX/unscannable.txt" \
  'not a clean bill'
# Findings still win the exit code, so a normal detection run is not reported to
# lint as an invocation error.
assert "findings win over unscannable (exit 1, not 2)" "1" \
  "$(bash "$SCRIPT" --repo-root "$SANDBOX" --quiet --target plugins/rite/hooks/scripts/bad.sh --target no/such/file.sh >/dev/null 2>&1; echo $?)"

print_summary "$(basename "$0")"
