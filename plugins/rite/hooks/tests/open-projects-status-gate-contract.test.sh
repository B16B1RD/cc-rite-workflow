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
