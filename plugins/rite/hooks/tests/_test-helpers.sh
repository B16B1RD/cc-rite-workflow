#!/bin/bash
# Common test helpers for plugins/rite/hooks/tests/*.test.sh
#
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/_test-helpers.sh"
#   REPO_ROOT="$(_helpers_resolve_repo_root "$SCRIPT_DIR")"
#   # ...assertions using pass / fail / assert / assert_grep / assert_not_grep...
#   if ! print_summary "$(basename "$0")" "drift hint text"; then
#     exit 1
#   fi
#
# Why this file is named `_test-helpers.sh` (no `.test.sh` suffix):
#   `run-tests.sh` globs `*.test.sh`. A `_test-helpers.sh` filename is
#   intentionally excluded so this helper is sourced only when callers
#   `source` it explicitly. Each caller test still runs standalone
#   (`bash 4-site-symmetry.test.sh`) because it defines its own SCRIPT_DIR
#   before sourcing this file.
#
# Output convention:
#   Scope: applies to tests that `source` this helper. Enumerate the current
#   set with:
#     grep -l 'source.*_test-helpers.sh' plugins/rite/hooks/tests/*.test.sh
#   Tests that define `pass()` / `fail()` inline (enumerate with the inverse
#   `grep -L 'source.*_test-helpers.sh' plugins/rite/hooks/tests/*.test.sh`)
#   are migration candidates but are NOT covered by this convention until
#   they switch to sourcing this file.
#
#   Tests sourcing this helper follow a single canonical convention so the
#   pass/fail stream and any supporting failure detail stay together for
#   readers and downstream tooling.
#
#   stdout (canonical for test-result stream):
#     - pass / fail / assert / assert_grep / assert_not_grep markers
#     - print_summary block (PASS/FAIL counts, Failed assertions list,
#       optional drift_hint_text)
#     - test phase headers (e.g., `echo "=== ... ==="`)
#     - failure detail context (expected/actual diffs, "--- block ---"
#       dumps that immediately follow a fail() line). Keep these on
#       stdout so the failure marker and its diff render in the same
#       stream — splitting them across stdout/stderr makes the diff
#       hard to correlate when callers redirect only one stream.
#
#   stderr (>&2 — reserved for environment errors only):
#     - Hard preconditions that prevent the test from running
#       (missing executable, mktemp/jq failure, malformed config).
#       These are NOT test failures; they are infrastructure problems
#       that callers may want to handle separately from PASS/FAIL.
#
#   The convention exists so downstream consumers (CI log parsers, grep
#   filters scanning for `❌` / `PASS:`) can rely on a single source stream
#   to capture the full test-result narrative without losing failure
#   detail context. `run-tests.sh` and `scripts/tests/run-all.sh` capture
#   each test file with `$(bash "$f" 2>&1)` — both streams MERGED — so that
#   they can parse the per-file skip count out of the summary. The rule
#   therefore remains observable rather than enforced: an environment error
#   written to stderr lands in the same captured stream as the assertions,
#   and the runner's skip parser anchors on summary-line shapes precisely
#   so that stderr text cannot be mistaken for a count.
#
# Provided variables (initialized to 0 / empty array on source):
#   PASS, FAIL, SKIP, FAILED_NAMES
#
# Preconditions:
#   Sourcing ABORTS the caller (exit 1) when neither timeout(1) nor perl(1) is
#   available, because _timeout below cannot detect hangs without one of them and
#   every caller reads a non-124 exit code as "no hang". Failing loudly at source
#   time is the only placement that cannot be swallowed by a `$( )` subshell.
#
# Provided functions:
#   _helpers_resolve_plugin_root <script_dir>
#   _helpers_resolve_repo_root   <script_dir>
#   pass <label>                                 # writes to stdout
#   fail <label>                                 # writes to stdout
#   skip <label>                                 # writes to stdout, counted in SKIP
#   _timeout <seconds> <command...>              # portable timeout(1); see Preconditions
#   assert <label> <expected> <actual>           # writes to stdout (via pass/fail)
#   assert_grep     <label> <file> <pattern>     # ERE, exits via fail() if not found
#   assert_not_grep <label> <file> <pattern>     # ERE, exits via fail() if found
#   assert_file_exists_or_fail <label> <file>    # pre-condition guard for assertion-pair loops
#                                                # (1 fail per missing file; caller pattern: || continue)
#   assert_grep_in_section <label> <file> <start_pattern> <end_pattern> <grep_pattern>
#                                                # extract awk-range section + ERE grep with self-cleanup
#   print_summary [test_name] [drift_hint_text]  # writes to stdout, returns 1 if FAIL > 0
#   make_sandbox       [--branch <name>] [--soft]   # git-init+commit sandbox, echoes path
#   make_plain_sandbox [--soft]                     # bare mktemp -d sandbox, echoes path

