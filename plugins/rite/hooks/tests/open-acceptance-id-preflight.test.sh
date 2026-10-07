#!/bin/bash
# Exercise the distributed open entry block with the real strict reader and
# safe body-update helper; only GitHub transport is replaced.
set -euo pipefail
root=$(cd "$(dirname "$0")/../../../.." && pwd)
python3 - "$root" <<'PY'
import json, os, shlex, shutil, subprocess, sys, tempfile
from pathlib import Path
root = Path(sys.argv[1])
reference = root / 'plugins/rite/skills/open/references/acceptance-id-preflight.md'
block = reference.read_text().split('```bash\n', 1)[1].split('\n```', 1)[0]
block = block.replace('{plugin_root}', str(root / 'plugins/rite')).replace('{issue_number}', '42').replace('{owner_repo}', 'o/r')
assert 'acceptance-id-preflight.md' in (root / 'plugins/rite/skills/open/SKILL.md').read_text()
with tempfile.TemporaryDirectory(prefix='rite-open-ac-test-') as temp:
    work = Path(temp)
    subprocess.run(['git', 'init', '-q', str(work)], check=True)
    subprocess.run(['git', '-C', str(work), 'remote', 'add', 'origin', 'git@github.com:o/r.git'], check=True)
    (work / 'bin').mkdir()
    wc = work / 'bin/wc'
    wc.write_text("#!/bin/bash\n" +
                  "count=$(" + shlex.quote(shutil.which('wc')) + " \"$@\") || exit $?\n" +
                  "case \"${BYTE_COUNT_STYLE:-plain}\" in\n" +
                  " padded) printf '      %s\\n' \"$count\" ;;\n" +
                  " invalid) printf 'x%s\\n' \"$count\" ;;\n" +
                  " internal) printf '1 %s\\n' \"$count\" ;;\n" +
                  " *) printf '%s\\n' \"$count\" ;;\nesac\n")
    wc.chmod(0o755)
    gh = work / 'bin/gh' 
    gh.write_text('''#!/usr/bin/env python3
import os, sys
from pathlib import Path
a=sys.argv[1:]; w=Path(os.environ['AC_TEST_DIR'])
with (w/'calls').open('a') as f: f.write(' '.join(a[:2])+'\\n')
if a[:2]==['issue','view']:
    sys.stdout.buffer.write((w/'body').read_bytes())
elif a[:2]==['issue','edit']:
    if os.environ.get('EDIT_FAIL')=='yes':
        print('transport-denied',file=sys.stderr);sys.exit(1)
    (w/'body').write_bytes(Path(a[a.index('--body-file')+1]).read_bytes())
elif a[:2]==['issue','comment']:
    (w/'comment').write_bytes(Path(a[a.index('--body-file')+1]).read_bytes())
else:
    print('unexpected gh call: '+repr(a),file=sys.stderr);sys.exit(2)
''')
    gh.chmod(0o755)
    script = work / 'preflight.sh'
    script.write_text(block.replace('{execution_cwd}', str(work)))
    env = dict(os.environ, PATH=str(work / 'bin') + os.pathsep + os.environ['PATH'], AC_TEST_DIR=str(work))
    def run(body, failure=False, byte_count_style="plain"):
        (work / 'body').write_bytes(body.encode())
        (work / 'calls').write_text('')
        (work / 'comment').unlink(missing_ok=True)
        actual_env = dict(env, EDIT_FAIL='yes' if failure else 'no', BYTE_COUNT_STYLE=byte_count_style)
        result = subprocess.run(['bash', str(script)], cwd=work, env=actual_env, text=True, capture_output=True)
        return result, (work / 'body').read_bytes().decode(), (work / 'calls').read_text().splitlines()
    def check(ok, message):
        assert ok, message
        print('PASS: '+message)
    (work / 'body').write_text('## 受入条件\n- [ ] AC-1: A\n')
    (work / 'calls').write_text('')
    mismatch = subprocess.run(['bash', str(root / 'plugins/rite/hooks/scripts/open-acceptance-id-preflight.sh'), '--issue', '42', '--repo', 'other/repo', '--cwd', str(work)], cwd=root, env=env, text=True, capture_output=True)
    check(mismatch.returncode != 0 and 'repository context mismatch' in mismatch.stderr and not (work / 'calls').read_text(), 'held outer repository identity is not replaced by cwd identity')
    original = '## 受入条件\n- [ ] A\n- [ ] B\n'
    result, body, calls = run(original)
    check(result.returncode == 0 and body == '## 受入条件\n- [ ] AC-1: A\n- [ ] AC-2: B\n', 'missing items become ordered explicit IDs')
    check(calls == ['issue view', 'issue edit', 'issue view', 'issue comment'], 'fresh verification follows apply before recording')
    # The returned body replaces the entry snapshot used by the downstream reader.
    returned = next(line.split('=', 1)[1] for line in result.stdout.splitlines() if line.startswith('OPEN_AC_ISSUE_JSON='))
    context = json.loads(returned)
    check(context == {'number': 42, 'body': body}, 'verified fresh body replaces the retained entry context')
    (work / 'retained').write_text(context['body'])
    downstream = subprocess.run(['bash', str(root / 'plugins/rite/scripts/acceptance-criteria-check.sh'), 'extract', '--body-file', str(work / 'retained')], text=True, capture_output=True)
    check(downstream.returncode == 0 and downstream.stdout.strip() == 'AC-1,AC-2', 'downstream strict reader accepts the refreshed retained body')
    check('OPEN_AC_ISSUE_JSON=' in reference.read_text() and 'ステップ 1.1 で保持した Issue 本文' in reference.read_text(), 'distributed reference requires replacing the retained Issue body')
    check('Issue #42 / 付与 ID: AC-1,AC-2' in (work / 'comment').read_text(), 'assignment has a persistent Issue/ID record')
    original = '前文\r\n## 5. Acceptance Criteria\r\n- [ ] AC-1: A\r\n- [ ] B\r\n### AC-3: C\r\n- [ ] D\r\n```\r\n- [ ] 例\r\n```\r\n## Other\r\n- [ ] untouched\r\n'
    result, body, calls = run(original)
    check(result.returncode == 0 and body == original.replace('- [ ] B', '- [ ] AC-2: B').replace('- [ ] D', '- [ ] AC-4: D'), 'existing IDs, holes, CRLF, fence, headings and outside text are preserved')
    original = '前文\r\n## 受入条件\r\n- [ ] A\r\n- [x] AC-1：既存\r\n### AC-3： 見出し\r\n- [ ] B\r\n+ [X] AC-2：完了\r\n'
    result, body, calls = run(original)
    expected = original.replace('- [ ] A', '- [ ] AC-4: A').replace('- [ ] B', '- [ ] AC-5: B')
    check(result.returncode == 0 and body == expected and calls == ['issue view', 'issue edit', 'issue view', 'issue comment'], 'fullwidth IDs are reserved before missing IDs, retaining original glyphs and CRLF')
    check('付与 ID: AC-4,AC-5' in (work / 'comment').read_text(), 'assignment record contains only newly assigned IDs')
    original = '## 受入条件\n### AC-1：見出し\n* [ ] AC-2： 未確認\n- [x] AC-3：完了\n+ [X] AC-4：完了\n'
    result, body, calls = run(original)
    check(result.returncode == 0 and body == original and calls == ['issue view'] and not (work / 'comment').exists(), 'complete fullwidth IDs preserve body glyphs without assignment or writes')
    for original, expected in [('## 受入条件\n- [ ] A\n- [ ] B\n', '## 受入条件\n- [ ] AC-1: A\n- [ ] AC-2: B\n'), ('## 受入条件\n- [ ] AC-1: A\n- [ ] B\n', '## 受入条件\n- [ ] AC-1: A\n- [ ] AC-2: B\n')]:
        result, body, calls = run(original, byte_count_style='padded')
        check(result.returncode == 0 and body == expected and calls == ['issue view', 'issue edit', 'issue view', 'issue comment'], 'BSD padded byte count preserves ID assignment and existing IDs')
    for style in ['invalid', 'internal']:
        original = '## 受入条件\n- [ ] A\n'
        result, body, calls = run(original, byte_count_style=style)
        check(result.returncode != 0 and body == original and 'issue edit' not in calls, 'non-numeric byte count remains rejected: '+style)
    original = '## 受入条件\n- [ ] AC-2: A\n## 受入基準\n- [ ] B\n- [ ] AC-1: C\n'
    result, body, calls = run(original)
    check(result.returncode == 0 and '- [ ] AC-3: B' in body, 'all existing section IDs are reserved before assigning')
    original = '## 受入条件\n- [ ] AC-1: A\n- [ ] AC-2: B\n'
    result, body, calls = run(original)
    check(result.returncode == 0 and body == original and calls == ['issue view'] and not (work / 'comment').exists() and 'OPEN_AC_IDS_ASSIGNED' not in result.stdout, 'complete IDs cause no edit or assignment record')
    result, body, calls = run('## 受入条件\n- [ ] A\n', failure=True)
    check(result.returncode != 0 and body == '## 受入条件\n- [ ] A\n' and calls == ['issue view','issue edit','issue view'] and 'apply_failure_reason=' in result.stdout and 'refreshed_body_invalid' in result.stderr, 'rc-zero safe apply failure stops on the freshly fetched body with cause')
    original = '## 完了条件\n- [ ] 内容\n'
    result, body, calls = run(original)
    check(result.returncode == 0 and body == original and calls == ['issue view'], 'unrecognized unrelated heading remains untouched and skipped')
    for original, reason in [('## Acceptance Criteria (extra)\n- [ ] 内容\n','unsupported_ac_section'), ('## 受入条件\n- [ ] AC-bad: A\n','malformed_ac_item'), ('## 受入条件\n- [ ] AC-1: A\n- [ ] AC-1: B\n','duplicate_ac_id')]:
        result, body, calls = run(original)
        check(result.returncode != 0 and body == original and calls == ['issue view'] and reason in result.stderr, 'strict reader rejects '+reason+' without writing')
PY
