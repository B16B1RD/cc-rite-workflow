#!/bin/bash
# Run all rite hook tests
# Usage: bash plugins/rite/hooks/tests/run-tests.sh [--jobs N]
set -euo pipefail

JOBS=4
usage() {
  echo "Usage: $0 [--jobs N] (N must be a positive integer)" >&2
  exit 2
}
if [ "$#" -gt 0 ]; then
  [ "$#" -eq 2 ] && [ "$1" = --jobs ] || usage
  JOBS=$2
  case "$JOBS" in ''|*[!0-9]*) usage ;; esac
  # Normalize leading zeroes without arithmetic overflow for large valid values.
  JOBS=${JOBS#"${JOBS%%[!0]*}"}
  [ -n "$JOBS" ] || usage
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Runtime identity and state-root inputs must come only from each fixture.
# shellcheck source=_hermetic-env.sh
source "$SCRIPT_DIR/_hermetic-env.sh" || { echo "ERROR: cannot source _hermetic-env.sh" >&2; exit 1; }

TOTAL=0
PASSED=0
FAILED=0
FAILED_TESTS=()

# Discover test files from BOTH conventions/locations:
#   1. this dir's `*.test.sh` — the hook/entry-point suite
#   2. the sibling `hooks/scripts/tests/test-*.sh` — the checker suite for
#      hooks/scripts/ scripts. It uses a `test-*.sh` name in a separate
#      directory, so the `*.test.sh` glob never reached it and those tests
#      ran nowhere despite existing. Collecting both into one list keeps a
#      single runner as the single source of test execution.
test_files=()
for f in "$SCRIPT_DIR"/*.test.sh; do
  [ -f "$f" ] && test_files+=("$f")
done
for f in "$SCRIPT_DIR"/../scripts/tests/test-*.sh; do
  [ -f "$f" ] && test_files+=("$f")
done

# Each asynchronous worker owns a process group, including its test's children.
# Monitor mode is available in macOS Bash 3.2; no setsid or wait -n is needed.
# Workers disable it so ordinary descendants stay in that worker's group.
run_dir=$(mktemp -d "${TMPDIR:-/tmp}/rite-hook-tests.XXXXXX")
active_pids=()
active_ids=()
active_files=()
run_started=$SECONDS
launch_in_progress=0
pending_signal=0
cleanup() {
  rm -rf "$run_dir"
}
# Snapshot descendants before terminating supervisors: the portable timeout
# helper and recursive runners can create process groups of their own.
owned_descendants() {
  ps -ax -o pid= -o ppid= -o pgid= | awk -v roots=" $* " '
    { parent[$1]=$2; group[$1]=$3 }
    END {
      for (pid in parent)
        if (index(roots, " " pid " ") || index(roots, " " group[pid] " ")) owned[pid]=1
      do {
        changed=0
        for (pid in parent)
          if (!owned[pid] && owned[parent[pid]]) { owned[pid]=1; changed=1 }
      } while (changed)
      for (pid in owned) if (owned[pid]) print pid
    }'
}
interrupt_run() {
  local status=$1 i pid
  local descendants=()
  # Do not lose a child if a signal lands between spawning it and recording $!.
  if [ "$launch_in_progress" -eq 1 ]; then
    pending_signal=$status
    return
  fi
  trap '' TERM INT
  set +m
  while read -r pid; do
    [ -n "$pid" ] && descendants+=("$pid")
  done < <(owned_descendants ${active_pids[@]+"${active_pids[@]}"})
  if [ "${#descendants[@]}" -gt 0 ]; then
    kill -TERM "${descendants[@]}" 2>/dev/null || true
  fi
  for ((i=0; i<${#active_pids[@]}; i++)); do
    pid=${active_pids[$i]}
    if [ ! -f "$run_dir/${active_ids[$i]}.result" ]; then
      printf 'TEST_INCOMPLETE id=%s file=%s elapsed_s=%s\n' \
        "${active_ids[$i]}" "${active_files[$i]}" "$((SECONDS - run_started))"
    fi
    kill -TERM -- "-$pid" 2>/dev/null || true
  done
  # Bound cleanup even when a test ignores TERM, then reap each owned worker.
  sleep 0.1
  if [ "${#descendants[@]}" -gt 0 ]; then
    kill -KILL "${descendants[@]}" 2>/dev/null || true
  fi
  for pid in ${active_pids[@]+"${active_pids[@]}"}; do
    kill -KILL -- "-$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  exit "$status"
}
trap cleanup EXIT
trap 'interrupt_run 143' TERM
trap 'interrupt_run 130' INT

# Roll the per-file skip counts up into the headline. Without this, a platform-gated
# run prints a headline byte-identical to a fully-exercised one, and the reader has
# to scroll the whole log to learn that (for example) 10 groups of assertions never
# ran on macOS. The count is parsed from what the files already print — `SKIP: N`
# from print_summary, or `, N skipped` from the three files with their own summary.
SKIPPED=0
SKIP_ACCOUNTING_BROKEN=0
next_test=0
next_output=1
test_rcs=()
marker_files=()
while [ "$next_test" -lt "${#test_files[@]}" ] || [ "${#active_pids[@]}" -gt 0 ]; do
  set -m
  while [ "$next_test" -lt "${#test_files[@]}" ] && [ "${#active_pids[@]}" != "$JOBS" ]; do
    test_file=${test_files[$next_test]}
    test_id=$((next_test + 1))
    case "$test_file" in
      "$SCRIPT_DIR"/../scripts/tests/*) marker_file="hooks/scripts/tests/$(basename "$test_file")" ;;
      *) marker_file="hooks/tests/$(basename "$test_file")" ;;
    esac
    launch_in_progress=1
    (
      set +m
      # The parent publishes the PID before allowing any output from this test.
      while [ ! -f "$run_dir/$test_id.start" ]; do sleep 0.01; done
      started=$SECONDS
      rc=0
      bash "$test_file" > "$run_dir/$test_id.output" 2>&1 || rc=$?
      printf 'TEST_END id=%s file=%s rc=%s duration_s=%s\n' \
        "$test_id" "$marker_file" "$rc" "$((SECONDS - started))"
      printf '%s\n' "$rc" > "$run_dir/$test_id.result"
      exit "$rc"
    ) &
    worker_pid=$!
    active_pids+=("$worker_pid")
    active_ids+=("$test_id")
    active_files+=("$marker_file")
    marker_files[$test_id]=$marker_file
    printf 'TEST_START id=%s file=%s pid=%s elapsed_s=%s\n' \
      "$test_id" "$marker_file" "$worker_pid" "$((SECONDS - run_started))"
    : > "$run_dir/$test_id.start"
    launch_in_progress=0
    if [ "$pending_signal" -ne 0 ]; then interrupt_run "$pending_signal"; fi
    next_test=$((next_test + 1))
  done
  set +m
  # Poll only owned workers; wait by PID remains the authority for exit status.
  # Refill a freed slot without waiting for slower peers (including on Bash 3.2).
  remaining_pids=()
  remaining_ids=()
  remaining_files=()
  reaped=0
  for ((active_index=0; active_index<${#active_pids[@]}; active_index++)); do
    worker_pid=${active_pids[$active_index]}
    test_id=${active_ids[$active_index]}
    if [ -f "$run_dir/$test_id.result" ] || ! kill -0 "$worker_pid" 2>/dev/null; then
      worker_rc=0
      wait "$worker_pid" || worker_rc=$?
      test_rcs[$test_id]=$worker_rc
      reaped=1
      if [ ! -f "$run_dir/$test_id.result" ]; then
        # Seed by the worker's group as its PID may already have been reaped.
        while read -r child_pid; do
          [ -n "$child_pid" ] && kill -KILL "$child_pid" 2>/dev/null || true
        done < <(owned_descendants "$worker_pid")
        kill -KILL -- "-$worker_pid" 2>/dev/null || true
      fi
    else
      remaining_pids+=("$worker_pid")
      remaining_ids+=("$test_id")
      remaining_files+=("${active_files[$active_index]}")
    fi
  done
  launch_in_progress=1
  active_pids=(${remaining_pids[@]+"${remaining_pids[@]}"})
  active_ids=(${remaining_ids[@]+"${remaining_ids[@]}"})
  active_files=(${remaining_files[@]+"${remaining_files[@]}"})
  launch_in_progress=0
  if [ "$pending_signal" -ne 0 ]; then interrupt_run "$pending_signal"; fi

  if [ "$reaped" -eq 0 ] && [ "${#active_pids[@]}" -gt 0 ]; then sleep 0.05; fi
done

# All live progress writers have exited before the parent emits captured bodies.
while [ "$next_output" -le "${#test_files[@]}" ]; do
  test_id=$next_output
  test_file=${test_files[$((test_id - 1))]}
  test_name="$(basename "$test_file")"
  TOTAL=$((TOTAL + 1))
  printf 'TEST_OUTPUT_BEGIN id=%s file=%s\n' "$test_id" "${marker_files[$test_id]}"
  echo "=== Running: $test_name ==="
  test_rc=${test_rcs[$test_id]}
  result_rc=
  if [ -f "$run_dir/$test_id.result" ]; then
    read -r result_rc < "$run_dir/$test_id.result" || true
  fi
  if [ "$result_rc" != "$test_rc" ]; then
    echo "ERROR: $test_name worker result missing or inconsistent (wait rc=$test_rc)" >&2
    [ "$test_rc" -ne 0 ] || test_rc=1
  fi
  # Valid UTF-8 (Japanese, emoji) is unchanged. Invalid sequences (raw C1
  # 0x80-0x9f, orphaned lead bytes) become U+FFFD so BSD sed/grep and the
  # GHA macos Worker log flush do not die with EILSEQ (no uploaded logs).
  # Read directly from the capture file: background writers cannot hold a command
  # substitution pipe open, and invalid bytes never enter a shell variable.
  [ -f "$run_dir/$test_id.output" ] || : > "$run_dir/$test_id.output"
  if command -v python3 >/dev/null 2>&1 \
     && test_out=$(python3 -c 'import sys; sys.stdout.buffer.write(sys.stdin.buffer.read().decode("utf-8", "replace").encode("utf-8"))' < "$run_dir/$test_id.output"); then
    :
  else
    test_out=$(LC_ALL=C tr '\000-\010\013-\037\177\200-\237' '[?*]' < "$run_dir/$test_id.output")
  fi
  printf '%s\n' "$test_out"
  printf 'TEST_OUTPUT_END id=%s\n' "$test_id"
  if [ "$test_rc" -eq 0 ]; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    FAILED_TESTS+=("$test_name")
  fi
  # Anchor both forms to a summary line rather than matching anywhere: a failure
  # diagnostic quoting ", 7 skipped" would otherwise be counted as seven skips.
  # A file emits one form or the other, so take whichever appears and stop —
  # summing both would double-count a file that ever printed both.
  file_skips=$(printf '%s\n' "$test_out" \
    | sed -n -E 's/^[[:space:]]*SKIP: ([0-9]+)[[:space:]]*$/\1/p' \
    | awk '{s += $1} END {print s + 0}')
  case "$file_skips" in ''|*[!0-9]*) file_skips=0 ;; esac
  if [ "$file_skips" -eq 0 ]; then
    file_skips=$(printf '%s\n' "$test_out" \
      | sed -n -E 's/^[^❌]*Results:[^❌]*, ([0-9]+) skipped.*$/\1/p' \
      | awk '{s += $1} END {print s + 0}')
    case "$file_skips" in ''|*[!0-9]*) file_skips=0 ;; esac
  fi
  # Cross-check the parsed count against the visible markers. A mismatch in either
  # direction means the file reports skips in a shape the runner does not know
  # about, and the undercount is exactly what this accounting exists to prevent —
  # so it FAILS the run rather than only warning. Counting only the zero case
  # would miss a file that mixes counted skip() calls with bare echoes.
  visible_skips=$(printf '%s\n' "$test_out" | grep -c '⏭️' || true)
  case "$visible_skips" in ''|*[!0-9]*) visible_skips=0 ;; esac
  if [ "$visible_skips" -ne "$file_skips" ]; then
    echo "ERROR: $test_name printed $visible_skips skip marker(s) but the summary reported $file_skips — summary format drift, the skip total below is wrong" >&2
    SKIP_ACCOUNTING_BROKEN=1
  fi
  SKIPPED=$((SKIPPED + file_skips))
  echo ""
  next_output=$((next_output + 1))
done

echo "==============================="
if [ "$SKIPPED" -gt 0 ]; then
  # "gated group(s)", not "skipped": the unit is a skip call, and one call can gate
  # anywhere from one to eleven assertions. Naming it precisely stops the number
  # from being read as an assertion count it is not.
  echo "Results: $PASSED/$TOTAL passed, $FAILED failed, $SKIPPED gated group(s) skipped"
else
  echo "Results: $PASSED/$TOTAL passed, $FAILED failed"
fi
# The failure list comes before the accounting bail: both exit 1, and bailing
# first would swallow the only line that names which files failed. Drift and a
# real failure land together whenever a set -e test aborts after a skip() call
# but before its summary, so the two diagnostics have to coexist.
if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
  echo "Failed tests:"
  for t in "${FAILED_TESTS[@]}"; do
    echo "  - $t"
  done
fi
if [ "$SKIP_ACCOUNTING_BROKEN" -eq 1 ]; then
  echo "Skip accounting is unreliable for this run (see the ERROR lines above)."
  exit 1
fi
if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
  exit 1
fi
# The gated-group count rides on the success line too (mirrors run-all.sh): a bare
# "All tests passed!" under a run that skipped ten groups reads as full coverage,
# which is the exact misreading the counting exists to prevent.
echo "All tests passed!$( [ "$SKIPPED" -gt 0 ] && printf ' (%s gated group(s) skipped)' "$SKIPPED" )"
