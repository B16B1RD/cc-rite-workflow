#!/bin/bash
# Contract tests for the /rite:open Projects Status verification gate
#
# Verifies:
#   T-01: ステップ 2.4(A) emits a machine-readable [CONTEXT] PROJECTS_STATUS= marker
#   T-02: a detection path for "2.4(A) did not land" exists at ステップ 2.6, and the gate
#         rides in the same bash block as the flow-state set (so skipping 2.4(A) cannot
#         also skip its own post-condition)
#   T-03: the gate never blocks open — statically (the SKILL routing keeps going) and
#         behaviorally (a failing gh still exits 0 and reports `unknown`, never `ok`)
#   T-02b also covers the terminal Status `Cancelled`: the verdict stays `missing`, and the
#         diagnostic names the abandonment instead of a dropped Status transition
#
# Usage: bash plugins/rite/hooks/tests/open-projects-status-gate-contract.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
OPEN_MD="$REPO_ROOT/plugins/rite/skills/open/SKILL.md"
GATE_SH="$REPO_ROOT/plugins/rite/hooks/scripts/projects-status-gate.sh"

PASS=0
FAIL=0
FAILURES=()

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); FAILURES+=("$1"); echo "  ✗ $1" >&2; }

assert_file_contains() {
  local file="$1" pattern="$2" description="$3"
  if grep -qE -e "$pattern" "$file"; then pass "$description"; else fail "$description (pattern: $pattern)"; fi
}

echo "=== open Projects Status gate contract ==="

for f in "$OPEN_MD" "$GATE_SH"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: $f not found" >&2
    exit 1
  fi
done

echo ""
echo "[T-01] 2.4(A) emits a machine-readable result marker"
assert_file_contains "$OPEN_MD" '\[CONTEXT\] PROJECTS_STATUS=\$status_result' \
  "open ステップ 2.4(A) emits [CONTEXT] PROJECTS_STATUS= carrying the helper result"
# The marker must carry the helper's own result variable, not a literal — a hardcoded
# value would report success for every branch including `failed`.
assert_file_contains "$OPEN_MD" 'status_result=\$\(printf' \
  "the emitted value comes from the projects-status-update.sh result, not a literal"
# `// "failed"` only fires when jq is handed JSON. Empty or non-JSON stdout leaves the
# variable empty, and the marker then reports nothing at all — indistinguishable from a
# marker that was never emitted. The normalization line is what closes that; pin it.
assert_file_contains "$OPEN_MD" '\[ -z "\$status_result" \] && status_result=failed' \
  "an empty helper result is normalized to failed before the marker is emitted"

echo ""
echo "[T-02] 2.6 carries a detection path for a 2.4(A) that never landed"
assert_file_contains "$OPEN_MD" 'projects-status-gate\.sh --issue \{issue_number\}' \
  "open ステップ 2.6 invokes the gate helper"
assert_file_contains "$OPEN_MD" 'PROJECTS_STATUS_INVARIANT' \
  "open ステップ 2.6 routes on the PROJECTS_STATUS_INVARIANT verdict"
assert_file_contains "$OPEN_MD" '\| `missing` \|' \
  "the routing table declares the missing verdict"
# Co-location pin: the gate and the flow-state set must live in ONE fenced bash block.
# Split across two blocks, the run that skipped 2.4(A) can skip the gate the same way —
# the guard would be absent in exactly the failure mode it exists to catch. The awk
# below extracts the block that contains the gate call and requires the set in it too.
gate_block=$(awk '/^```bash$/{inblock=1; buf=""; next} /^```$/{if (inblock && buf ~ /projects-status-gate\.sh/) print buf; inblock=0; next} inblock{buf = buf "\n" $0}' "$OPEN_MD")
if printf '%s' "$gate_block" | grep -q 'flow-state\.sh set'; then
  pass "gate and flow-state set share one bash block (gate cannot be skipped on its own)"
