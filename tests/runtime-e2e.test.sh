#!/usr/bin/env bash
set -euo pipefail

# These are offline contract tests. Synthetic evidence is a stub, not host E2E proof.
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_THREAD_ID GROK_SESSION_ID RITE_HOST
unset CLAUDE_ENV_FILE RITE_STATE_ROOT RITE_RUNTIME_EXPLICIT _RITE_HOOK_REDIRECTED
unset RITE_PLUGIN_ROOT CLAUDE_PLUGIN_ROOT
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PREPARE="$SCRIPT_DIR/runtime-e2e/prepare.sh"
RESULTS="$SCRIPT_DIR/runtime-e2e/results.py"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
PASS=0
FAIL=0

assert_rc() {
  local label=$1 expected=$2 actual=0
  shift 2
  "$@" >"$TEST_ROOT/output" 2>&1 || actual=$?
  if [ "$actual" -eq "$expected" ]; then
    PASS=$((PASS + 1))
    printf 'PASS: %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s (expected %s, got %s)\n' "$label" "$expected" "$actual"
    cat "$TEST_ROOT/output"
  fi
}

assert_rc 'prepare a fresh offline fixture' 0 bash "$PREPARE" "$TEST_ROOT/fixture"
assert_rc 'fixture application tests pass' 0 python3 -m unittest discover -s "$TEST_ROOT/fixture" -v
assert_rc 'fixture includes isolated local distribution and source manifest' 0 python3 - "$TEST_ROOT/fixture" <<'PY'
import json
import os
import pathlib
import re
import sys
p = pathlib.Path(sys.argv[1])
assert not (p / '.git').exists(), 'fixture must not be a git repository'
assert (p / 'scripts/rite-dev').is_file(), 'launcher copy missing'
assert (p / 'plugins/rite/skills/open/SKILL.md').is_file(), 'plugin copy missing'
# Compare the link text itself: resolving only one side breaks when the temp
# directory is reached through a symlink (macOS /var -> /private/var).
assert os.readlink(p / '.grok/plugins/rite') == '../../plugins/rite', 'grok plugin link must be relative to fixture plugins/rite'
assert '[plugins]' in (p / '.grok/config.toml').read_text(), 'grok config missing [plugins]'
manifest = json.loads((p / '.runtime-e2e-source.json').read_text())
assert re.fullmatch('[0-9a-f]{40}', manifest['rite_commit'])
assert isinstance(manifest['dirty'], bool)
ignore = (p / '.gitignore').read_text().splitlines()
assert {'plugins/', 'scripts/', '.runtime-e2e-source.json', '.rite/'} <= set(ignore)
PY
printf 'keep\n' >"$TEST_ROOT/fixture/sentinel"
assert_rc 'existing destination is rejected' 1 bash "$PREPARE" "$TEST_ROOT/fixture"
assert_rc 'existing fixture remains intact' 0 test -s "$TEST_ROOT/fixture/sentinel"
ln -s "$TEST_ROOT/fixture" "$TEST_ROOT/link"
assert_rc 'symlink destination is rejected' 1 bash "$PREPARE" "$TEST_ROOT/link"
ln -s "$TEST_ROOT/nonexistent" "$TEST_ROOT/dangling"
assert_rc 'dangling symlink destination is rejected' 1 bash "$PREPARE" "$TEST_ROOT/dangling"
assert_rc 'relative destination is rejected' 1 bash "$PREPARE" relative-fixture

assert_rc 'initialize an unverified record' 0 python3 "$RESULTS" init claude "$TEST_ROOT/claude.json"
assert_rc 'initialized record is unverified' 2 python3 "$RESULTS" check "$TEST_ROOT/claude.json"
assert_rc 'init cannot overwrite an existing record' 1 python3 "$RESULTS" init codex "$TEST_ROOT/claude.json"
assert_rc 'init preserved original host' 0 python3 - "$TEST_ROOT/claude.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r['metadata']['host'] == 'claude'
assert all(s['status'] == 'unverified' and s['reason'] == 'not_run' for s in r['stages'].values())
PY
assert_rc 'init rejects unknown host' 2 python3 "$RESULTS" init unknown "$TEST_ROOT/unknown.json"

