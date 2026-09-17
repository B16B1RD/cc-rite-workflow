#!/bin/bash
# gitignore-health-check-verify-negation.test.sh
#
# Smoke tests for the `--verify-negation` mode of gitignore-health-check.sh
# (wiki/init.md ステップ 1.3.4 delegation target).
#
# The mode is post-injection verification: caller (wiki/init.md ステップ 1.3.4) is
# same_branch + has just injected the `!.rite/wiki/` negation, so the mode skips
# config/strategy/parent-exclusion checks and is fully non-blocking (every outcome
# exits 0; result surfaces via stdout `✅ ... OK` / stderr `WARNING`).
#
# Coverage:
#   TC-1  healthy negation        → stdout `✅ ... OK`, exit 0
#   TC-2  absent/broken negation  → stderr WARNING, exit 0 (non-blocking contract)
#   TC-3  rmdir 副作用抑止          → .rite/wiki/raw/ survives, probe removed
#   TC-4  no rite-config.yml       → still runs (config read is skipped in this mode)
#
# NOT covered (environment-dependent; verified manually): probe-creation failure on
# a read-only filesystem. The mode emits a WARNING + exit 0 in that case too, but
# simulating it portably (chmod is a no-op under root) is brittle for a smoke test.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
SCRIPT="$PLUGIN_ROOT/hooks/scripts/gitignore-health-check.sh"

if [ ! -x "$SCRIPT" ]; then
  echo "ERROR: helper not executable: $SCRIPT" >&2
  exit 1
fi

cleanup_dirs=()
err_files=()
cleanup() {
  local p
  for p in "${cleanup_dirs[@]:-}"; do [ -n "$p" ] && rm -rf "$p"; done
  for p in "${err_files[@]:-}"; do [ -n "$p" ] && rm -f "$p"; done
}
trap cleanup EXIT

# Healthy same_branch .gitignore: parent exclusion + negation override (the canonical
# setup from the repo .gitignore `DRIFT-CHECK ANCHOR: same_branch verification-first` steps).
write_healthy_gitignore() {
  printf '.rite/wiki/\n!.rite/wiki/\n!.rite/wiki/**\n' > "$1/.gitignore"
}

# Broken/absent negation: parent exclusion only, no negation override.
write_broken_gitignore() {
  printf '.rite/wiki/\n' > "$1/.gitignore"
}

mk_errfile() {
  local f
  f=$(mktemp "${TMPDIR:-/tmp}/rite-vn-err-XXXXXX") || { echo "ERROR: mktemp failed" >&2; exit 1; }
  err_files+=("$f")
  printf '%s' "$f"
}

# === TC-1: healthy negation → ✅ OK on stdout, exit 0 ===
echo "=== TC-1: healthy negation ==="
sbx=$(make_sandbox); cleanup_dirs+=("$sbx")
write_healthy_gitignore "$sbx"
errf=$(mk_errfile)
out=$(cd "$sbx" && bash "$SCRIPT" --verify-negation 2>"$errf"); rc=$?
assert "TC-1 exit 0" "0" "$rc"
if printf '%s' "$out" | grep -cF >/dev/null "✅ .gitignore negation verification OK"; then
  pass "TC-1 stdout に ✅ negation OK"
else
  fail "TC-1 stdout に ✅ negation OK (out='$out' err='$(cat "$errf")')"
fi

# === TC-2: absent negation → WARNING on stderr, exit 0 (non-blocking) ===
echo "=== TC-2: absent negation (non-blocking) ==="
sbx=$(make_sandbox); cleanup_dirs+=("$sbx")
write_broken_gitignore "$sbx"
errf=$(mk_errfile)
out=$(cd "$sbx" && bash "$SCRIPT" --verify-negation 2>"$errf"); rc=$?
err=$(cat "$errf")
assert "TC-2 exit 0 (non-blocking)" "0" "$rc"
if printf '%s' "$err" | grep -cF >/dev/null "WARNING: .gitignore negation verification failed"; then
  pass "TC-2 stderr に WARNING"
else
  fail "TC-2 stderr に WARNING (err='$err' out='$out')"
fi
if printf '%s' "$out" | grep -cF >/dev/null "✅"; then
  fail "TC-2 success メッセージが出てはいけない (out='$out')"
else
  pass "TC-2 stdout に ✅ 不在"
fi

# === TC-3: rmdir 副作用抑止 — .rite/wiki/raw/ survives, probe removed ===
echo "=== TC-3: rmdir 副作用抑止 ==="
sbx=$(make_sandbox); cleanup_dirs+=("$sbx")
write_healthy_gitignore "$sbx"
(cd "$sbx" && bash "$SCRIPT" --verify-negation >/dev/null 2>&1)
if [ -d "$sbx/.rite/wiki/raw" ]; then
  pass "TC-3 .rite/wiki/raw/ が残存 (rmdir 抑止)"
else
  fail "TC-3 .rite/wiki/raw/ が rmdir された (rmdir 抑止が効いていない)"
fi
if [ ! -e "$sbx/.rite/wiki/raw/.rite-lint-negation-probe" ]; then
  pass "TC-3 probe は cleanup 済み"
else
  fail "TC-3 probe が残留している"
fi

# === TC-4: no rite-config.yml — mode still runs (config read skipped) ===
echo "=== TC-4: config 不在でも動作 ==="
sbx=$(make_sandbox); cleanup_dirs+=("$sbx")
write_healthy_gitignore "$sbx"
rm -f "$sbx/rite-config.yml"  # make_sandbox は作らないが念のため
errf=$(mk_errfile)
out=$(cd "$sbx" && bash "$SCRIPT" --verify-negation 2>"$errf"); rc=$?
assert "TC-4 exit 0 (config 不在)" "0" "$rc"
if printf '%s' "$out" | grep -cF >/dev/null "✅ .gitignore negation verification OK"; then
  pass "TC-4 config 不在でも ✅ OK"
else
  fail "TC-4 config 不在で ✅ OK (out='$out' err='$(cat "$errf")')"
fi

if ! print_summary "$(basename "$0")" \
  "drift: gitignore-health-check.sh --verify-negation の挙動が変わった可能性。wiki/init.md ステップ 1.3.4 委譲契約を参照。"; then
  exit 1
fi
