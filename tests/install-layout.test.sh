#!/usr/bin/env bash
set -euo pipefail

# Offline contract test for the marketplace install layout: the plugin lives in a
# cache directory recorded by installed_plugins.json, and the project has no
# plugins/rite. The plugin root must resolve to the cache and the SessionStart hook
# must start from there. Claude Code itself is never launched.
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_THREAD_ID GROK_SESSION_ID RITE_HOST
unset CLAUDE_ENV_FILE RITE_STATE_ROOT RITE_RUNTIME_EXPLICIT RITE_PLUGIN_ROOT CLAUDE_PLUGIN_ROOT
unset _RITE_HOOK_REDIRECTED _RITE_HOOK_RUNNING_SESSIONSTART

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
REAL_HOME=$HOME
EXPECTED_PASS=20

for tool in jq git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool not available: $tool" >&2; exit 1; }
done

# Resolve symlinks once (macOS mktemp lives under /var -> /private/var) so every
# path comparison below is between real paths.
TEST_ROOT=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$TEST_ROOT"' EXIT
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

canon() { (cd "$1" 2>/dev/null && pwd -P); }

# Existence and checksums of the real user's plugin cache plus the checkout's own
# plugin-root marker: both must be identical before and after the run.
snapshot() {
  local plugins_dir="$REAL_HOME/.claude/plugins"
  if [ -d "$plugins_dir" ]; then
    find "$plugins_dir" -type f -exec cksum {} + | LC_ALL=C sort
  else
    echo "absent: $plugins_dir"
  fi
  if [ -e "$REPO_ROOT/.rite/plugin-root" ]; then
    cat "$REPO_ROOT/.rite/plugin-root"
  else
    echo "absent: plugin-root marker"
  fi
}
SNAPSHOT_BEFORE=$(snapshot)

# Copy the checkout's plugin into a marketplace-style cache under a throwaway HOME.
# Sets HOME_DIR / INSTALL_DIR. installPath is the plugin root itself (no nested
# plugins/rite); the JSON mirrors a live installed_plugins.json entry.
make_home() {
  HOME_DIR="$TEST_ROOT/$1/home"
  INSTALL_DIR="$HOME_DIR/.claude/plugins/cache/rite-marketplace/rite/0.0.0-layout-test"
  mkdir -p "$INSTALL_DIR" || return 1
  cp -R "$REPO_ROOT/plugins/rite/." "$INSTALL_DIR/" || return 1
  [ -f "$INSTALL_DIR/hooks/session-start.sh" ] || return 1
  [ ! -e "$INSTALL_DIR/plugins/rite" ] || return 1
  jq -n --arg p "$INSTALL_DIR" '{
    version: 2,
    plugins: {"rite@rite-marketplace": [{
      scope: "user", installPath: $p, version: "0.0.0-layout-test",
      installedAt: "2026-01-01T00:00:00.000Z", lastUpdated: "2026-01-01T00:00:00.000Z",
      gitCommitSha: "0000000000000000000000000000000000000000"}]}}' \
    > "$HOME_DIR/.claude/plugins/installed_plugins.json" || return 1
}

# A project directory like a consumer's: a git repository of its own, no plugins/rite,
# no plugin-root marker. Sets WORK_DIR.
make_work() {
  WORK_DIR="$TEST_ROOT/$1/work"
  mkdir -p "$WORK_DIR" || return 1
  git init -q "$WORK_DIR" || return 1
  [ "$(git -C "$WORK_DIR" rev-parse --show-toplevel)" = "$(canon "$WORK_DIR")" ] || return 1
  [ ! -e "$WORK_DIR/plugins/rite" ] || return 1
  [ ! -e "$WORK_DIR/.rite/plugin-root" ] && [ ! -e "$WORK_DIR/.rite-plugin-root" ] || return 1
}

# The resolver text shipped with the plugin, taken from the cached copy itself.
resolver_one_liner() {
  grep -m1 '^plugin_root=\$(cat \.rite/plugin-root' \
    "$INSTALL_DIR/references/plugin-path-resolution.md" || return 1
}