# Resolve PLUGIN_ROOT from the test's SCRIPT_DIR (tests/ is 2 levels below).
# plugins/rite/hooks/tests/<test>.sh -> plugins/rite (2 up)
_helpers_resolve_plugin_root() {
  local script_dir="${1:?script_dir required}"
  (cd "$script_dir/../.." && pwd)
}

# Resolve REPO_ROOT from the test's SCRIPT_DIR (tests/ is 4 levels below repo root).
# plugins/rite/hooks/tests/<test>.sh -> repo root (4 up)
_helpers_resolve_repo_root() {
  local script_dir="${1:?script_dir required}"
  (cd "$script_dir/../../../.." && pwd)
}

# Counters — declared here so callers can rely on them existing after `source`.
# Callers may reassign to 0 if re-running within a long-lived shell, but the
# normal pattern (run-tests.sh forks a fresh `bash` per test) makes that unnecessary.
PASS=0
FAIL=0
SKIP=0
FAILED_NAMES=()

# Pass marker — writes to stdout (see "Output convention" in the file header).
pass() {
  PASS=$((PASS + 1))
  echo "  ✅ $1"
}

# Skip marker — writes to stdout (see "Output convention" in the file header).
#
# Skips are counted, not just printed. A platform-gated suite that prints
# "PASS: 8, FAIL: 0" tells the reader nothing about how many assertions never
# ran; on the macOS leg that difference is 31 assertions, several of them
# guarding known production bugs (#2010 / #2011 / #2014). Counting them keeps
# "green" honest and makes a growing skip set visible in the summary.
# Same shape as the pre-existing skip() in pre-compact.test.sh and
# pr-cycle-cleanup.test.sh.
skip() {
  SKIP=$((SKIP + 1))
  echo "  ⏭️ SKIP: $1"
}

# Fail marker — writes to stdout (see "Output convention" in the file header).
# Any failure-detail context the caller emits afterwards (expected/actual,
# block dumps, etc.) MUST also go to stdout so it stays adjacent to this
# marker in the result stream.
fail() {
  FAIL=$((FAIL + 1))
  FAILED_NAMES+=("$1")
  echo "  ❌ $1"
}

# Generic equality assertion.
assert() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$label"
  else
    fail "$label (expected='$expected' actual='$actual')"
  fi
}

# Pattern presence assertion (ERE via grep -E).
# File-existence check distinguishes "file missing" (grep exit 2) from "pattern absent" (grep exit 1).
assert_grep() {
  local label="$1"
  local file="$2"
  local pattern="$3"
  if [ ! -f "$file" ]; then
    fail "$label (file not found: $file)"
    return
  fi
  if grep -qE "$pattern" "$file"; then
    pass "$label"
  else
    fail "$label (pattern not found in $file: $pattern)"
  fi
}

# Pattern absence assertion (ERE via grep -E).
# File-existence check distinguishes "file missing" (grep exit 2) from "pattern absent" (grep exit 1).
assert_not_grep() {
  local label="$1"
  local file="$2"
  local pattern="$3"
  if [ ! -f "$file" ]; then
    fail "$label (file not found: $file)"
    return
  fi
  if grep -qE "$pattern" "$file"; then
    fail "$label (anti-pattern found in $file: $pattern)"
  else
    pass "$label"
  fi
}