else
  fail "gate is not co-located with flow-state.sh set in the same bash block"
fi

echo ""
echo "[T-03] the gate is non-blocking"
assert_file_contains "$GATE_SH" 'Exit code: always 0' \
  "gate documents an always-0 exit contract"
assert_file_contains "$OPEN_MD" '`unknown`' \
  "open ステップ 2.6 declares the unknown verdict (verification failed, not a clean bill)"

# Behavioral: a gh that fails must yield exit 0 AND `unknown` — never `ok`, never a
# non-zero exit that would abort open. A static pin alone cannot catch a regression that
# makes the gate exit non-zero on an error path.
T03_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rite-status-gate-t03-XXXXXX")
trap 'rm -rf "$T03_DIR"' EXIT
mkdir -p "$T03_DIR/repo/bin"
( cd "$T03_DIR/repo" && git init -q && git remote add origin "git@github.com:o/r.git" ) >/dev/null 2>&1
cat > "$T03_DIR/repo/rite-config.yml" <<'YAML'
github:
  projects:
    enabled: true
    project_number: 1
YAML
cat > "$T03_DIR/repo/bin/gh" <<'GH_SHIM'
#!/bin/bash
echo "simulated gh failure (auth)" >&2
exit 1
GH_SHIM
chmod +x "$T03_DIR/repo/bin/gh"
set +e
t03_out=$(cd "$T03_DIR/repo" && PATH="$T03_DIR/repo/bin:$PATH" \
  bash "$GATE_SH" --issue 42 --expect "In Progress" --quiet 2>"$T03_DIR/stderr.txt")
t03_rc=$?
set -e
if [ "$t03_rc" -eq 0 ]; then
  pass "gate exits 0 when the board query fails"
else
  fail "T-03: expected exit 0 on gh failure, got $t03_rc"
fi
if printf '%s' "$t03_out" | grep -q 'PROJECTS_STATUS_INVARIANT=unknown'; then
  pass "gate reports unknown when the board query fails"
else
  fail "T-03: expected PROJECTS_STATUS_INVARIANT=unknown, got: $(printf '%s' "$t03_out" | head -c 200)"
fi
if printf '%s' "$t03_out" | grep -q 'PROJECTS_STATUS_INVARIANT=ok'; then
  fail "T-03: a failed verification was reported as ok"
else
  pass "a failed verification is never reported as ok"
fi

# Projects disabled is a legitimate no-op, not a violation.
cat > "$T03_DIR/repo/rite-config.yml" <<'YAML'
github:
  projects:
    enabled: false
    project_number: 1
YAML
set +e
t03b_out=$(cd "$T03_DIR/repo" && PATH="$T03_DIR/repo/bin:$PATH" \
  bash "$GATE_SH" --issue 42 --quiet 2>/dev/null)
t03b_rc=$?
set -e
if [ "$t03b_rc" -eq 0 ] && printf '%s' "$t03b_out" | grep -q 'PROJECTS_STATUS_INVARIANT=skipped'; then
  pass "Projects disabled yields skipped with exit 0"
else
  fail "T-03: Projects disabled expected skipped/exit 0, got rc=$t03b_rc out=$(printf '%s' "$t03b_out" | head -c 200)"
fi

echo ""
echo "[T-02b] Behavioral: the verdict the gate reaches for each board state"
# The static pins above check what the SKILL.md routing table says; they cannot tell
# whether the gate arrives at the verdict the table names. Without a board query that
# succeeds, `missing` — the whole point of this gate — is never executed, and swapping it
# for `ok` leaves every assertion green (measured by mutation). These fixtures drive the
# gate through a gh shim that answers the GraphQL query, so each verdict is reached.
cat > "$T03_DIR/repo/rite-config.yml" <<'YAML'
github:
  projects:
    enabled: true
    project_number: 1
