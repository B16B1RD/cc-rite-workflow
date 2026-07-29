#!/bin/bash
# Tests for hooks/scripts/dollar-zero-check.sh (Issue #2046)
#
# The checker exists because the Skill loader expands parameter-zero references
# in a skill body to the invocation argument string — including inside fenced
# code blocks. These tests pin the three boundaries that decide whether the
# check is usable at all:
#   - a reference inside a fence is a finding (the defect),
#   - a reference in prose outside every fence is not (explaining the parameter
#     must stay possible — this test file's own header does it),
#   - a real shell script is never scanned (every hooks/*.sh would false-positive).
# Plus the unbalanced-fence contract: skip the file loudly rather than emit
# findings from a block structure that could not be parsed.
#
# Convention: mktemp sandbox, no network, no gh, GNU/BSD portable. The checker
# resolves targets under --repo-root, so no git repo is needed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

SCRIPT="$SCRIPT_DIR/../scripts/dollar-zero-check.sh"

echo "=== dollar-zero-check.sh tests ==="

if [ ! -f "$SCRIPT" ]; then
  echo "ERROR: $SCRIPT not found" >&2
  exit 1
fi

SANDBOX="$(make_plain_sandbox)"
# Second sandbox stands in for a consumer repo that installs rite from the
# marketplace and has no plugins/rite/ tree of its own. Created up front so the
# trap owns both — a bare `rm -rf` at the end of the file leaks it on any signal.
CONSUMER_SANDBOX="$(make_plain_sandbox)"
cleanup() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
  [ -n "${CONSUMER_SANDBOX:-}" ] && rm -rf "$CONSUMER_SANDBOX"
}
trap 'rc=$?; cleanup; exit $rc' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

# The literal is assembled at runtime so the fixtures below carry a real
# parameter-zero reference without this file tripping the check it tests.
DOLLAR='$'
P0="${DOLLAR}0"
P0_BRACE="${DOLLAR}{0}"
P0_SUFFIX="${DOLLAR}{0##*/}"

REPO_ROOT="$(_helpers_resolve_repo_root "$SCRIPT_DIR")"

mkdir -p "$SANDBOX/plugins/rite/skills/demo" "$SANDBOX/plugins/rite/hooks/scripts"