# File-existence pre-condition guard for assertion-pair loops.
#
# Consolidates the inline `[ ! -f "$f" ] && fail ... && continue` boilerplate
# that callers would otherwise inline when running multiple assertions against the
# same file inside a loop. Without this guard the standalone assert_grep / assert_not_grep
# file-existence checks each emit their own fail() when the file is absent,
# inflating one missing file into N fails (one per assertion pair).
#
# Caller pattern (the helper writes the failure marker via fail() and returns
# non-zero so the caller can `|| continue` to skip the subsequent assertions):
#   for r in "${reviewers[@]}"; do
#     f="$AGENTS_DIR/$r.md"
#     assert_file_exists_or_fail "$r.md" "$f" || continue
#     assert_grep     "..." "$f" 'pattern1'
#     assert_not_grep "..." "$f" 'pattern2'
#   done
#
# Return code semantics (consumed by caller `|| continue`):
#   0 — file exists, caller proceeds with the subsequent assertions
#   1 — file is missing, fail() was already invoked, caller should skip
assert_file_exists_or_fail() {
  local label="$1"
  local file="$2"
  if [ ! -f "$file" ]; then
    fail "$label (file not found: $file)"
    return 1
  fi
  return 0
}

# Section-scoped pattern presence assertion.
# Extracts an awk address-range section ([start_pattern, end_pattern]) from `file`
# into a private tempfile, runs `grep -qE grep_pattern` against it, then self-cleans.
#
# Consolidates the boilerplate that T-2/T-3/T-4 would otherwise duplicate:
#   section_file=$(mktemp)
#   trap 'rm -f "$section_file"' EXIT
#   awk '/start/, /end/' "$file" > "$section_file"
#   assert_grep "label" "$section_file" "pattern"
#
# What is consolidated: section tempfile lifecycle (mktemp + cleanup) and the
# awk range extraction. What is NOT consolidated: callers managing their own
# tempfiles for non-section uses still need their own mktemp + trap.
#
# Patterns are passed to awk via `-v` variables (not interpolated into the awk
# program text) so caller-supplied strings cannot inject awk syntax.
#
# Failure modes (each falls through to fail() with diagnostic context):
#   - file not found          → "file not found: <file>"
#   - mktemp failure          → "mktemp failed" (infrastructure error to stderr)
#   - awk extraction failure  → "awk extraction failed" (rc, syntax / IO error to stderr)
#   - empty section           → "empty section: start_pattern matched no line"
#                               (distinguishable from "pattern not found in section")
#   - pattern not in section  → "pattern not found in section [<start>..<end>] of <file>: <pattern>"
#
# Caller pattern:
#   assert_grep_in_section "T-2 reviewer ref" "$BASE_FILE" \
#     '^### Hypothetical Exception カテゴリの nit-noted 禁止$' \
#     '^##[^#]' \
#     "security\\.md|security-reviewer"
assert_grep_in_section() {
  local label="$1"
  local file="$2"
  local start_pattern="$3"
  local end_pattern="$4"
  local grep_pattern="$5"
  if [ ! -f "$file" ]; then
    fail "$label (file not found: $file)"
    return
  fi
  local section_file
  if ! section_file=$(mktemp); then
    echo "ERROR: assert_grep_in_section: mktemp failed" >&2
    fail "$label (mktemp failed)"
    return
  fi
  local awk_err
  if ! awk -v start="$start_pattern" -v end="$end_pattern" \
       '$0 ~ start, $0 ~ end' "$file" > "$section_file" 2>"$section_file.err"; then
    awk_err=$(head -3 "$section_file.err" 2>/dev/null)
    echo "ERROR: assert_grep_in_section: awk extraction failed (file=$file start=$start_pattern end=$end_pattern): $awk_err" >&2
    fail "$label (awk extraction failed)"
    rm -f "$section_file" "$section_file.err"
    return
  fi
  rm -f "$section_file.err"
  if [ ! -s "$section_file" ]; then
    fail "$label (empty section: start_pattern [$start_pattern] matched no line in $file — section heading drift?)"
    rm -f "$section_file"
    return
  fi
  if grep -qE "$grep_pattern" "$section_file"; then
    pass "$label"
  else
    fail "$label (pattern not found in section [$start_pattern..$end_pattern] of $file: $grep_pattern)"
  fi
  rm -f "$section_file"
}

