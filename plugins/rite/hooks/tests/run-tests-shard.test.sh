#!/bin/bash
# Exercise scheduling through actual runner progress, using isolated stub suites.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_hermetic-env.sh" || exit 1
TEST_DIR=$(mktemp -d) || exit 1
trap 'rm -rf "$TEST_DIR"' EXIT
python3 - "$SCRIPT_DIR" "$TEST_DIR" <<'PY'
from pathlib import Path
import re
import shutil
import subprocess
import sys

source, root = map(Path, sys.argv[1:])
d = root / 'hooks' / 'tests'
sibling = root / 'hooks' / 'scripts' / 'tests'
d.mkdir(parents=True)
sibling.mkdir(parents=True)
shutil.copy(source / 'run-tests.sh', d / 'runner.sh')
shutil.copy(source / '_hermetic-env.sh', d)
priority = [
    'cleanup-follow-up-issue.test.sh', 'review-commit-guard.test.sh',
    'review-stagnation-breaker.test.sh', 'review-stagnation-retry.test.sh',
    'pre-tool-bash-guard.test.sh', 'review-stagnation-cleanup.test.sh',
    'session-start.test.sh', 'pr-cycle-cleanup-session-reap.test.sh',
    'wiki-apply-gate.test.sh', 'review-helpers-gate-behavior.test.sh',
]
for name in priority + ['a.test.sh', 'z.test.sh']:
    (d / name).write_text('exit 0\n')
for name in ['test-a.sh', 'test-z.sh']:
    (sibling / name).write_text('exit 0\n')
expected = ['hooks/tests/' + name for name in priority]
remainder = ['hooks/tests/a.test.sh', 'hooks/tests/z.test.sh',
             'hooks/scripts/tests/test-a.sh', 'hooks/scripts/tests/test-z.sh']

def run(*args):
    return subprocess.run(['bash', str(d / 'runner.sh'), *args],
                          capture_output=True, text=True, timeout=20)

def starts(result):
    return re.findall(r'^TEST_START id=\d+ file=(\S+)', result.stdout, re.M)

def check(condition, message):
    if not condition:
        raise AssertionError(message)

whole = run()
check(whole.returncode == 0 and starts(whole) == expected + remainder,
      'default execution must include both globs in longest-first order')
check('Results: 14/14 passed, 0 failed\nAll tests passed!\n' in whole.stdout,
      'default summary and success format changed')
one = run('--shard', '1/1')
check(one.returncode == 0 and starts(one) == starts(whole), '1/1 differs from default')
union = []
for i in range(1, 4):
    result = run('--shard', f'{i}/3', '--jobs', '1')
    want = expected[i-1::3] + remainder[i-1::3]
    check(result.returncode == 0 and starts(result) == want,
          f'shard {i}/3 must round-robin both groups and preserve their order')
    union.extend(starts(result))
check(len(union) == len(set(union)) == 14 and set(union) == set(starts(whole)),
      'shards must cover all files exactly once')
reverse = run('--jobs', '1', '--shard', '1/3')
check(reverse.returncode == 0 and starts(reverse) == expected[::3] + remainder[::3],
      'option order must not affect scheduling')
leading = run('--shard', '01/03', '--jobs', '01')
check(leading.returncode == 0 and starts(leading) == starts(reverse),
      'decimal arguments with leading zeroes must work')
for value in ('0/3', '4/3', 'a/b', '1/0', '1', '1/2/3', '/3', '1/', '-1/3', '1:2/3'):
    result = run('--shard', value)
    check(result.returncode == 2 and 'Usage:' in result.stderr and not starts(result),
          f'invalid shard {value!r} must fail before execution with usage')
for args in (['--shard'], ['--jobs'], ('--jobs', '0'), ('--jobs', 'x'),
             ('--unknown', '1'), ('--shard', '1/3', '--shard', '2/3')):
    result = run(*args)
    check(result.returncode == 2 and 'Usage:' in result.stderr, f'invalid options {args!r}')
for value in ('14/14', '999999999999999999999/999999999999999999999'):
    result = run('--shard', value)
    check(result.returncode == 0 and not starts(result) and
          'Results: 0/0 passed, 0 failed\nAll tests passed!\n' in result.stdout,
          'valid empty shard must succeed with an unchanged zero-file summary')
large = run('--shard', '1/999999999999999999999')
check(large.returncode == 0 and starts(large) == [expected[0], remainder[0]],
      'large valid counts must not overflow modulo arithmetic')
(d / 'a.test.sh').write_text('exit 1\n')
broken = run()
check(broken.returncode == 1 and 'Results: 13/14 passed, 1 failed\n' in broken.stdout and
      '  - a.test.sh\n' in broken.stdout and 'All tests passed!' not in broken.stdout,
      'default failure status, summary and failure list must be preserved')
(d / priority[0]).unlink()
missing = run('--shard', '3/3')
check(missing.returncode == 1 and
      f'ERROR: priority list entry not found: {priority[0]}' in missing.stderr and
      not starts(missing), 'stale priority list must fail before any test starts')
print('Scheduling, shard coverage, argument errors and default regression: passed')
PY