# --- Fixtures ----------------------------------------------------------------
# Fenced bash carrying the defect: the awk condition breaks when the loader
# rewrites the reference to the invocation arguments.
printf 'Prose line.\n\n```bash\nawk -v k="$key" '\''%s ~ "^" k { print }'\''\n```\n' "$P0" \
  > "$SANDBOX/plugins/rite/skills/demo/ng-fenced.md"

# Same defect in brace form — the loader treats both spellings alike.
printf '```bash\necho "%s"\n```\n' "$P0_BRACE" \
  > "$SANDBOX/plugins/rite/skills/demo/ng-brace.md"

# Brace form with a modifier. The loader rewrites this exactly like the two
# unmodified spellings, so a pattern that only matched `$0` and `${0}` would let
# it through while reading as if it were covered.
printf '```bash\nname=%s\n```\n' "$P0_SUFFIX" \
  > "$SANDBOX/plugins/rite/skills/demo/ng-brace-suffix.md"

# A fence with no info string is just as vulnerable as a bash one; tagging the
# fence differently must not buy an exemption.
printf '```\nprintf "%%s" "%s"\n```\n' "$P0" \
  > "$SANDBOX/plugins/rite/skills/demo/ng-untagged.md"

# Prose mention outside any fence — the documented safe way to talk about it.
printf 'The Skill loader expands %s in the body to the invocation arguments.\n\n```bash\necho ok\n```\n' "$P0" \
  > "$SANDBOX/plugins/rite/skills/demo/clean-prose.md"

# Indented fence-looking literal inside an awk program: 4+ spaces of indent means
# it is code, not a fence, so the block must stay open and the check must not
# start treating the rest of the file as prose.
printf '```bash\nawk %s\n    if (line ~ /^```json/) next\n%s file\n```\n' "'" "'" \
  > "$SANDBOX/plugins/rite/skills/demo/clean-indented-fence-literal.md"

# Unbalanced fence: opened, never closed.
printf 'Prose.\n\n```bash\necho "%s"\n' "$P0" \
  > "$SANDBOX/plugins/rite/skills/demo/ng-unbalanced.md"

# Content-driven desync: a bare unindented fence line inside a fenced block
# closes it early (a closing fence carries no info string), so the reference on
# the next line is read as prose and the file ends with an open fence. This is
# the failure mode that costs a real finding, and it is the reason an
# unscannable file must not exit 0.
printf '```bash\necho x\n```\n%s\n```\n' "$P0" \
  > "$SANDBOX/plugins/rite/skills/demo/ng-unindented-fence-literal.md"

# The same shape but with an info string on the inner fence does NOT close the
# block — the reference stays inside and is found normally. Pinning both halves
# keeps a future relaxation of the closing rule from silently swallowing
# findings in blocks that quote fenced JSON.
printf '```bash\nawk %s\n```json\n%s\n```\n' "'" "$P0" \
  > "$SANDBOX/plugins/rite/skills/demo/ng-inner-tagged-fence.md"

# Byte-identical content placed on each side of the scan boundary. Asserting the
# pair is what verifies the exclusion: a single `.sh` fixture returning rc=0
# proves nothing, because a fixture whose reference sits outside any fence would
# also return rc=0 no matter how wide the scan set became.
EXCLUSION_BODY=$(printf '```bash\necho "%s"\n```\n' "$P0")
printf '%s\n' "$EXCLUSION_BODY" > "$SANDBOX/plugins/rite/skills/demo/exclusion-probe.md"
printf '%s\n' "$EXCLUSION_BODY" > "$SANDBOX/plugins/rite/hooks/scripts/exclusion-probe.sh"

# Real shell script carrying the same idiom — immune, because bash executes the
# file directly and the loader never sees it.
printf '#!/usr/bin/env bash\necho "invoked as %s"\n' "$P0" \
  > "$SANDBOX/plugins/rite/hooks/scripts/real-script.sh"

run() { bash "$SCRIPT" --repo-root "$SANDBOX" "$@" >/dev/null 2>&1; echo $?; }

# --- Invocation contract ------------------------------------------------------
assert "--help exits 0" "0" "$(bash "$SCRIPT" --help >/dev/null 2>&1; echo $?)"
assert "no targets exits 2 (invocation error)" "2" "$(run --quiet)"
assert "unknown argument exits 2" "2" "$(run --bogus)"

# --- T-04: detection + line number --------------------------------------------
assert "fenced reference detected (exit 1)" "1" \
  "$(run --quiet --target plugins/rite/skills/demo/ng-fenced.md)"
assert "brace form detected (exit 1)" "1" \
  "$(run --quiet --target plugins/rite/skills/demo/ng-brace.md)"
assert "brace form with modifier detected (exit 1)" "1" \
  "$(run --quiet --target plugins/rite/skills/demo/ng-brace-suffix.md)"
assert "untagged fence detected (exit 1)" "1" \
  "$(run --quiet --target plugins/rite/skills/demo/ng-untagged.md)"

ng_out="$(bash "$SCRIPT" --repo-root "$SANDBOX" --quiet \
  --target plugins/rite/skills/demo/ng-fenced.md 2>/dev/null || true)"
if printf '%s' "$ng_out" | grep -qF '[dollar-zero]'; then
  pass "finding is tagged [dollar-zero]"
else
  fail "finding tag missing: $ng_out"
fi
if printf '%s' "$ng_out" | grep -qF 'ng-fenced.md:4:'; then
  pass "finding carries file path and line number"
else
  fail "finding lacks file:line — got: $ng_out"
fi
if printf '%s' "$ng_out" | grep -qF 'helper script'; then
  pass "finding states the fix direction (helper script)"
else
  fail "finding lacks fix direction — got: $ng_out"
fi

# --- T-06: prose outside a fence is not a finding ------------------------------
assert "prose mention outside a fence is clean (exit 0)" "0" \
  "$(run --quiet --target plugins/rite/skills/demo/clean-prose.md)"

# --- Indented fence literal does not desynchronize fence tracking --------------
assert "indented fence-looking literal stays inside the block (exit 0)" "0" \
  "$(run --quiet --target plugins/rite/skills/demo/clean-indented-fence-literal.md)"

# --- T-08: unbalanced fence -> WARNING + not-a-clean-bill ---------------------
# rc=2, not 0: the caller (/rite:lint Phase 3.5) reads only the exit code, maps 0
# to success, and does not surface stderr for a successful check. Returning 0
# here would report "scanned, found nothing" for a file that was never scanned.
assert "unbalanced fence exits 2 (not scanned != clean)" "2" \
  "$(run --quiet --target plugins/rite/skills/demo/ng-unbalanced.md)"
unbalanced_err="$(bash "$SCRIPT" --repo-root "$SANDBOX" --quiet \
  --target plugins/rite/skills/demo/ng-unbalanced.md 2>&1 >/dev/null || true)"
if printf '%s' "$unbalanced_err" | grep -qF 'unbalanced code fence'; then
  pass "unbalanced fence emits a WARNING naming the cause"
else
  fail "unbalanced fence WARNING missing — got: $unbalanced_err"
fi
if printf '%s' "$unbalanced_err" | grep -qF 'could not be scanned'; then
  pass "unscannable file is called out as not a clean bill"
else
  fail "unscannable ERROR line missing — got: $unbalanced_err"
fi

# Content-driven desync produces the same outcome. Without this case the suite
# only pins the indented literal, whose whole point is that it does NOT desync.
assert "unindented bare fence desyncs the block and exits 2" "2" \
  "$(run --quiet --target plugins/rite/skills/demo/ng-unindented-fence-literal.md)"
assert "inner fence with an info string does not close the block (exit 1)" "1" \
  "$(run --quiet --target plugins/rite/skills/demo/ng-inner-tagged-fence.md)"

# --- T-05: real shell scripts are outside the scan set ------------------------
# Byte-identical content on each side of the boundary, asserted as a pair. The
# `.md` copy must be a finding; the `.sh` copy carries its reference *inside* a
# fence, so if --all ever scanned hooks/scripts/ it would necessarily report it.
# That is what makes the rc=0 below evidence of exclusion rather than a tautology
# — unlike a fixture whose reference sits outside any fence, which returns 0 no
# matter how wide the scan set grows.
assert "exclusion probe under skills/ is a finding (exit 1)" "1" \
  "$(run --quiet --target plugins/rite/skills/demo/exclusion-probe.md)"
rm -f "$SANDBOX/plugins/rite/skills/demo/ng-fenced.md" \
      "$SANDBOX/plugins/rite/skills/demo/ng-brace.md" \
      "$SANDBOX/plugins/rite/skills/demo/ng-brace-suffix.md" \
      "$SANDBOX/plugins/rite/skills/demo/ng-untagged.md" \
      "$SANDBOX/plugins/rite/skills/demo/ng-unbalanced.md" \
      "$SANDBOX/plugins/rite/skills/demo/ng-unindented-fence-literal.md" \
      "$SANDBOX/plugins/rite/skills/demo/ng-inner-tagged-fence.md" \
      "$SANDBOX/plugins/rite/skills/demo/exclusion-probe.md"
assert "--all leaves the fenced .sh copy unscanned (exit 0)" "0" "$(run --quiet --all)"

# --- awk failure: the third route to rc=2 -------------------------------------
# The script's header justifies moving its own unbalanced-fence sentinel to
# exit 3 by saying it keeps the awk-failure branch from being dead code. Without
# a case that reaches that branch, the justification is unverified — and
# deleting its SKIPPED increment makes an unreadable file report rc=0, the very
# "did not look, reported clean" outcome this checker exists to prevent.
if [ "$(id -u)" -eq 0 ]; then
  skip "unreadable file exits 2 (running as root: chmod 000 does not deny access)"
else
  printf '```bash\necho ok\n```\n' > "$SANDBOX/plugins/rite/skills/demo/unreadable.md"
  chmod 000 "$SANDBOX/plugins/rite/skills/demo/unreadable.md"
  assert "unreadable file exits 2 (awk failure route)" "2" \
    "$(run --quiet --target plugins/rite/skills/demo/unreadable.md)"
  unreadable_err="$(bash "$SCRIPT" --repo-root "$SANDBOX" --quiet \
    --target plugins/rite/skills/demo/unreadable.md 2>&1 >/dev/null || true)"
  if printf '%s' "$unreadable_err" | grep -qF 'awk failed on'; then
    pass "awk failure is reported distinctly from the fence sentinel"
  else
    fail "awk failure WARNING missing — got: $unreadable_err"
  fi
  chmod 644 "$SANDBOX/plugins/rite/skills/demo/unreadable.md"
  rm -f "$SANDBOX/plugins/rite/skills/demo/unreadable.md"
fi

# --- Missing target is reported, not silently passed --------------------------
assert "missing --target exits 2 (per the documented contract)" "2" \
  "$(run --quiet --target plugins/rite/skills/demo/does-not-exist.md)"
missing_err="$(bash "$SCRIPT" --repo-root "$SANDBOX" --quiet \
  --target plugins/rite/skills/demo/does-not-exist.md 2>&1 >/dev/null || true)"
if printf '%s' "$missing_err" | grep -qF 'target not found'; then
  pass "missing --target is reported as a WARNING"
else
  fail "missing --target produced no WARNING — got: $missing_err"
fi

# --- Count line format and --quiet contract (both read by /rite:lint row 17) ---
# lint extracts the finding count with `Total dollar-zero findings: (\d+)` and
# defaults to 0 when the regex misses, so a wording change would surface as an
# innocuous-looking "warning (0 findings)" rather than as a failure.
count_out="$(bash "$SCRIPT" --repo-root "$SANDBOX" \
  --target plugins/rite/skills/demo/clean-prose.md 2>&1 >/dev/null || true)"
if printf '%s' "$count_out" | grep -qE 'Total dollar-zero findings: [0-9]+'; then
  pass "count line matches the regex /rite:lint parses"
else
  fail "count line format drifted — got: $count_out"
fi
quiet_out="$(bash "$SCRIPT" --repo-root "$SANDBOX" --quiet \
  --target plugins/rite/skills/demo/clean-prose.md 2>&1 || true)"
if printf '%s' "$quiet_out" | grep -qF 'Total dollar-zero findings:'; then
  fail "--quiet leaked the count line — got: $quiet_out"
else
  pass "--quiet suppresses the count line"
fi

# --- Real repository corpus: the regression this check exists to catch ---------
# Every other assertion runs against a synthetic sandbox, so a reference
# reintroduced into a real skill body would be invisible to this suite.
assert "real repo skills/ tree is clean (exit 0)" "0" \
  "$(bash "$SCRIPT" --repo-root "$REPO_ROOT" --quiet --all --skip-if-no-target >/dev/null 2>&1; echo $?)"
real_repo_err="$(bash "$SCRIPT" --repo-root "$REPO_ROOT" --quiet --all --skip-if-no-target 2>&1 >/dev/null || true)"
if printf '%s' "$real_repo_err" | grep -qF 'unbalanced code fence'; then
  fail "real repo has an unscannable file — coverage is silently reduced: $real_repo_err"
else
  pass "no file in the real repo is skipped for an unbalanced fence"
fi

# --- --skip-if-no-target contract ---------------------------------------------
assert "--all without a scan dir exits 2 by default" "2" \
  "$(bash "$SCRIPT" --repo-root "$CONSUMER_SANDBOX" --quiet --all >/dev/null 2>&1; echo $?)"
assert "--skip-if-no-target turns that into a clean skip (exit 0)" "0" \
  "$(bash "$SCRIPT" --repo-root "$CONSUMER_SANDBOX" --quiet --all --skip-if-no-target >/dev/null 2>&1; echo $?)"

print_summary "$(basename "$0")"