# _timeout <seconds> <command...> — portable timeout(1) for the test suite.
#
# GNU `timeout` is absent on macOS (BSD / no coreutils — the macOS CI leg
# deliberately omits coreutils to expose GNU/BSD divergence, so the suite must
# NOT depend on the binary). When it is present we use it; otherwise we fall
# back to a perl fork/waitpid shim that reproduces timeout(1)'s full exit-code
# contract: 124 on timeout (the value several suites assert on to detect an
# infinite-loop regression), 128+N when the child dies from signal N, and the
# child's own status otherwise. macOS ships /usr/bin/perl, so hang-protection
# coverage is preserved rather than silently skipped. A naive
# `perl -e 'alarm; exec'` is WRONG here — after exec, SIGALRM hits the target
# with its default disposition and the process dies with 142 (128+14),
# defeating the `== 124` assertions; the fork/waitpid form below maps the alarm
# to a real 124. `exec` in the child keeps fd 0, so stdin-fed callers
# (`printf ... | _timeout N bash ...`, `_timeout N bash hook < in.json`) work
# unchanged. The block form `exec { $ARGV[0] } @ARGV` forces execvp even for a
# single argument, so a command string containing shell metacharacters is never
# handed to /bin/sh (plain `exec @ARGV` would shell-interpret it, diverging from
# timeout(1) and turning the shim into an injection sink).
_timeout() {
  local _d="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$_d" "$@"
  else
    perl -e '
      my $d = shift;
      # alarm truncates to an integer, so a fractional deadline silently becomes
      # alarm 0 — no timeout at all, and waitpid blocks until the CI job limit.
      # Reject rather than degrade, and exit 125 rather than die: die exits 255,
      # which every caller reads as "not 124, so no hang" — the same silent pass
      # the rejection exists to prevent. GNU timeout accepts fractions, so this
      # shim only claims the contract for integer seconds.
      if ($d !~ /^[0-9]+$/) {
        print STDERR "_timeout: fractional seconds are not supported by the perl fallback: $d\n";
        exit 125;
      }
      my $pid = fork;
      exit 127 unless defined $pid;
      if ($pid == 0) { exec { $ARGV[0] } @ARGV; exit 127; }
      $SIG{ALRM} = sub { kill "TERM", $pid; waitpid($pid, 0); exit 124; };
      alarm $d; waitpid $pid, 0;
      my $st = $?; exit($st & 127 ? 128 + ($st & 127) : $st >> 8);
    ' "$_d" "$@"
  fi
}

# Fail closed when no backend exists. Every `_timeout` caller reads a non-124 rc
# as "no hang", so a missing backend would silently turn each hang assertion into
# a pass. Abort at source time rather than degrade.
if ! command -v timeout >/dev/null 2>&1 && ! command -v perl >/dev/null 2>&1; then
  echo "ERROR: neither timeout(1) nor perl(1) is available — _timeout cannot detect" >&2
  echo "  hangs, and every hang assertion in this suite would silently pass." >&2
  echo "  Install GNU coreutils (timeout) or perl before running the test suite." >&2
  exit 1
fi

