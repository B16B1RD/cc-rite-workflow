#!/bin/bash
# Tests for hooks/scripts/lib/tempfile.sh
#
# The lib exists to make three recurring defects unwritable, so the tests pin
# the three corresponding boundaries rather than the happy path alone:
#   - a mktemp failure is loud and returns non-zero (it must never degrade into
#     an empty path the caller then redirects into),
#   - a tempfile is gone after INT/TERM/HUP, not just after a normal exit,
#   - creating a tempfile before the handlers are installed is refused.
# Plus the composition contract: a caller that owns its own EXIT handler gets a
# refusal from the default init and an explicit --caller-traps path instead.
#
# Signals are delivered by the child script to itself (`kill -INT $$`) so the
# assertion does not race a background process.
#
# Convention: mktemp sandbox, no network, no gh, GNU/BSD portable.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

LIB="$SCRIPT_DIR/../scripts/lib/tempfile.sh"

echo "=== tempfile.sh lib tests ==="

if [ ! -f "$LIB" ]; then
  echo "ERROR: $LIB not found" >&2
  exit 1
fi

SANDBOX="$(make_plain_sandbox)"
cleanup() { [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"; }
trap 'rc=$?; cleanup; exit $rc' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

# Every child script writes the paths it created to this file so the parent can
# assert on them after the child is gone.
PATHLOG="$SANDBOX/paths.log"

# Run a child bash script that sources the lib. $1 = script body, rest = env
# assignments prefixed to the invocation. Echoes the child's exit code.
#
# PATHLOG is truncated first. Without that, a child that dies before writing it
# leaves the previous case's (already-deleted) path in place, and the reader sees
# "gone" for a file that was never created.
run_child() {
  local body="$1"; shift
  local script="$SANDBOX/child.sh"
  : > "$PATHLOG"
  {
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' 'set -uo pipefail'
    printf 'source "%s"\n' "$LIB"
    printf '%s\n' "$body"
  } > "$script"
  ( cd "$SANDBOX" && env "$@" bash "$script" ) >"$SANDBOX/out" 2>"$SANDBOX/err"
  echo $?
}

# --- T-01: happy path — creation, registration, cleanup on normal exit -------
rc=$(run_child '
rite_tempfile_init || exit 90
rite_tempfile_new f "unit" || exit 91
[ -f "$f" ] || exit 92
printf "%s\n" "$f" > "'"$PATHLOG"'"
' TMPDIR="$SANDBOX")
assert "T-01 happy path exits 0" "0" "$rc"
created="$(cat "$PATHLOG" 2>/dev/null || true)"
if [ -n "$created" ]; then
  pass "T-01 rite_tempfile_new assigned a path to the caller's variable"
  assert "T-01 the file is removed once the child exits" "gone" \
    "$([ -e "$created" ] && echo present || echo gone)"
  case "$created" in
    "$SANDBOX"/rite-unit-*) pass "T-01 path honours TMPDIR and the rite-<tag>- template" ;;
    *) fail "T-01 unexpected path shape: $created" ;;
  esac
else
  fail "T-01 no path was recorded (rite_tempfile_new did not assign)"
fi

# --- T-01b: rite_tempdir_new ------------------------------------------------
# `: > "$d/inside"` is the assertion that matters here: a tempdir chmod'd 600
# (the file mode) is not traversable, so anything written inside it fails.
rc=$(run_child '
rite_tempfile_init || exit 90
rite_tempdir_new d "unitdir" || exit 91
[ -d "$d" ] || exit 92
: > "$d/inside" || exit 93
[ -f "$d/inside" ] || exit 94
printf "%s\n" "$d" > "'"$PATHLOG"'"
' TMPDIR="$SANDBOX")
assert "T-01b rite_tempdir_new yields a writable directory" "0" "$rc"
created_dir="$(cat "$PATHLOG" 2>/dev/null || true)"
if [ -n "$created_dir" ]; then
  assert "T-01b the directory and its contents are removed on exit" "gone" \
    "$([ -e "$created_dir" ] && echo present || echo gone)"
else
  fail "T-01b no path was recorded (rite_tempdir_new did not assign)"
fi

# --- T-01c: sourcing twice keeps the registry ------------------------------
# The second source must not reset _RITE_TMP_PATHS. If it does, the exit handler
# has nothing to remove and the file created before it survives the process.
rc=$(run_child '
rite_tempfile_init || exit 90
rite_tempfile_new f "double-src" || exit 91
printf "secret" > "$f"
printf "%s\n" "$f" > "'"$PATHLOG"'"
source "'"$LIB"'"
[ "${#_RITE_TMP_PATHS[@]}" -eq 1 ] || exit 92
' TMPDIR="$SANDBOX")
assert "T-01c a second source leaves the registry intact" "0" "$rc"
dsrc_path="$(cat "$PATHLOG" 2>/dev/null || true)"
if [ -n "$dsrc_path" ]; then
  assert "T-01c the file created before the re-source is still removed on exit" "gone" \
    "$([ -e "$dsrc_path" ] && echo present || echo gone)"
else
  fail "T-01c no path was recorded"
fi

# --- T-02: mktemp failure is loud and non-zero ------------------------------
rc=$(run_child '
rite_tempfile_init || exit 90
new_rc=0; rite_tempfile_new f "failcase" || new_rc=$?
[ -z "${f:-}" ] || exit 81   # a failed create must leave no half-assigned path
exit "$new_rc"
' TMPDIR="$SANDBOX/definitely/not/here")
assert "T-02 rite_tempfile_new returns non-zero when mktemp fails" "1" "$rc"
assert_grep "T-02 the failure is reported on stderr, not swallowed" "$SANDBOX/err" \
  'ERROR: rite_tempfile: mktemp failed'

# The dir branch is duplicated code with its own diagnostic and its own return,
# and it is the only one with a production caller — its failure path needs its
# own assertions, not the file branch's.
rc=$(run_child '
rite_tempfile_init || exit 90
new_rc=0; rite_tempdir_new d "failcase" || new_rc=$?
[ -z "${d:-}" ] || exit 81
exit "$new_rc"
' TMPDIR="$SANDBOX/definitely/not/here")
assert "T-02a rite_tempdir_new returns non-zero when mktemp -d fails" "1" "$rc"
assert_grep "T-02a the dir branch has its own diagnostic" "$SANDBOX/err" \
  'ERROR: rite_tempfile: mktemp -d failed'

# --- T-02b: the signal handlers themselves do the cleanup -------------------
# The child drops its EXIT handler before signalling. Without that, bash runs the
# EXIT trap on the way out of a fatal signal too, so both the exit code and the
# vanished file are satisfied by the EXIT handler alone and the assertion cannot
# tell whether the INT/TERM/HUP handlers exist at all (verified: deleting those
# three lines from the lib left the whole suite green).
for sig_case in "INT 130" "TERM 143" "HUP 129"; do
  set -- $sig_case
  signame="$1"; expected_rc="$2"
  # Only an *ignored* disposition is inherited by the child — a handler this
  # script installed for itself is reset to default there, so it is irrelevant.
  # An ignored signal cannot be trapped or delivered, so the lib skips it on
  # purpose and these assertions have nothing to observe (nohup ignores HUP,
  # async children inherit an ignored INT).
  case "$(trap -p "$signame")" in
    "trap -- '' "*)
      skip "T-02b $signame (inherited as ignored in this environment — cannot be trapped)"
      continue
      ;;
  esac
  rc=$(run_child '
rite_tempfile_init || exit 90
rite_tempfile_new f "sig-'"$(printf '%s' "$signame" | tr 'A-Z' 'a-z')"'" || exit 91
printf "%s\n" "$f" > "'"$PATHLOG"'"
trap - EXIT
kill -'"$signame"' $$
sleep 5
' TMPDIR="$SANDBOX")
  assert "T-02b $signame exits $expected_rc with no EXIT handler present" "$expected_rc" "$rc"
  sig_path="$(cat "$PATHLOG" 2>/dev/null || true)"
  if [ -n "$sig_path" ]; then
    assert "T-02b the $signame handler removed the tempfile" "gone" \
      "$([ -e "$sig_path" ] && echo present || echo gone)"
  else
    fail "T-02b $signame: no path was recorded"
  fi
done

# The handlers are also asserted by name, so a future refactor that leaves them
# installed but pointing elsewhere is visible.
# A `case` rather than a pipe into grep -q: under pipefail the consumer's early
# exit can hand the producer a SIGPIPE and turn the pipeline into a false 141.
rc=$(run_child '
rite_tempfile_init || exit 90
for s in INT TERM HUP; do
  # Skip a signal the process inherited as ignored: the lib leaves those alone
  # on purpose and bash could not install a handler for them anyway.
  case "$(trap -p "$s")" in "trap -- '"''"' "*) continue ;; esac
  case "$(trap -p "$s")" in *rite_tempfile_cleanup*) ;; *) exit 92 ;; esac
done
' TMPDIR="$SANDBOX")
assert "T-02b every signal handler the lib installed calls rite_tempfile_cleanup" "0" "$rc"

# A signal inherited as ignored is not a caller handler. `trap -p` reports it as
# a non-empty `trap -- '' SIG`, so a plain length test refuses to initialise
# under nohup or in an async child and blames a handler nobody wrote.
rc=$(run_child '
trap "" INT
init_rc=0; rite_tempfile_init || init_rc=$?
[ "$init_rc" -eq 0 ] || exit 90
rite_tempfile_new f "sigign" || exit 91
case "$(trap -p TERM)" in *rite_tempfile_cleanup*) ;; *) exit 92 ;; esac
' TMPDIR="$SANDBOX")
assert "T-02b an inherited SIG_IGN is skipped, not treated as a caller handler" "0" "$rc"

# Calling init twice must stay a no-op — otherwise the second call finds its own
# EXIT handler and refuses.
rc=$(run_child '
rite_tempfile_init || exit 90
rite_tempfile_init || exit 91
' TMPDIR="$SANDBOX")
assert "T-02b rite_tempfile_init is idempotent" "0" "$rc"

# --- T-02c: creating before init is refused ---------------------------------
rc=$(run_child '
new_rc=0; rite_tempfile_new f "no-init" || new_rc=$?
exit "$new_rc"
' TMPDIR="$SANDBOX")
assert "T-02c rite_tempfile_new before init returns non-zero" "1" "$rc"
assert_grep "T-02c the refusal names the missing init" "$SANDBOX/err" \
  'call rite_tempfile_init before creating a tempfile'

# --- T-02d: init refuses to clobber an existing EXIT handler ----------------
rc=$(run_child '
trap "echo caller-exit-handler-ran" EXIT
if rite_tempfile_init; then
  exit 80
fi
exit 0
' TMPDIR="$SANDBOX")
assert "T-02d init returns non-zero when an EXIT handler already exists" "0" "$rc"
assert_grep "T-02d the refusal points at --caller-traps" "$SANDBOX/err" \
  'rite_tempfile_init --caller-traps'
assert_grep "T-02d the caller's own EXIT handler still ran" "$SANDBOX/out" \
  'caller-exit-handler-ran'

# `trap '' EXIT` must be refused too. EXIT is not a signal, so it is never
# inherited as ignored — the ignore form only appears because the caller wrote
# it, and unlike an ignored signal it still fires. Exempting it the way the
# INT/TERM/HUP inherited-SIG_IGN case is exempted returns success with no
# cleanup arranged, which is the leak this lib exists to remove.
rc=$(run_child '
trap "" EXIT
init_rc=0; rite_tempfile_init || init_rc=$?
[ "$init_rc" -eq 1 ] || exit 80
exit 0
' TMPDIR="$SANDBOX")
assert "T-02d init refuses an EXIT handler set to ignore" "0" "$rc"
assert_grep "T-02d the ignore-form refusal names EXIT" "$SANDBOX/err" \
  'a EXIT handler is already installed'

# The same refusal must cover the signal handlers — checking EXIT alone leaves
# the caller's INT/TERM/HUP handlers to be clobbered without a word.
for existing_sig in INT TERM HUP; do
  # An inherited SIG_IGN cannot be replaced by a real handler, so the child
  # cannot set up the precondition this case needs.
  case "$(trap -p "$existing_sig")" in
    "trap -- '' "*)
      skip "T-02d $existing_sig (inherited as ignored in this environment — cannot install a handler to collide with)"
      continue
      ;;
  esac
  rc=$(run_child '
trap "exit 7" '"$existing_sig"'
init_rc=0; rite_tempfile_init || init_rc=$?
exit "$init_rc"
' TMPDIR="$SANDBOX")
  assert "T-02d init refuses when an $existing_sig handler already exists" "1" "$rc"
  assert_grep "T-02d the $existing_sig refusal names the signal" "$SANDBOX/err" \
    "a $existing_sig handler is already installed"
done

# --- T-02e: --caller-traps composes with a caller-owned handler -------------
rc=$(run_child '
_own_cleanup() { rite_tempfile_cleanup; echo "own-handler-ran"; }
trap "rc=\$?; _own_cleanup; exit \$rc" EXIT
rite_tempfile_init --caller-traps || exit 90
rite_tempfile_new f "composed" || exit 91
printf "%s\n" "$f" > "'"$PATHLOG"'"
' TMPDIR="$SANDBOX")
assert "T-02e --caller-traps path exits 0" "0" "$rc"
assert_grep "T-02e the caller's handler ran" "$SANDBOX/out" 'own-handler-ran'
composed_path="$(cat "$PATHLOG" 2>/dev/null || true)"
assert "T-02e rite_tempfile_cleanup removed the file from the caller's handler" "gone" \
  "$([ -n "$composed_path" ] && [ -e "$composed_path" ] && echo present || echo gone)"

# --- T-02f: argument validation ---------------------------------------------
rc=$(run_child '
rite_tempfile_init || exit 90
name_rc=0; rite_tempfile_new "bad name" "x" || name_rc=$?
[ "$name_rc" -eq 1 ] || exit 80
tag_rc=0; rite_tempfile_new "ok" "../escape" || tag_rc=$?
exit "$tag_rc"
' TMPDIR="$SANDBOX")
assert "T-02f invalid out-variable / tag are both refused" "1" "$rc"
assert_grep "T-02f the tag charset refusal is explicit" "$SANDBOX/err" \
  "tag '\.\./escape' contains characters outside"

# A bracket name is the case the identifier check actually exists for. Unlike
# `bad name`, which bash rejects on its own, `printf -v 'a[0]'` succeeds — it is
# an array write. Without this pin, deleting the check leaves the suite green
# while `rite_tempfile_new 'PATH[0]'` corrupts PATH and returns 0.
rc=$(run_child '
rite_tempfile_init || exit 90
br_rc=0; rite_tempfile_new "a[0]" "x" || br_rc=$?
[ "$br_rc" -eq 1 ] || exit 79
exit 0
' TMPDIR="$SANDBOX")
assert "T-02f an out-variable naming an array element is refused" "0" "$rc"
assert_grep "T-02f the bracket-name refusal is explicit" "$SANDBOX/err" \
  "is not a valid variable name"

# A failed assignment must not return success. The path is already registered by
# then, so the file is still reclaimed — but the caller's variable holds its old
# value, and returning 0 would send the caller off to write to it.
rc=$(run_child '
rite_tempfile_init || exit 90
readonly f=preset
ro_rc=0; rite_tempfile_new f "ro" || ro_rc=$?
[ "$ro_rc" -eq 1 ] || exit 79
[ "$f" = "preset" ] || exit 78
[ "${#_RITE_TMP_PATHS[@]}" -eq 1 ] || exit 77
exit 0
' TMPDIR="$SANDBOX")
assert "T-02f a readonly out-variable fails loudly and still registers the path" "0" "$rc"
assert_grep "T-02f the assignment failure is reported" "$SANDBOX/err" \
  'could not assign the path'

# An unknown flag must not be swallowed into the installed-traps default: a
# caller that typo'd --caller-trap would silently get the opposite mode.
rc=$(run_child '
init_rc=0; rite_tempfile_init --nope || init_rc=$?
[ "$init_rc" -eq 1 ] || exit 80
exit 0
' TMPDIR="$SANDBOX")
assert "T-02f an unknown init argument is refused" "0" "$rc"
assert_grep "T-02f the unknown-argument refusal names the flag" "$SANDBOX/err" \
  "unknown argument '--nope'"

# The lib's own namespace is reserved. `printf -v _RITE_TMP_PATHS` would write
# element 0 of the live registry while returning success.
rc=$(run_child '
rite_tempfile_init || exit 90
rite_tempfile_new keep "reg-keep" || exit 91
ns_rc=0; rite_tempfile_new _RITE_TMP_PATHS "clobber" || ns_rc=$?
[ "$ns_rc" -eq 1 ] || exit 80
[ "${#_RITE_TMP_PATHS[@]}" -eq 1 ] || exit 81
[ "${_RITE_TMP_PATHS[0]}" = "$keep" ] || exit 82
' TMPDIR="$SANDBOX")
assert "T-02f a reserved lib name is refused and the registry is intact" "0" "$rc"
assert_grep "T-02f the refusal names the reserved namespace" "$SANDBOX/err" \
  "is reserved for the lib's own namespace"

# A caller variable that happens to match one of the function's locals must
# still receive the path.
rc=$(run_child '
rite_tempfile_init || exit 90
rite_tempfile_new path "localname" || exit 91
[ -n "${path:-}" ] || exit 92
[ -f "$path" ] || exit 93
' TMPDIR="$SANDBOX")
assert "T-02f an out-variable named like a lib local is still assigned" "0" "$rc"

# --- T-02g: executing instead of sourcing is refused ------------------------
exec_rc=$(bash "$LIB" >/dev/null 2>"$SANDBOX/err_exec"; echo $?)
assert "T-02g running the lib as a script exits 2" "2" "$exec_rc"
assert_grep "T-02g the refusal explains why sourcing is required" "$SANDBOX/err_exec" \
  'must be sourced, not executed'

print_summary "$(basename "$0")"