# Prints the resolved root. Fails loudly on an empty result or a root outside the cache.
resolve_root() {
  local work=$1 home=$2 install=$3 line root
  line=$(resolver_one_liner) || { echo "ERROR: resolver one-liner not found in the install cache" >&2; return 1; }
  root=$(cd "$work" && HOME="$home" bash -c "$line"'; printf %s "$plugin_root"') || true
  if [ -z "$root" ]; then
    echo "ERROR: plugin root unresolved from installed_plugins.json (resolved: '<empty>')" >&2
    return 1
  fi
  if [ "$(canon "$root")" != "$(canon "$install")" ]; then
    echo "ERROR: plugin root resolved outside the install cache (priority 1 or 2 selected): $root" >&2
    return 1
  fi
  printf '%s\n' "$root"
}

# Starts the hook with the command registered in the cached hooks.json.
run_session_start() {
  local work=$1 home=$2 install=$3 cmd err rc=0
  cmd=$(jq -r '.hooks.SessionStart[0].hooks[0].command // empty' "$install/hooks/hooks.json") || return 1
  [ -n "$cmd" ] || { echo "ERROR: SessionStart command missing in hooks.json" >&2; return 1; }
  err="$work/.hook-stderr"
  printf '{"session_id":"11111111-2222-3333-4444-555555555555","cwd":"%s","source":"startup"}' "$work" \
    | (cd "$work" && HOME="$home" CLAUDE_PLUGIN_ROOT="$install" bash -c "$cmd") >/dev/null 2>"$err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    cat "$err" >&2
    echo "ERROR: session-start exited $rc" >&2
    return 1
  fi
  if grep -q '読み込まれた plugin が .rite/plugin-root と一致しません' "$err"; then
    cat "$err" >&2
    return 1
  fi
}