# make_sandbox — git-init + initial-commit sandbox.
#
# Consolidates the inline `make_sandbox()` definition shared by
# state-read.test.sh, work-memory-update.test.sh (with `--branch` for branch
# parsing scenarios), and notification.test.sh TC-016 (with `--soft` for the
# setup-failure-skip path).
#
# Options:
#   --branch <name>  git init -b <name>; fall back to plain `git init` if -b is
#                    unsupported (older git pre-2.28).
#   --soft           Return non-zero on git-init/commit failure (caller decides
#                    whether to `skip` or treat as test failure). Default behavior
#                    is hard-fail (echo ERROR + exit 1) — used by tests where a
#                    broken sandbox indicates an infrastructure problem that must
#                    halt the run.
#
# Output:
#   stdout : sandbox path (one line) on success.
#   stderr : ERROR line(s) on failure, plus up to 5 lines of git's own stderr
#            to aid CI debugging when git config issues break sandbox setup.
#
# Exit code semantics:
#   exit 1   — hard-fail (default): mktemp -d or git init/commit failure halts the run.
#   return 1 — soft-fail (--soft):  same failures, but caller decides skip vs. test failure.
#   return 2 — option parse error:  unknown option or --branch without a non-empty argument.
#
# Caller patterns (the helper does NOT push to cleanup_dirs — callers do):
#   SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
#   SBX=$(make_sandbox --branch fix/issue-687-test); cleanup_dirs+=("$SBX")
#   if ! SBX=$(make_sandbox --soft); then skip "TC-N (sandbox setup failed)"; fi
#
# Note: $(make_sandbox) runs in a command substitution subshell — any cleanup_dirs
# push performed inside a wrapper that is itself called via $(...) stays local to
# that subshell and is lost in the parent. Callers MUST push to cleanup_dirs from
# the parent shell (the assignment line, not inside the wrapper).
make_sandbox() {
  local branch_arg=""
  local soft_fail=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --branch)
        if [ $# -lt 2 ] || [ -z "$2" ]; then
          echo "ERROR: make_sandbox: --branch requires a non-empty argument" >&2
          return 2
        fi
        branch_arg="$2"
        shift 2
        ;;
      --soft)
        soft_fail=1
        shift
        ;;
      *)
        echo "ERROR: make_sandbox: unknown option '$1'" >&2
        return 2
        ;;
    esac
  done

  local d sandbox_err
  d=$(mktemp -d) || {
    echo "ERROR: make_sandbox: mktemp -d failed" >&2
    [ "$soft_fail" -eq 1 ] && return 1
    exit 1
  }
  # Canonicalize the sandbox root so it matches what the code under test sees.
  # On macOS $TMPDIR lives under /var/folders (a symlink to /private/var/...),
  # and git rev-parse / realpath in production canonicalize to the /private
  # form. Comparing the raw mktemp path against those canonical paths would
  # spuriously fail path-equality assertions (Issue #2008 Family D).
  #
  # Fail closed on canonicalization failure. `cd ""` returns 0 without changing
  # the directory, so letting an empty $d through would make the git init/commit
  # subshell below run in the caller's CWD — the repository checkout under CI —
  # instead of a sandbox, and the helper would still return 0.
  local d_canon
  d_canon=$(cd "$d" && pwd -P) || {
    echo "ERROR: make_sandbox: failed to canonicalize sandbox root '$d'" >&2
    [ "$soft_fail" -eq 1 ] && return 1
    exit 1
  }
  d="$d_canon"
  sandbox_err=$(mktemp "${TMPDIR:-/tmp}/rite-sandbox-err-XXXXXX" 2>/dev/null) || {
    echo "WARNING: make_sandbox: mktemp ${TMPDIR:-/tmp}/rite-sandbox-err-XXXXXX failed; diagnostic capture disabled (git stderr will not be surfaced on failure)" >&2
    sandbox_err="/dev/null"
  }

  if ! (
    cd "$d" || exit 1
    if [ -n "$branch_arg" ]; then
      # Pre-2.28 git lacks `-b`; fall back to plain init + checkout to ensure
      # the requested branch name is the active HEAD regardless of git version.
      if ! git init -q -b "$branch_arg" 2>"$sandbox_err"; then
        git init -q 2>>"$sandbox_err" || exit 1
        git checkout -q -b "$branch_arg" 2>>"$sandbox_err" || exit 1
      fi
    else
      git init -q 2>"$sandbox_err"
    fi
    echo a > a && git add a 2>>"$sandbox_err"
    git -c user.email=t@test.local -c user.name=test commit -q -m init 2>>"$sandbox_err"
  ); then
    echo "ERROR: make_sandbox: git init/commit failed in $d" >&2
    [ "$sandbox_err" != "/dev/null" ] && [ -s "$sandbox_err" ] && head -5 "$sandbox_err" | sed 's/^/  /' >&2
    rm -rf "$d"
    [ "$sandbox_err" != "/dev/null" ] && rm -f "$sandbox_err"
    [ "$soft_fail" -eq 1 ] && return 1
    exit 1
  fi
  [ "$sandbox_err" != "/dev/null" ] && rm -f "$sandbox_err"
  echo "$d"
}