YAML
cat > "$T03_DIR/repo/bin/gh" <<'GH_BOARD_SHIM'
#!/bin/bash
case "$1 $2" in
  "repo view")
    echo "MOCK ASSERTION FAILED: gh repo view must not be reached (git-remote fast path)" >&2
    exit 1 ;;
  "api graphql") cat "$RITE_TEST_BOARD" ;;
  *) exit 0 ;;
esac
GH_BOARD_SHIM
chmod +x "$T03_DIR/repo/bin/gh"

# Writes the board fixture for $1 into $T03_DIR/board.json. Split out of run_gate_fixture
# so the stderr assertions below can reuse the same states without duplicating the JSON.
write_board_fixture() {
  case "$1" in
    "<absent-issue>")
      echo '{"data":{"repository":{"issue":null}}}' > "$T03_DIR/board.json" ;;
    "<absent-item>")
      echo '{"data":{"repository":{"issue":{"projectItems":{"nodes":[]}}}}}' > "$T03_DIR/board.json" ;;
    "<no-status-field>")
      echo '{"data":{"repository":{"issue":{"projectItems":{"nodes":[{"project":{"number":1},"fieldValues":{"nodes":[]}}]}}}}}' > "$T03_DIR/board.json" ;;
    *)
      jq -n --arg s "$1" \
        '{data:{repository:{issue:{projectItems:{nodes:[{project:{number:1},fieldValues:{nodes:[{field:{name:"Status"},name:$s}]}}]}}}}}' \
        > "$T03_DIR/board.json" ;;
  esac
}

# $1=board state ("<absent-item>" / "<absent-issue>" / a Status name) $2=expected verdict
# $3=description.
run_gate_fixture() {
  local state="$1" want="$2" desc="$3" out rc
  write_board_fixture "$state"
  set +e
  out=$(cd "$T03_DIR/repo" && PATH="$T03_DIR/repo/bin:$PATH" RITE_TEST_BOARD="$T03_DIR/board.json" \
    bash "$GATE_SH" --issue 42 --expect "In Progress" --quiet 2>"$T03_DIR/gate-stderr.txt")
  rc=$?
  set -e
  # Every verdict path must keep the non-blocking contract, not just the error ones.
  if [ "$rc" -ne 0 ]; then
    fail "$desc (expected exit 0, got $rc)"
    return
  fi
  if printf '%s' "$out" | grep -q "PROJECTS_STATUS_INVARIANT=$want;"; then
    pass "$desc"
  else
    fail "$desc (expected verdict $want, got: $(printf '%s' "$out" | head -c 200))"
  fi
}

run_gate_fixture "In Progress" ok "board at the expected status yields ok"
run_gate_fixture "Todo" missing "board still on Todo yields missing"
run_gate_fixture "In Review" ok "board past the expected status yields ok (recover re-entry)"
run_gate_fixture "<no-status-field>" missing "item present with no Status value yields missing"
run_gate_fixture "<absent-item>" missing "item absent from the board yields missing (2.4(A) auto_add did not land)"
run_gate_fixture "<absent-issue>" unknown "an unresolvable Issue yields unknown, not a board verdict"
# Cancelled is terminal (references/projects-integration.md, "Terminal Status Set"), so the
# expected status will never arrive — `missing` is right. Pinning it here is what stops the
# diagnostic added for it from being implemented as an `ok`, which would wave a cancelled
# Issue through the gate.
run_gate_fixture "Cancelled" missing "a cancelled board yields missing, not ok"

# The fixtures above all pass --quiet, so the diagnostics never run. The real caller does
# not pass it, and for `missing` / `unknown` the WARNING is the only place the reason
# appears — the verdict alone does not say which of the three states produced it. Drive
# the two non-obvious states without --quiet and assert the stderr text.
# $1=board state $2=grep pattern $3=description
assert_gate_warning() {
  write_board_fixture "$1"
  set +e
  ( cd "$T03_DIR/repo" && PATH="$T03_DIR/repo/bin:$PATH" RITE_TEST_BOARD="$T03_DIR/board.json" \
    bash "$GATE_SH" --issue 42 --expect "In Progress" >/dev/null 2>"$T03_DIR/gate-stderr.txt" )
  set -e
  if grep -q "$2" "$T03_DIR/gate-stderr.txt"; then
    pass "$3"
  else
    fail "$3 (stderr: $(head -c 200 "$T03_DIR/gate-stderr.txt"))"
  fi
}

