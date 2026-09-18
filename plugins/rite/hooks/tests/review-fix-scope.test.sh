#!/usr/bin/env bash
# Exercise scope planning and validation through real persisted review receipts.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 - "$SCRIPT_DIR/../.." <<'PYTEST'
import copy
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile

plugin = Path(sys.argv[1]).resolve()
helper = plugin / 'hooks/scripts/review-fix-scope-check.sh'
checks = 0


def check(value, label):
    global checks
    assert value, label
    checks += 1


def dump(path, value):
    path.write_text(json.dumps(value), encoding='utf-8')


def caller_block(text, marker):
    check(text.count(marker) == 1, 'unique caller marker: ' + marker)
    at = text.index(marker)
    start = text.rfind('```bash\n', 0, at)
    end = text.index('\n```', at)
    check(start >= 0, 'caller is an executable bash block')
    return text[start + len('```bash\n'):end]


with tempfile.TemporaryDirectory(prefix='rite-fix-scope-') as tmp:
    root = Path(tmp)
    private = root / '.rite'
    private.mkdir()
    env = dict(os.environ)
    for key in ('CODEX_THREAD_ID', 'GROK_SESSION_ID', 'CLAUDE_SESSION_ID',
                'CLAUDE_CODE_SESSION_ID', 'RITE_SESSION_ID', 'RITE_HOST', 'RITE_STATE_ROOT',
                'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE'):
        env.pop(key, None)
    session = 'fix-scope-test'
    env.update(RITE_HOST='claude', CLAUDE_CODE_SESSION_ID=session, RITE_STATE_ROOT=tmp,
               TMPDIR=tmp, SCOPE_TEST_ENV='initial')

    def run(args, ok=True):
        result = subprocess.run(args, cwd=root, env=env, text=True, capture_output=True)
        if ok:
            check(result.returncode == 0, repr(args) + '\n' + result.stdout + result.stderr)
        return result

    def flow(*args):
        return run(['bash', str(plugin / 'hooks/flow-state.sh'), *map(str, args)])

    run(['git', 'init', '-q'])
    (root / '.git/info/exclude').write_text('.rite/\n')
    (root / 'src').mkdir()
    source = root / 'src/a.py'
    source.write_text('original\n')
    (root / 'protected').mkdir()
    (root / 'protected/secret.py').write_text('protected\n')
    run(['git', 'add', 'src', 'protected'])
    run(['git', '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
         'commit', '-q', '-m', 'fixture'])
    flow('set', '--phase', 'pr', '--next', 'review', '--pr', 71, '--issue', 42)
    selection = private / 'selection.json'
    selected = ['code-quality-reviewer', 'acceptance-reviewer']
    dump(selection, selected)
    flow('review-start', '--selection', selection)
    state_path = Path(flow('path').stdout.strip())
    state = json.loads(state_path.read_text())
    context = state['review_cycle']['review_context']
    records = []
    for index, reviewer in enumerate(selected):
        raw = private / (reviewer + '.md')
        raw.write_text('### 評価: 要修正\n### 所見\n確認済み\n### 指摘事項\n再現済み\n### 監査ログ\nなし\n')
        records.append(dict(reviewer=reviewer, review_context=context, agent_id='child-' + str(index),
                            status='completed', started_at='2026-01-01T00:00:00Z',
                            ended_at='2026-01-01T00:01:00Z', output_file=str(raw)))
    manifest = private / 'manifest.json'
    dump(manifest, dict(schema_version=1, parent_agent_id=session, review_context=context,
                        selected_reviewers=selected, reviewers=records))
    content = private / 'review.json'
    findings = [dict(id='F-0' + str(index + 1), reviewer=selected[index], severity='HIGH',
                     file='src/a.py', line=1, description='Verification: repro sample => failed',
                     suggestion='fix', status='open', scope='current-pr') for index in range(2)]
    dump(content, dict(schema_version='1.1.0', pr_number=71, review_context=context,
                       timestamp='__RITE_TS_PLACEHOLDER_7f3a9b2c__', commit_sha=context['commit_sha'],
                       reviewers=selected, findings=findings, non_blocking_findings=[], guardrail_audit_log=[]))
    run(['bash', str(plugin / 'scripts/review-measured-gate.sh'), '--input', str(content),
         '--reject-preset-verification'])
    flow('review-finish', '--manifest', manifest, '--content-file', content)
    cycle = json.loads(state_path.read_text())['review_cycle']
    check(cycle['status'] == 'completed' and cycle['verdict'] == 'fix-needed', 'real blocking receipt')
    review_path = Path(cycle['result_path'])
    issue_file, plan_file = private / 'issue.json', private / 'plan.json'
    issue = {'number': 42, 'body': '## 4. 対象範囲\n### 4.1 対象\n- `src/a.py`\n'
             '### 4.2 対象外\n- `protected`\n## 5. 受入条件\n- 全指摘を一括修正する\n'}
    dump(issue_file, issue)
    related_command = "printf 'related\\n' >> .rite/related.log; if test -f .rite/fail; then exit 7; fi"
    plan = dict(review_context=context, issue_number=42, issue_body=issue['body'],
                constraints=dict(targets=['src/a.py'], non_targets=['protected'], closed_targets=False,
                                 rationale='Issue target候補なので開集合'),
                groups=[dict(root_cause='共有する入力判定の欠落', finding_ids=['F-01', 'F-02'], action='fix',
                             paths=['src/a.py'], rationale='入力判定の修正で両指摘を解消する',
                             semantic=dict(approved=True, acceptance_criteria='全指摘を一括修正するACに適合',
                                           out_of_scope='protectedは変更しない'), verification_ids=['related'])],
                verifications=[dict(id='related', kind='related', command=related_command,
                                    inputs=['src/a.py'], environment=['SCOPE_TEST_ENV']),
                               dict(id='full', kind='full', command="printf 'full\\n' >> .rite/full.log; test ! -f .rite/full-fail",
                                    inputs=['src'], environment=[])])
    canonical = private / ('state/fix-plan-' + session + '.json')
    verification_file = private / ('state/fix-verification-' + session + '.json')

    def invoke(mode='check', kind=None, ok=True):
        args = ['bash', str(helper), mode, '--plan', str(plan_file), '--issue', str(issue_file)]
        if kind:
            args += ['--kind', kind]
        return run(args, ok)

    def save_plan(value=plan):
        dump(plan_file, value)

    def reject_plan(value, label):
        before = canonical.read_bytes() if canonical.exists() else None
        save_plan(value)
        result = invoke(ok=False)
        check(result.returncode != 0 and '[fix:error]' in result.stdout + result.stderr, label)
        if before is not None:
            check(canonical.read_bytes() == before, label + ': old record retained')
        save_plan()

    def lines(name):
        path = private / name
        return len(path.read_text().splitlines()) if path.exists() else 0

    save_plan()
    invoke()
    saved = json.loads(canonical.read_text())
    check(saved['plan'] == plan and saved['plan_hash'] and saved['review_hash'] and
          saved['mechanical'] and saved['checked_at'], 'canonical scope receipt separates semantic and mechanical evidence')
    invoke()  # Interrupted callers may repeat the check without starting another review.
    check(json.loads(state_path.read_text())['cycle_count'] == 1, 'idempotent check preserves cycle')
    for mutation, label in (
            (lambda p: p['groups'][0].update(finding_ids=['F-01']), 'missing blocking disposition'),
            (lambda p: p['groups'][0].update(finding_ids=['F-01', 'F-02', 'invented']), 'unknown finding'),
            (lambda p: p['groups'][0]['semantic'].update(approved=False), 'unresolved semantic decision'),
            (lambda p: p['groups'][0].update(verification_ids=[]), 'fix without verification'),
            (lambda p: p['review_context'].update(session_id='foreign'), 'foreign session'),
            (lambda p: p['review_context'].update(run_id='foreign'), 'foreign run'),
            (lambda p: p.update(issue_number=43), 'foreign issue'),
            (lambda p: p['constraints'].update(non_targets=[]), 'omitted explicit non-target'),
            (lambda p: p['groups'][0].update(paths=['protected/secret.py']), 'explicit non-target'),
            (lambda p: p['groups'][0].update(paths=['src/../protected/secret.py']), 'parent traversal'),
            (lambda p: p['groups'][0].update(paths=[str(source)]), 'absolute path')):
        candidate = copy.deepcopy(plan)
        mutation(candidate)
        reject_plan(candidate, label)
    with tempfile.TemporaryDirectory(prefix='rite-fix-outside-') as outside:
        (root / 'src/escape').symlink_to(outside, target_is_directory=True)
        candidate = copy.deepcopy(plan)
        candidate['groups'][0]['paths'] = ['src/escape/new.py']
        reject_plan(candidate, 'symlink escape')
        (root / 'src/escape').unlink()

    previous = canonical.read_bytes()
    plan_file.write_text('{broken')
    check(invoke(ok=False).returncode != 0 and canonical.read_bytes() == previous, 'malformed plan preserves saved record')
    save_plan()
    original_review = review_path.read_bytes()
    review_path.write_text('{broken')
    check(invoke(ok=False).returncode != 0 and canonical.read_bytes() == previous, 'damaged review receipt rejected')
    review_path.write_bytes(original_review)
    changed_issue = dict(issue, body=issue['body'] + '\n追加AC\n')
    dump(issue_file, changed_issue)
    check(invoke(ok=False).returncode != 0 and canonical.read_bytes() == previous, 'changed issue requires replanning')
    dump(issue_file, issue)

    # Rows rite itself appends to the Issue (triage Decision Log entries, the non-blocking
    # record marker) are not specification changes; anything else in the body still is.
    row = '- 2026-01-02 D-01: defer the boundary / Reason: out of scope / Impact: none'
    marker = '<!-- rite:nbr:comment-id:101 -->'
    triaged = issue['body'] + '\n## 9. Decision Log\n\n' + row + '\n\n' + marker + '\n'
    for body, label in ((issue['body'] + row + '\n', 'triage-format row outside the Decision Log'),
                        (issue['body'] + '\n## 9. Decision Log\n\n- note: manual decision\n', 'free-form Decision Log row'),
                        (issue['body'] + '\n<!-- note -->\n', 'HTML comment that is not the record marker'),
                        (issue['body'] + '\n' + marker + ' trailing\n', 'record marker with trailing text'),
                        (triaged + '\n## 9. Decision Log\n\n' + row + '\n', 'duplicated Decision Log heading')):
        dump(issue_file, dict(issue, body=body))
        result = invoke(ok=False)
        check(result.returncode != 0 and canonical.read_bytes() == previous, label + ' requires replanning')
    check('boundary undecidable' in result.stderr, 'duplicated heading is reported as an undecidable boundary')
    dump(issue_file, dict(issue, body=triaged))
    check(invoke().returncode == 0,
          'created Decision Log row and record marker pass the specification check')
    crlf = issue['body'].replace('\n', '\r\n') + '\r\n' + marker + '\r\n'
    dump(issue_file, dict(issue, body=crlf))
    check(invoke(ok=False).returncode != 0, 'CRLF rewrite of the specification text is still a change')
    dump(plan_file, dict(plan, issue_body=issue['body'].replace('\n', '\r\n')))
    check(invoke().returncode == 0, 'record marker on a CRLF body passes the specification check')
    save_plan()
    mutant = private / 'mutant-hooks'
    shutil.copytree(plugin / 'hooks', mutant)
    lib = mutant / 'scripts/lib/review-cycle.py'
    lib.write_text(lib.read_text().replace('def normalize_issue_body(body):\n', 'def normalize_issue_body(body):\n    return body\n', 1))
    mutation = run(['bash', str(mutant / 'scripts/review-fix-scope-check.sh'), 'check', '--plan', str(plan_file), '--issue', str(issue_file)], ok=False)
    check(mutation.returncode != 0 and 'specification' in mutation.stderr, 'identity normalization mutation rejects the triaged Issue')
    dump(issue_file, issue)
    invoke()
    previous = canonical.read_bytes()

    # Inject a physical replace failure after serialization, retaining the old canonical file.
    fault_dir = private / 'fault'
    fault_dir.mkdir()
    (fault_dir / 'sitecustomize.py').write_text(
        "import os\noriginal = os.replace\n"
        "def fail_plan_replace(src, dst, *a, **kw):\n"
        "    if str(dst).endswith('fix-plan-fix-scope-test.json'):\n"
        "        raise OSError('fixture replace failure')\n"
        "    return original(src, dst, *a, **kw)\n"
        "os.replace = fail_plan_replace\n")
    old_pythonpath = env.get('PYTHONPATH')
    env['PYTHONPATH'] = str(fault_dir)
    result = invoke(ok=False)
    check(result.returncode != 0 and canonical.read_bytes() == previous, 'atomic save failure retains old plan')
    if old_pythonpath is None:
        env.pop('PYTHONPATH')
    else:
        env['PYTHONPATH'] = old_pythonpath

    source.write_text('fixed\n')
    invoke('verify', 'related')
    invoke('verify', 'related')
    check(lines('related.log') == 1 and lines('full.log') == 0, 'unchanged related result reused; full waits')
    source.write_text('fixed again\n')
    invoke('verify', 'related')
    check(lines('related.log') == 2, 'dependency content invalidates related cache')
    env['SCOPE_TEST_ENV'] = 'changed'
    invoke('verify', 'related')
    check(lines('related.log') == 3, 'environment value invalidates related cache')
    candidate = copy.deepcopy(plan)
    candidate['verifications'][0]['command'] += '; : changed-command'
    save_plan(candidate)
    check(invoke('verify', 'related', ok=False).returncode != 0, 'changed plan requires check before execution')
    invoke()
    invoke('verify', 'related')
    check(lines('related.log') == 4, 'changed command executes again')
    save_plan()
    invoke()
    invoke('verify', 'all')
    invoke('verify', 'all')
    check(lines('full.log') == 2, 'full suite always executes at each completion checkpoint')
    record = json.loads(verification_file.read_text())
    check(record['review_context'] == context and record['results']['related']['exit_code'] == 0 and
          record['results']['related']['key'], 'verification receipt has identity, input key and exit')
    count = lines('related.log')
    source.unlink()
    invoke('verify', 'related')
    check(lines('related.log') == count + 1, 'missing dependency invalidates cached success')
    source.write_text('restored dependency\n')
    invoke('verify', 'related')
    check(lines('related.log') == count + 2, 'restored dependency invalidates missing-input cache')
    original_verification = verification_file.read_bytes()
    record = json.loads(original_verification)
    record['review_context']['session_id'] = 'foreign-session'
    dump(verification_file, record)
    check(invoke('verify', 'related', ok=False).returncode != 0, 'foreign verification receipt rejected')
    verification_file.write_text('{broken')
    check(invoke('verify', 'related', ok=False).returncode != 0, 'corrupt verification receipt rejected')
    verification_file.write_bytes(original_verification)

    source.write_text('another revision\n')
    (private / 'fail').touch()
    check(invoke('verify', 'related', ok=False).returncode != 0, 'failed related command stops verification')
    count = lines('related.log')
    check(invoke('verify', 'related', ok=False).returncode != 0 and lines('related.log') == count + 1,
          'failed verification never reuses an old successful receipt')
    check(json.loads(verification_file.read_text())['results']['related']['exit_code'] == 7,
          'failed command exit is persisted')
    (private / 'fail').unlink()
    invoke('verify', 'related')
    extra = root / 'src/unplanned.py'
    extra.write_text('new unplanned change\n')
    check(invoke('verify', 'all', ok=False).returncode != 0, 'unplanned untracked changes rejected')
    extra.unlink()

    # Sandbox write-block masks: a character device (simulated by a symlink to
    # /dev/null, which stat follows) and a leftover 0-byte no-write stub are not
    # untracked changes; every other untracked shape still is.
    def fixture(name, mode, content=''):
        target = root / name
        target.write_text(content)
        target.chmod(mode)
        info = os.lstat(target)
        if not (stat.S_ISREG(info.st_mode) and info.st_size == len(content) and stat.S_IMODE(info.st_mode) == mode):
            raise SystemExit('ERROR: fixture ' + name + ' did not keep mode/size (filesystem does not keep modes?)')
        return target

    def stub_warnings(result):
        return [line for line in result.stderr.splitlines() if 'sandbox stub file(s)' in line]

    def filtered_untracked():
        # The helper's own mktemp files must not land in the tree it inspects.
        result = subprocess.run(['bash', str(plugin / 'hooks/scripts/lib/git-status-filtered.sh')], cwd=root,
                                env=dict(env, TMPDIR=str(private)), text=True, capture_output=True)
        check(result.returncode == 0, 'git-status-filtered.sh succeeds: ' + result.stderr)
        return {line[3:] for line in result.stdout.splitlines() if line.startswith('?? ')}

    ghost = root / 'ghost_devnull'
    ghost.symlink_to('/dev/null')
    check(stat.S_ISLNK(os.lstat(ghost).st_mode) and stat.S_ISCHR(os.stat(ghost).st_mode), 'device fixture is a symlink to a character device')
    result = invoke('verify', 'all')
    check(stub_warnings(result) == [], 'character device mask excluded silently')
    check(filtered_untracked() == set(), 'git-status-filtered.sh also drops the device mask')
    ghost.unlink()
    mask = fixture('.bashrc', 0o444)
    result = invoke('verify', 'all')
    warnings = stub_warnings(result)
    check(len(warnings) == 1 and ' 1 sandbox stub file(s)' in warnings[0] and '".bashrc"' in warnings[0],
          'stub mask excluded with a single warning naming it')
    check(filtered_untracked() == set(), 'git-status-filtered.sh also drops the stub')
    link = root / 'stub_link'
    link.symlink_to(mask.name)
    check(stat.S_ISLNK(os.lstat(link).st_mode) and os.stat(link).st_size == 0, 'stub link fixture points at the stub')
    result = invoke('verify', 'all', ok=False)
    warnings = stub_warnings(result)
    check(result.returncode != 0 and len(warnings) == 1 and ' 1 sandbox stub file(s)' in warnings[0]
          and '"stub_link"' not in warnings[0] and 'unplanned changed path' in result.stderr,
          'symlink to a stub stays an untracked change while the stub itself is still excluded')
    check(filtered_untracked() == {link.name}, 'git-status-filtered.sh keeps the same symlink')
    link.unlink()
    mask.unlink()
    # An untracked entry whose stat fails is not excluded. The shell helper keeps the
    # same link only because find -type f does not match it, not through its own
    # unreadable-entry path, so this pins the Python stat-failure branch.
    dangling = root / 'dangling_link'
    dangling.symlink_to('missing-target')
    check(stat.S_ISLNK(os.lstat(dangling).st_mode) and not os.path.exists(dangling), 'dangling link fixture makes stat fail')
    result = invoke('verify', 'all', ok=False)
    check(result.returncode != 0 and 'unplanned changed path' in result.stderr and stub_warnings(result) == [],
          'untracked entry whose stat fails stays a change')
    check(filtered_untracked() == {dangling.name}, 'git-status-filtered.sh keeps the same dangling link')
    dangling.unlink()
    first, second = fixture('.bashrc', 0o444), fixture('.gitconfig', 0o444)
    result = invoke('verify', 'all')
    warnings = stub_warnings(result)
    check(result.returncode == 0 and len(warnings) == 1 and ' 2 sandbox stub file(s)' in warnings[0]
          and warnings[0].count('".bashrc"') == 1 and warnings[0].count('".gitconfig"') == 1
          and warnings[0].endswith('".bashrc" ".gitconfig"'),
          'several stubs share one warning line that names each once')
    check(filtered_untracked() == set(), 'git-status-filtered.sh also drops both stubs')
    first.unlink()
    second.unlink()
    check(filtered_untracked() == set(), 'stub fixtures leave no untracked entries behind')
    for name, mode, content, label in (('.bashrc', 0o644, '', 'writable empty file'),
                                       ('.bashrc', 0o444, 'alias ls=ls\n', 'read-only file with content'),
                                       ('.gitconfig', 0o464, '', 'empty file with a group write bit')):
        real = fixture(name, mode, content)
        result = invoke('verify', 'all', ok=False)
        check(result.returncode != 0 and stub_warnings(result) == [], label + ' rejected as untracked change')
        check(filtered_untracked() == {name}, label + ' kept by git-status-filtered.sh too')
        real.unlink()
    tracked_stub = fixture('protected/secret.py', 0o444)
    result = invoke('verify', 'all', ok=False)
    check(result.returncode != 0 and stub_warnings(result) == [], 'tracked file emptied into stub shape is a change, not a mask')
    tracked_stub.chmod(0o644)
    tracked_stub.write_text('protected\n')
    protected = root / 'protected/secret.py'
    protected.write_text('forbidden change\n')
    check(invoke('verify', 'all', ok=False).returncode != 0, 'actual tracked non-target changes rejected')
    protected.write_text('protected\n')

    candidate = copy.deepcopy(plan)
    candidate['groups'][0]['paths'] = ['src']
    save_plan(candidate)
    invoke()
    run(['git', 'mv', 'protected/secret.py', 'src/moved.py'])
    result = invoke('verify', 'all', ok=False)
    check(result.returncode != 0 and 'unplanned changed path' in result.stderr,
          'staged rename cannot hide a non-target source deletion')
    run(['git', 'mv', 'src/moved.py', 'protected/secret.py'])

    dependency = private / 'dependency'
    dependency.mkdir()
    (dependency / 'flag').write_text('good\n')
    linked = root / 'src/link'
    linked.symlink_to('../.rite/dependency', target_is_directory=True)
    candidate['groups'][0]['paths'].append('src/link')
    candidate['verifications'][0].update(
        inputs=['src'], command="echo run >> .rite/symlink.log; test \"$(cat src/link/flag)\" = good")
    save_plan(candidate)
    invoke()
    invoke('verify', 'related')
    invoke('verify', 'related')
    check(lines('symlink.log') == 1, 'unchanged nested directory symlink result is reused')
    (dependency / 'flag').write_text('broken\n')
    result = invoke('verify', 'related', ok=False)
    check(result.returncode != 0 and lines('symlink.log') == 2,
          'nested directory symlink content change reruns and propagates failure')
    check(json.loads(verification_file.read_text())['results']['related']['exit_code'] == 1,
          'symlink dependency failure is recorded')
    (dependency / 'flag').write_text('good\n')
    invoke('verify', 'related')
    loop = dependency / 'loop'
    loop.symlink_to('.', target_is_directory=True)
    result = invoke('verify', 'related', ok=False)
    check(result.returncode != 0 and 'cyclic verification input' in result.stderr,
          'cyclic directory input cannot reuse cached success')
    loop.unlink()
    linked.unlink()
    save_plan()
    invoke()

    docs = (plugin / 'skills/fix/SKILL.md').read_text()
    before_edit = caller_block(docs, '# fix-scope-before-edit')
    final_verify = caller_block(docs, '# fix-scope-final-verification')

    def execute(body):
        for key, value in {'plugin_root': str(plugin), 'fix_plan_file': str(plan_file),
                           'fix_issue_file': str(issue_file)}.items():
            body = body.replace('{' + key + '}', value)
        return run(['bash', '-c', body + '\nprintf "REACHED_LATER_ACTION\\n"'], ok=False)

    save_plan()
    result = execute(before_edit)
    check(result.returncode == 0 and 'REACHED_LATER_ACTION' in result.stdout, 'real pre-edit caller permits checked plan')
    candidate = copy.deepcopy(plan)
    candidate['groups'][0]['semantic']['approved'] = False
    save_plan(candidate)
    result = execute(before_edit)
    check(result.returncode != 0 and 'REACHED_LATER_ACTION' not in result.stdout and
          '[fix:error]' in result.stdout + result.stderr, 'pre-edit caller fails before later edit')
    save_plan()
    invoke()
    (private / 'fail').touch()
    source.write_text('force failed completion\n')
    result = execute(final_verify)
    check(result.returncode != 0 and 'REACHED_LATER_ACTION' not in result.stdout and
          '[fix:error]' in result.stdout + result.stderr, 'final caller fails before commit/push/review')
    (private / 'fail').unlink()
    result = execute(final_verify)
    check(result.returncode == 0 and 'REACHED_LATER_ACTION' in result.stdout, 'final caller permits verified completion')
    (private / 'full-fail').touch()
    result = execute(final_verify)
    check(result.returncode != 0 and 'REACHED_LATER_ACTION' not in result.stdout and
          '[fix:error]' in result.stdout + result.stderr, 'full-suite failure stops final caller after related success')
    (private / 'full-fail').unlink()

    # A plan stored under the check record's own name must be refused before the record replaces it.
    plan_bytes = json.dumps(plan).encode()
    guard = 'plan input must not be the check record'

    def check_record_guard(plan_arg, label, stored=plan_bytes):
        canonical.write_bytes(stored)
        for mode, kind in (('check', None), ('verify', 'related')):
            args = ['bash', str(helper), mode, '--plan', plan_arg, '--issue', str(issue_file)]
            if kind:
                args += ['--kind', kind]
            result = run(args, ok=False)
            check(result.returncode != 0 and guard in result.stderr and
                  '[fix:error]' in result.stdout + result.stderr, label + ': ' + mode + ' refused by guard')
            check(canonical.read_bytes() == stored, label + ': ' + mode + ' leaves input intact')

    check_record_guard(str(canonical), 'absolute record path')
    check_record_guard('.rite/state/fix-plan-' + session + '.json', 'relative record path')
    alias = private / 'alias-plan.json'
    alias.symlink_to('state/fix-plan-' + session + '.json')
    check_record_guard(str(alias), 'file symlink to record')
    alias.unlink()
    statelink = private / 'statelink'
    statelink.symlink_to('state', target_is_directory=True)
    check_record_guard(str(statelink / ('fix-plan-' + session + '.json')), 'directory symlink to record')
    statelink.unlink()
    overwritten = json.dumps(dict(plan=plan, plan_hash='x', review_hash='x', mechanical={}, checked_at='x')).encode()
    check_record_guard(str(canonical), 'record already holding a check result', stored=overwritten)

    input_file = private / ('state/fix-plan-input-' + session + '.json')
    input_file.write_bytes(plan_bytes)
    run(['bash', str(helper), 'check', '--plan', '.rite/state/fix-plan-input-' + session + '.json',
         '--issue', str(issue_file)])
    check(input_file.read_bytes() == plan_bytes and input_file.resolve() != canonical.resolve() and
          json.loads(canonical.read_text())['plan'] == plan, 'documented input name keeps the plan and records separately')
    result = run(['bash', str(helper), 'verify', '--plan', str(input_file), '--issue', str(issue_file), '--kind', 'all'])
    check('FIX_VERIFICATION=pass' in result.stdout and input_file.read_bytes() == plan_bytes,
          'documented input name verifies without touching the plan')
    input_file.unlink()
    guide = (plugin / 'skills/fix/references/fix-plan.md').read_text()
    defined = [line for line in guide.splitlines() if '`{fix_plan_file}` は' in line]
    check(len(defined) == 1 and 'fix-plan-input-{session}.json' in defined[0] and
          '`.rite/state/fix-plan-{session}.json`' not in defined[0] and
          '検査記録は `.rite/state/fix-plan-{session}.json`' in guide, 'guide names input and check record separately')
    # Execute the documented assertion bodies through the real verify helper.
    script_a, script_b = private / 'a.sh', private / 'b.sh'
    script_a.write_text('printf "target out\\n"; printf "target err\\n" >&2; exit 2\n')
    script_b.write_text('exit 2\n')
    for marker, cases in (
        ('# assert-expected-exit-single', ((2, 2, True), (1, 2, False))),
        ('# assert-expected-exit-multiple', ((2, 2, True), (2, 1, False), (1, 2, False))),
    ):
        body = caller_block(guide, marker).replace('scripts/a.sh', '.rite/a.sh').replace('scripts/b.sh', '.rite/b.sh')
        candidate = copy.deepcopy(plan)
        candidate['verifications'][0].update(command=body, inputs=['.rite/a.sh', '.rite/b.sh'])
        save_plan(candidate)
        invoke()
        for rc_a, rc_b, success in cases:
            script_a.write_text('printf "target out\\n"; printf "target err\\n" >&2; exit ' + str(rc_a) + '\n')
            script_b.write_text('exit ' + str(rc_b) + '\n')
            result = invoke('verify', 'all', ok=False)
            check((result.returncode == 0) == success, marker + ': individually assert rc ' + str((rc_a, rc_b)))
            saved = json.loads(verification_file.read_text())['results']['related']
            check(saved['exit_code'] == (0 if success else 1), 'wrapper receipt retains measured assertion exit')
            check('target out' in saved['stdout'] and 'target err' in saved['stderr'], 'wrapper output evidence retained')
    body_and = caller_block(guide, '# assert-expected-exit-multiple').replace(
        'scripts/a.sh', '.rite/a.sh').replace('scripts/b.sh', '.rite/b.sh')
    body_semi = body_and.replace('&&', ';')
    check('&&' in body_and and body_and != body_semi, 'documented multiple example joins with &&')
    script_a.write_text('printf "target out\\n"; printf "target err\\n" >&2; exit 1\n')
    script_b.write_text('exit 2\n')
    candidate = copy.deepcopy(plan)
    candidate['verifications'][0].update(command=body_and, inputs=['.rite/a.sh', '.rite/b.sh'])
    save_plan(candidate)
    invoke()
    check(invoke('verify', 'all', ok=False).returncode != 0,
          '&& does not conceal first-wrong/second-right')
    candidate['verifications'][0]['command'] = body_semi
    save_plan(candidate)
    invoke()
    check(invoke('verify', 'all', ok=False).returncode == 0,
          '; conceals first-wrong/second-right')
    candidate['verifications'][0]['command'] = 'bash .rite/a.sh'
    script_a.write_text('printf "raw out\\n"; printf "raw err\\n" >&2; exit 2\n')
    save_plan(candidate)
    invoke()
    result = invoke('verify', 'all', ok=False)
    check(result.returncode != 0 and 'actual_rc=2' in result.stderr and 'expected_rc=0' in result.stderr
          and str(verification_file) in result.stderr and 'wrapper that exits 0' in result.stderr,
          'raw nonzero failure gives actual exit, evidence path and assertion guidance')
    saved = json.loads(verification_file.read_text())['results']['related']
    check(saved['exit_code'] == 2 and 'raw out' in saved['stdout'] and 'raw err' in saved['stderr'],
          'raw nonzero exit and output evidence are preserved')
    script_a.unlink()
    script_b.unlink()
    save_plan()
    invoke()
    run(['git', '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
         'commit', '-q', '--allow-empty', '-m', 'changed HEAD'])
    check(invoke(ok=False).returncode != 0, 'changed HEAD rejects stale review and plan')
    print('PASS: review fix scope: ' + str(checks) + ' assertions; real receipts, cache, failures and documented callers')
PYTEST