# make_plain_sandbox — bare `mktemp -d` sandbox (no git init), echoes path.
#
# Consolidates the no-git sandbox helper shared by
# _validate-helpers.test.sh and _resolve-session-id-from-file.test.sh.
# The helper does NOT push to cleanup_dirs — callers do — to match the
# `make_sandbox` convention (single uniform caller pattern across tests).
#
# Options:
#   --soft  Return non-zero on mktemp failure (caller decides whether to `skip`
#           or treat as test failure). Default behavior is hard-fail (echo ERROR
#           + exit 1). Mirrors `make_sandbox` for API symmetry.
#
# Output:
#   stdout : sandbox path (one line) on success.
#   stderr : ERROR line on mktemp failure.
#
# Exit code semantics:
#   exit 1   — hard-fail (default): mktemp -d failure halts the run.
#   return 1 — soft-fail (--soft):  same failure, but caller decides skip vs. test failure.
#   return 2 — option parse error:  unknown option.
#
# Caller pattern:
#   sbx=$(make_plain_sandbox); cleanup_dirs+=("$sbx")
#   if ! sbx=$(make_plain_sandbox --soft); then skip "TC-N (sandbox setup failed)"; fi
make_plain_sandbox() {
  local soft_fail=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --soft)
        soft_fail=1
        shift
        ;;
      *)
        echo "ERROR: make_plain_sandbox: unknown option '$1'" >&2
        return 2
        ;;
    esac
  done

  local d
  d=$(mktemp -d) || {
    echo "ERROR: make_plain_sandbox: mktemp -d failed" >&2
    [ "$soft_fail" -eq 1 ] && return 1
    exit 1
  }
  # Canonicalize so the sandbox root matches production's realpath/pwd -P view
  # (macOS $TMPDIR is under the /private-symlinked /var/folders). See make_sandbox.
  # Fail closed: emitting an empty path here would make callers' `cd "$sbx"` a
  # no-op (bash `cd ""` returns 0) and land their fixtures in the caller's CWD.
  local d_canon
  d_canon=$(cd "$d" && pwd -P) || {
    echo "ERROR: make_plain_sandbox: failed to canonicalize sandbox root '$d'" >&2
    [ "$soft_fail" -eq 1 ] && return 1
    exit 1
  }
  echo "$d_canon"
}

# Print summary block and return non-zero when any assertion failed.
# When FAILED_NAMES is non-empty, lists them so callers don't need to duplicate
# the "Failed assertions:" loop in every test file.
# drift_hint_text (optional) is echoed verbatim after the failure list — used by
# tests like 4-site-symmetry that point readers at canonical anchor docs.
# Writes everything to stdout (see "Output convention" in the file header).
print_summary() {
  local test_name="${1:-summary}"
  local drift_hint="${2:-}"
  echo
  echo "─── $test_name summary ──────────────────────"
  echo "PASS: $PASS"
  echo "FAIL: $FAIL"
  [ "${SKIP:-0}" -gt 0 ] && echo "SKIP: $SKIP"
  if [ "$FAIL" -ne 0 ]; then
    if [ "${#FAILED_NAMES[@]}" -gt 0 ]; then
      echo "Failed assertions:"
      local n
      for n in "${FAILED_NAMES[@]}"; do
        echo "  - $n"
      done
    fi
    if [ -n "$drift_hint" ]; then
      echo
      printf '%s\n' "$drift_hint"
    fi
    return 1
  fi
  return 0
}
