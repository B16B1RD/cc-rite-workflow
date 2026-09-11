#!/usr/bin/env bash
# Execute the skill's queue operations: failure must preserve the resume point.
set -euo pipefail
cd "$(dirname "$0")/../../../.."
python3 - <<'PY'
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

skill = Path('plugins/rite/skills/batch-run/SKILL.md').read_text()
stop_section = skill.split('## ステップ 8:', 1)[1]
stop = re.search(r'```bash\n(.*?)\n```', stop_section, re.S).group(1)
advance_section = skill.split('cursor を進める（**両モード共有**', 1)[1]
advance = re.search(r'```bash\n(.*?)\n```', advance_section, re.S).group(1)
resume_section = skill.split('## ステップ 0:', 1)[1]
resume = re.search(r'```bash\n(.*?)\n```', resume_section, re.S).group(1)
route = next(line for line in skill.splitlines() if line.startswith('| `[iterate:max-cycles-reached]`'))
assert 'ステップ 8' in route and 'ステップ 6' not in route, route
assert '<!-- [run:stopped] -->' in stop_section
# Stub only path discovery and handoff consumption, not jq or queue mutations.
wrapper = '''bash() {
  case "$1" in
    /fixture/hooks/state-path-resolve.sh) printf '%s\\n' "$TEST_STATE_ROOT" ;;
    /fixture/hooks/flow-state.sh)
      case "$2" in
        path) printf '%s/session.flow-state\\n' "$TEST_STATE_ROOT" ;;
        consume-handoff) : ;;
        *) return 90 ;;
      esac ;;
    *) return 91 ;;
  esac
}
'''
with tempfile.TemporaryDirectory(prefix='rite-batch-stop-') as tmp:
    root = Path(tmp)
    (root / '.rite/state').mkdir(parents=True)
    queue = root / '.rite/state/run-queue-session.json'
    foreign = root / '.rite/state/run-queue-other.json'
    foreign.write_text('{"active":true}')
    env = dict(os.environ, TEST_STATE_ROOT=tmp)

    def run(code, breaker=True):
        code = code.replace('{plugin_root}', '/fixture').replace('{breaker_failed}', str(breaker).lower())
        code = code.replace('$ARGUMENTS', '')  # explicit no-argument batch restart
        result = subprocess.run(['bash', '-eu', '-c', wrapper + code], env=env, text=True, capture_output=True)
        assert result.returncode == 0, result.stderr
        assert foreign.read_text() == '{"active":true}'
        return result.stdout

    for mode in ('default', 'merge'):
        for cursor in (0, 1):  # first failure and last-Issue failure both stop
            initial = dict(issues=[101, 102], cursor=cursor, mode=mode, active=True, outstanding=[99], updated_at='old')
            queue.write_text(json.dumps(initial))  # legacy missing failed[] is accepted
            output = run(stop)
            state = json.loads(queue.read_text())
            assert state['cursor'] == cursor and state['active'] is False
            assert state['failed'] == [initial['issues'][cursor]]
            assert state['outstanding'] == [99] and state['mode'] == mode
            assert state['updated_at'] != 'old'
            assert 'RUN_STOP;' in output and 'RUN_ADVANCE' not in output and 'RUN_DONE' not in output
            run(stop)  # repeated stop is idempotent
            assert json.loads(queue.read_text())['failed'] == state['failed']
            run(resume)
            restarted = json.loads(queue.read_text())
            assert restarted['cursor'] == cursor and restarted['active'] is True
            assert restarted['mode'] == mode and restarted['failed'] == state['failed']
            run(advance)  # successful retry reaches normal cursor advance
            recovered = json.loads(queue.read_text())
            assert recovered['cursor'] == cursor + 1 and recovered['failed'] == []
            print(f'PASS: {mode}, cursor={cursor}: stop -> explicit resume -> successful advance')
        queue.write_text(json.dumps(dict(initial, failed=[99])))
        run(stop, breaker=False)
        state = json.loads(queue.read_text())
        assert state['failed'] == [99] and state['cursor'] == cursor and not state['active']
        print(f'PASS: {mode}: other failures stop without adding breaker failure')
PY