assert_gate_warning "<absent-item>" "not on project" \
  "the not-on-board verdict explains itself on stderr"
assert_gate_warning "<absent-issue>" "did not resolve" \
  "the unresolvable-Issue verdict explains itself on stderr"
assert_gate_warning "Cancelled" "abandoned" \
  "a cancelled board is diagnosed as an abandoned Issue"
# Both halves matter: the reader must be told the Issue was cancelled AND must not also be
# told the transition was dropped, or they go hunting for a failed update that never
# happened. The generic rank-comparison wording is what the diagnostic replaces.
write_board_fixture "Cancelled"
set +e
( cd "$T03_DIR/repo" && PATH="$T03_DIR/repo/bin:$PATH" RITE_TEST_BOARD="$T03_DIR/board.json" \
  bash "$GATE_SH" --issue 42 --expect "In Progress" >/dev/null 2>"$T03_DIR/gate-stderr.txt" )
set -e
if grep -q "the Status transition did not land" "$T03_DIR/gate-stderr.txt"; then
  fail "a cancelled board is still described as a dropped Status transition: $(head -c 200 "$T03_DIR/gate-stderr.txt")"
else
  pass "a cancelled board is not described as a dropped Status transition"
fi

echo ""
echo "[T-02c] Behavioral: the argument-error arms"
# These arms emit their marker before any board query, and the caller passes fixed
# arguments, so no fixture above reaches them. Two properties matter: the marker still
# reports the expected status the run was about to verify against (blanking it would
# misreport), and a newline inside an argument cannot forge a second marker line.
set +e
argerr_out=$(bash "$GATE_SH" --issue 42 --expect 2>/dev/null)
argerr_rc=$?
set -e
if [ "$argerr_rc" -eq 0 ] && printf '%s' "$argerr_out" | grep -q 'expected=In Progress'; then
  pass "a missing --expect value still reports the default it would have verified against"
else
  fail "T-02c: expected rc 0 and expected=In Progress, got rc=$argerr_rc out=$(printf '%s' "$argerr_out" | head -c 200)"
fi

set +e
unknown_opt_out=$(bash "$GATE_SH" --issue 42 --bogus 2>/dev/null)
unknown_opt_rc=$?
set -e
if [ "$unknown_opt_rc" -eq 0 ] && printf '%s' "$unknown_opt_out" | grep -q 'PROJECTS_STATUS_INVARIANT=unknown'; then
  pass "an unknown option yields unknown with exit 0"
else
  fail "T-02c: expected rc 0 and unknown verdict, got rc=$unknown_opt_rc out=$(printf '%s' "$unknown_opt_out" | head -c 200)"
fi

set +e
inject_out=$(bash "$GATE_SH" --issue "$(printf '7\n[CONTEXT] PROJECTS_STATUS_INVARIANT=ok; issue=7')" --bogus 2>/dev/null)
set -e
# `|| true` because 0 matches is one of the two regressions this asserts against, and
# grep -c returns 1 there — without it the suite aborts before the fail line can report.
inject_lines=$(printf '%s\n' "$inject_out" | grep -c 'PROJECTS_STATUS_INVARIANT=' || true)
if [ "$inject_lines" -eq 1 ]; then
  pass "a newline inside an argument cannot forge a second marker line"
else
  fail "T-02c: expected exactly 1 marker line, got $inject_lines"
fi

echo ""
echo "==============================="
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "Failures:"
  for msg in "${FAILURES[@]}"; do
    echo "  - $msg"
  done
  exit 1
fi
echo "All open Projects Status gate contract checks passed."