# Build explicitly synthetic successful records and a nonempty evidence stub.
python3 -B - "$RESULTS" "$TEST_ROOT" <<'PY'
import importlib.util, json, pathlib, sys
spec = importlib.util.spec_from_file_location('results', sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
root = pathlib.Path(sys.argv[2])
(root / 'synthetic.log').write_text('STUB: offline test data, never real host evidence\n')
for host in ('claude', 'codex', 'grok'):
    record = {
        'metadata': {'host': host, 'host_version': 'test-stub', 'rite_commit': 'a' * 40,
                     'surface': 'development', 'execution_mode': 'synthetic'},
        'stages': {s: {'status': 'pass', 'reason': 'synthetic contract fixture',
                       'evidence': ['synthetic.log']} for s in m.STAGES},
    }
    (root / f'{host}.json').write_text(json.dumps(record))
PY
RECORDS=("$TEST_ROOT/claude.json" "$TEST_ROOT/codex.json" "$TEST_ROOT/grok.json")
assert_rc 'all three complete synthetic records pass' 0 python3 "$RESULTS" check "${RECORDS[@]}"
assert_rc 'missing host is unverified' 2 python3 "$RESULTS" check "${RECORDS[@]:0:2}"
assert_rc 'duplicate host is invalid' 1 python3 "$RESULTS" check "${RECORDS[@]}" "$TEST_ROOT/claude.json"
assert_rc 'check leaves all records unchanged' 0 python3 - "$RESULTS" "${RECORDS[@]}" <<'PY'
from pathlib import Path
import subprocess, sys
paths = list(map(Path, sys.argv[2:]))
before = [p.read_bytes() for p in paths]
subprocess.run([sys.executable, sys.argv[1], 'check', *sys.argv[2:]], check=True)
assert before == [p.read_bytes() for p in paths]
PY

mutate() {
  python3 - "$TEST_ROOT/claude.json" "$TEST_ROOT/changed.json" "$1" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
exec(sys.argv[3], {'r': r})
with open(sys.argv[2], 'w') as f:
    json.dump(r, f)
PY
}
check_changed() {
  local label=$1 expected=$2
  assert_rc "$label" "$expected" python3 "$RESULTS" check "$TEST_ROOT/changed.json" "${RECORDS[@]:1}"
}
mutate "r['metadata']['host_version'] = ''"
check_changed 'pass requires complete metadata' 1
mutate "r['metadata']['rite_commit'] = 'invalid'"
check_changed 'invalid revision rejected' 1
mutate "r['metadata']['rite_commit'] = 'b' * 40"
check_changed 'mixed revision rejected' 1
mutate "r['metadata']['surface'] = 'distribution'"
check_changed 'mixed surface rejected' 1
mutate "r['metadata']['execution_mode'] = 'different'"
check_changed 'mixed execution mode rejected' 1
mutate "r['stages']['draft']['status'] = 'skipped'"
check_changed 'unknown stage status rejected' 1
mutate "del r['stages']['recover']"
check_changed 'missing stage rejected' 1
mutate "r['stages']['draft']['evidence'] = []"
check_changed 'pass requires evidence' 1
mutate "r['stages']['draft']['evidence'] = ['missing.log']"
check_changed 'missing evidence file rejected' 1
touch "$TEST_ROOT/empty.log"
mutate "r['stages']['draft']['evidence'] = ['empty.log']"
check_changed 'empty evidence rejected' 1
mutate "r['stages']['draft']['evidence'] = ['.']"
check_changed 'directory is not evidence' 1
mutate "r['stages']['draft']['evidence'] = ['$TEST_ROOT/synthetic.log']"
check_changed 'absolute evidence path accepted' 0
mutate "r['stages']['draft']['reason'] = ''"
check_changed 'pass needs explanation' 1
mutate "r['stages']['recover'] = {'status': 'unverified', 'reason': 'not_run', 'evidence': []}"
check_changed 'unverified does not count as pass' 2
mutate "r['stages']['recover'] = {'status': 'unverified', 'reason': '', 'evidence': []}"
check_changed 'unverified requires a reason' 1
mutate "r['stages']['recover'] = {'status': 'fail', 'reason': 'synthetic failure', 'evidence': []}"
check_changed 'failure returns one' 1
assert_rc 'failure takes precedence over missing host' 1 python3 "$RESULTS" check "$TEST_ROOT/changed.json"
mutate "r['stages']['recover'] = {'status': 'fail', 'reason': '', 'evidence': []}"
check_changed 'failure requires a reason' 1
printf '{invalid\n' >"$TEST_ROOT/invalid.json"
assert_rc 'malformed JSON rejected' 1 python3 "$RESULTS" check "$TEST_ROOT/invalid.json"
assert_rc 'missing record rejected' 1 python3 "$RESULTS" check "$TEST_ROOT/missing.json"

printf '\nResults: %s passed, %s failed (offline contracts only)\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