# --- T-01: the cache path is resolved from a throwaway HOME -------------------
make_home t01
make_work t01
resolved=$(resolve_root "$WORK_DIR" "$HOME_DIR" "$INSTALL_DIR") || resolved=""
[ -n "$resolved" ] && pass 'T-01 resolver returns the cache path' || fail 'T-01 resolver returns the cache path'
case "$resolved" in
  "$TEST_ROOT"/*) pass 'T-01 resolved path is under the throwaway HOME' ;;
  *) fail "T-01 resolved path is under the throwaway HOME ($resolved)" ;;
esac
[ -d "$resolved/hooks" ] && pass 'T-01 resolved root contains hooks/' || fail 'T-01 resolved root contains hooks/'
[ "$(jq -r '.plugins["rite@rite-marketplace"][0].installPath' "$HOME_DIR/.claude/plugins/installed_plugins.json")" = "$INSTALL_DIR" ] \
  && pass 'T-01 installPath is the plugin root itself' || fail 'T-01 installPath is the plugin root itself'

# --- T-02: the hook starts from the cache layout ------------------------------
make_home t02
make_work t02
if run_session_start "$WORK_DIR" "$HOME_DIR" "$INSTALL_DIR"; then
  pass 'T-02 session-start exits 0 from the cache layout'
else
  fail 'T-02 session-start exits 0 from the cache layout'
fi
# rc=0 alone is also what an early exit returns; the marker proves the hook ran.
if [ -f "$WORK_DIR/.rite/plugin-root" ] && [ "$(canon "$(cat "$WORK_DIR/.rite/plugin-root")")" = "$(canon "$INSTALL_DIR")" ]; then
  pass 'T-02 session-start recorded the cache path as plugin-root'
else
  fail 'T-02 session-start recorded the cache path as plugin-root'
fi
grep -q '読み込まれた plugin が .rite/plugin-root と一致しません' "$WORK_DIR/.hook-stderr" \
  && fail 'T-02 no plugin-root mismatch warning' || pass 'T-02 no plugin-root mismatch warning'

# --- T-03: a checkout-side plugins/rite is detected as a bypass ----------------
make_home t03
make_work t03
resolve_root "$WORK_DIR" "$HOME_DIR" "$INSTALL_DIR" >/dev/null 2>&1 \
  && pass 'T-03 control: resolves to the cache without plugins/rite' \
  || fail 'T-03 control: resolves to the cache without plugins/rite'
mkdir -p "$WORK_DIR/plugins/rite/hooks"
rc=0
resolve_root "$WORK_DIR" "$HOME_DIR" "$INSTALL_DIR" >"$TEST_ROOT/t03.out" 2>"$TEST_ROOT/t03.err" || rc=$?
[ "$rc" -ne 0 ] && pass 'T-03 plugins/rite in the project fails' || fail 'T-03 plugins/rite in the project fails'
grep -q '^ERROR: plugin root resolved outside the install cache (priority 1 or 2 selected): ' "$TEST_ROOT/t03.err" \
  && pass 'T-03 failure reports the bypass' || fail 'T-03 failure reports the bypass'
grep -qF "$(canon "$WORK_DIR/plugins/rite")" "$TEST_ROOT/t03.err" \
  && pass 'T-03 failure names the checkout path' || fail 'T-03 failure names the checkout path'

# --- T-04: a missing installed_plugins.json fails instead of skipping ----------
make_home t04
make_work t04
resolve_root "$WORK_DIR" "$HOME_DIR" "$INSTALL_DIR" >/dev/null 2>&1 \
  && pass 'T-04 control: resolves with installed_plugins.json present' \
  || fail 'T-04 control: resolves with installed_plugins.json present'
rm -f "$HOME_DIR/.claude/plugins/installed_plugins.json"
rc=0
resolve_root "$WORK_DIR" "$HOME_DIR" "$INSTALL_DIR" >"$TEST_ROOT/t04.out" 2>"$TEST_ROOT/t04.err" || rc=$?
[ "$rc" -ne 0 ] && pass 'T-04 missing installed_plugins.json fails' || fail 'T-04 missing installed_plugins.json fails'
grep -q "^ERROR: plugin root unresolved from installed_plugins.json (resolved: '<empty>')" "$TEST_ROOT/t04.err" \
  && pass 'T-04 failure reports the unresolved root' || fail 'T-04 failure reports the unresolved root'

# --- T-05: ci.yml runs the layout test on both OSes as blocking jobs -----------
CI_YML="$REPO_ROOT/.github/workflows/ci.yml"
JOB=$(awk '/^  install-layout:/{f=1;print;next} f&&/^  [A-Za-z0-9_-]+:/{exit} f{print}' "$CI_YML")
[ -n "$JOB" ] && pass 'T-05 install-layout job exists' || fail 'T-05 install-layout job exists'
printf '%s\n' "$JOB" | grep -qE '^ +os: \[ubuntu-latest, macos-latest\]$' \
  && pass 'T-05 matrix is exactly ubuntu-latest and macos-latest' || fail 'T-05 matrix is exactly ubuntu-latest and macos-latest'
printf '%s\n' "$JOB" | grep -q 'continue-on-error' \
  && fail 'T-05 no continue-on-error in the job' || pass 'T-05 no continue-on-error in the job'
run_line=$(printf '%s\n' "$JOB" | grep -n 'bash tests/install-layout.test.sh' | head -1 | cut -d: -f1)
brew_line=$(printf '%s\n' "$JOB" | grep -n 'brew install bash' | head -1 | cut -d: -f1)
[ -n "$run_line" ] && printf '%s\n' "$JOB" | sed -n "$((run_line > 3 ? run_line - 3 : 1)),${run_line}p" | grep -q 'shell: bash' \
  && pass 'T-05 the test runs under shell: bash' || fail 'T-05 the test runs under shell: bash'
[ -n "$run_line" ] && [ -n "$brew_line" ] && [ "$brew_line" -lt "$run_line" ] \
  && pass 'T-05 bash 5 is installed before the test on macOS' || fail 'T-05 bash 5 is installed before the test on macOS'

# --- T-06: the real HOME and the checkout are untouched ------------------------
SNAPSHOT_AFTER=$(snapshot)
[ "$SNAPSHOT_BEFORE" = "$SNAPSHOT_AFTER" ] \
  && pass 'T-06 real HOME plugin cache and checkout marker are unchanged' \
  || fail 'T-06 real HOME plugin cache and checkout marker are unchanged'

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
if [ "$PASS" -ne "$EXPECTED_PASS" ]; then
  echo "ERROR: expected $EXPECTED_PASS passing checks, ran $PASS" >&2
  exit 1
fi
