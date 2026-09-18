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


# The third case scopes the plan to a directory so that a rename with both
# endpoints inside the plan is expressible. The commit preflight lists changed
# paths with --no-renames, exactly as verify() does, so a rename must not read as
# an unplanned change when it stays in scope, and must still be refused when
# either endpoint leaves it.
# Its verification inputs stay file-scoped there so that a rename is observed by
# the path check alone; a directory input would fingerprint the whole tree and
# report a stale verification before the path check is reached.
for use_run, plan_paths, full_inputs, rename_boundary in ((False, ['src/a.py'], ['src'], False),
                                                          (True, ['src/a.py'], ['src'], False),
                                                          (False, ['src'], ['src/a.py'], True)):
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
        if rename_boundary:
            # A planned file that no verification reads, so a rename of it is
            # observed by the unplanned-path check rather than by a stale input.
            (root / 'src/extra.py').write_text('extra\n')
        run(['git', 'add', 'src', 'protected'])
        run(['git', '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
             'commit', '-q', '-m', 'fixture'])
        flow('set', '--phase', 'pr', '--next', 'review', '--pr', 71, '--issue', 42,
             '--worktree', str(root), '--require-worktree')
        selection = private / 'selection.json'
        selected = ['code-quality-reviewer', 'acceptance-reviewer']
        dump(selection, selected)
        flow('review-start', '--selection', selection, *(['--stagnation'] if use_run else []))
        state_path = Path(flow('path').stdout.strip())
        state = json.loads(state_path.read_text())
        context = state['review_cycle']['review_context']
        guard = plugin / 'hooks/pre-tool-bash-guard.sh'
        def hook(command='git commit -m fix', allowed=False, reason=None):
            payload = json.dumps(dict(tool_name='Bash', cwd=str(root), tool_input=dict(command=command)))
            result = subprocess.run(['bash', str(guard)], input=payload, cwd=root, env=env,
                                    text=True, capture_output=True)
            denied = bool(result.stdout.strip()) and json.loads(result.stdout).get('hookSpecificOutput', {}).get('permissionDecision') == 'deny'
            check(not denied if allowed else denied, command + ': ' + result.stdout + result.stderr)
            if not allowed:
                text = result.stdout + result.stderr
                check('review-commit-evidence' in result.stdout, 'fail-closed commit denial')
                check('review-finish' in text and 'verify --plan' in text and '--issue' in text,
                      'denied alternative names check/verify with plan and issue: ' + text)
                if reason:
                    check(reason in text, 'expected reason ' + reason + ' in ' + text)
            return result

        message_file = private / 'commit-message.txt'
        message_file.write_text('fix: preserve receipt\n\nRoot cause: the "review context" was skipped.\n'
                                'Keep `git commit` evidence bound to HEAD.\n')
        ordinary_recipe = caller_block((plugin / 'skills/fix/SKILL.md').read_text(), '# fix-commit-execute')
        ordinary_recipe = ordinary_recipe.replace('{changed_files}', 'src/a.py').replace('{commit_message_file}', str(message_file))
        old_head = run(['git', 'rev-parse', 'HEAD']).stdout
        for command in ('git commit -m fix', 'git -c user.name=Test commit --amend -m fix',
                        'git -C . commit -m fix', 'git commit -m --dry-run', 'git commit -am --dry-run', '/usr/bin/git commit -m fix',
                        'git status; git commit -m fix', 'cat <<EOF\nhello\nEOF\ngit commit -m fix'):
            hook(command, reason='review is incomplete')
        hook('if true; then git commit -m x; fi', reason='review is incomplete')
        hook('{ git commit -m x; }', reason='review is incomplete')
        hook('env git commit -m x', reason='review is incomplete')
        hook('nohup git commit -m x', reason='review is incomplete')
        hook('time git commit -m x', reason='review is incomplete')
        hook('exec git commit -m x', reason='review is incomplete')
        hook('command git commit -m x', reason='review is incomplete')
        check(run(['git', 'rev-parse', 'HEAD']).stdout == old_head, 'denial precedes HEAD change')
        hook(ordinary_recipe, reason='review is incomplete')
        hook('git commit --dry-run', allowed=True)
        hook('git commit --help', allowed=True)
        hook("printf '%s' 'git commit -m text'", allowed=True)
        hook("echo ';' git commit", allowed=True)
        hook("echo '\n' git commit", allowed=True)
        hook('git commit -m "first line\nsecond line"')
        hook('git commit -m"first line second line"')
        saved = state_path.read_bytes()
        state_path.unlink()
        hook(allowed=True)
        state_path.write_text('{invalid')
        hook(reason='Expecting property name')
        state_path.write_bytes(saved)
        normal = json.loads(saved)
        normal.pop('review_cycle')
        normal.pop('review_run', None)
        dump(state_path, normal)
        hook(allowed=True)
        state_path.write_bytes(saved)
        with tempfile.TemporaryDirectory(prefix='rite-unrelated-') as other:
            run(['git', 'worktree', 'add', '--detach', other, 'HEAD'])
            hook('git -C ' + other + ' commit -m unrelated', allowed=True)
            missing_wt = json.loads(state_path.read_text())
            missing_wt.pop('worktree', None)
            dump(state_path, missing_wt)
            hook('git -C ' + other + ' commit -m unrelated',
                 reason='session worktree path is missing from state')
            state_path.write_bytes(saved)

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
                           reviewers=selected, findings=findings, non_blocking_findings=[], guardrail_audit_log=[], acceptance_criteria=[]))
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
                                 paths=plan_paths, rationale='入力判定の修正で両指摘を解消する',
                                 semantic=dict(approved=True, acceptance_criteria='全指摘を一括修正するACに適合',
                                               out_of_scope='protectedは変更しない'), verification_ids=['related'])],
                    verifications=[dict(id='related', kind='related', command=related_command,
                                        inputs=['src/a.py'], environment=['SCOPE_TEST_ENV']),
                                   dict(id='full', kind='full', command="printf 'full\\n' >> .rite/full.log; test ! -f .rite/full-fail",
                                        inputs=full_inputs, environment=[])])
        canonical = private / ('state/fix-plan-' + session + '.json')
        verification_file = private / ('state/fix-verification-' + session + '.json')

        def invoke(mode='check', kind=None, ok=True):
            args = ['bash', str(helper), mode, '--plan', str(plan_file), '--issue', str(issue_file)]
            if kind:
                args += ['--kind', kind]
            return run(args, ok)

        def save_plan(value=plan):
            dump(plan_file, value)

        (private / 'state').mkdir(exist_ok=True)
        if use_run:
            clock_file = private / 'clock.json'
            dump(clock_file, dict(review_context=context, segment_id='work', kind='work',
                                 started_at='2026-01-01T00:00:00Z', ended_at='2026-01-01T00:00:01Z'))
            flow('review-clock', '--input', clock_file)
            observation = private / 'observation.json'
            dump(observation, dict(review_context=context, issue_number=42, issue_body=issue['body'],
                 roots=[dict(defect='shared input defect', trigger='invalid input',
                             violated_contract='input contract', finding_ids=['F-01', 'F-02'])],
                 acceptance=dict(satisfied=[], evidence='saved measurements')))
            flow('review-observe', '--input', observation, '--issue', issue_file)

        hook(reason='fix plan record missing')  # completed but no scope/verification
        save_plan()
        invoke('check')
        record = json.loads(canonical.read_text())
        check(record['issue']['number'] == 42 and 'body' in record['issue'],
              'check stores the validated Issue snapshot on the plan record')
        check(not (private / ('state/fix-issue-' + session + '.json')).exists(),
              'check does not plant a separate fix-issue file')
        hook(reason='fix-verification')  # scope approval alone is not verification
        source.write_text('fixed\n')
        invoke('verify', 'related')
        hook(reason='stale/missing verification: full')  # full verification is missing
        # A sandbox write-block stub is untracked but is not a real change. The
        # commit preflight must apply verify's mask, or the verified commit that
        # the fix recipe runs next becomes unreachable.
        stub = root / '.bashrc'
        stub.write_bytes(b'')
        stub.chmod(0o444)
        invoke('verify', 'all')
        check(stub.exists() and stub.stat().st_size == 0 and not stub.stat().st_mode & 0o222,
              'sandbox stub fixture is a 0-byte unwritable untracked file')
        before_state = state_path.read_bytes()
        before_receipt = verification_file.read_bytes()
        hook(ordinary_recipe, allowed=True)
        hook(allowed=True)
        hook('git commit -m "first line\nsecond line"', allowed=True)
        hook('git commit -m"first line second line"', allowed=True)
        if use_run:
            check('pending_fix' in json.loads(before_state)['review_run'], 'real full verification stores pending fix')
            missing = json.loads(before_state)
            missing['review_run'].pop('pending_fix')
            dump(state_path, missing)
            hook()
            state_path.write_bytes(before_state)
            flow('set', '--phase', 'review', '--next', 'stopped', '--active', 'false',
                 '--stop-reason', 'circuit-breaker:max-cycles')
            rejected = hook()
            check('review run stopped' in rejected.stdout, 'existing stagnation gate rejects stopped run')
            state_path.write_bytes(before_state)
        check(state_path.read_bytes() == before_state and verification_file.read_bytes() == before_receipt,
              'commit check is read only')
        if rename_boundary:
            # Renaming inside the plan is ordinary fix work and must stay allowed:
            # --no-renames lists both endpoints, and both are in scope here.
            run(['git', 'mv', 'src/extra.py', 'src/extra2.py'])
            hook(allowed=True)
            # Moving the file out of the plan is refused on the destination.
            run(['git', 'mv', 'src/extra2.py', 'escaped.py'])
            hook()
            run(['git', 'mv', 'escaped.py', 'src/extra2.py'])
            hook(allowed=True)
            # Moving a Non-Target file into the plan is refused on the source,
            # which only --no-renames keeps visible: rename detection would report
            # the in-scope destination alone and let the Non-Target change through.
            run(['git', 'mv', 'protected/secret.py', 'src/smuggled.py'])
            hook()
            run(['git', 'mv', 'src/smuggled.py', 'protected/secret.py'])
            run(['git', 'mv', 'src/extra2.py', 'src/extra.py'])
            hook(allowed=True)
            check(source.read_text() == 'fixed\n', 'rename boundary restored the verified tree')
        source.write_text('changed after verification\n')
        hook()
        source.write_text('fixed\n')
        hook(allowed=True)
        foreign = json.loads(verification_file.read_text())
        foreign['review_context']['cycle_count'] += 1
        dump(verification_file, foreign)
        hook()
        verification_file.write_bytes(before_receipt)
        run(['git', 'add', 'src/a.py'])
        hook(allowed=True)
        env.update(GIT_AUTHOR_NAME='Test', GIT_AUTHOR_EMAIL='test@example.invalid', GIT_COMMITTER_NAME='Test', GIT_COMMITTER_EMAIL='test@example.invalid')
        run(['bash', '-c', ordinary_recipe])
        check(run(['git', 'rev-parse', 'HEAD']).stdout != old_head, 'verified commit succeeds')

# Mergeable completed cycle and active retained run must not lock out ordinary commits.
with tempfile.TemporaryDirectory(prefix='rite-fix-scope-mergeable-') as tmp:
    root = Path(tmp)
    private = root / '.rite'
    private.mkdir()
    env = dict(os.environ)
    for key in ('CODEX_THREAD_ID', 'GROK_SESSION_ID', 'CLAUDE_SESSION_ID',
                'CLAUDE_CODE_SESSION_ID', 'RITE_SESSION_ID', 'RITE_HOST', 'RITE_STATE_ROOT',
                'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE'):
        env.pop(key, None)
    session = 'fix-scope-test'
    env.update(RITE_HOST='claude', CLAUDE_CODE_SESSION_ID=session, RITE_STATE_ROOT=tmp, TMPDIR=tmp)

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
    (root / 'src/a.py').write_text('original\n')
    run(['git', 'add', 'src'])
    run(['git', '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-q', '-m', 'fixture'])
    flow('set', '--phase', 'pr', '--next', 'review', '--pr', 71, '--issue', 42,
         '--worktree', str(root), '--require-worktree')
    selection = private / 'selection.json'
    selected = ['code-quality-reviewer', 'acceptance-reviewer']
    dump(selection, selected)
    flow('review-start', '--selection', selection, '--stagnation')
    state_path = Path(flow('path').stdout.strip())
    state = json.loads(state_path.read_text())
    context = state['review_cycle']['review_context']
    guard = plugin / 'hooks/pre-tool-bash-guard.sh'

    def hook(command='git commit -m fix', allowed=False, reason=None):
        payload = json.dumps(dict(tool_name='Bash', cwd=str(root), tool_input=dict(command=command)))
        result = subprocess.run(['bash', str(guard)], input=payload, cwd=root, env=env,
                                text=True, capture_output=True)
        denied = bool(result.stdout.strip()) and json.loads(result.stdout).get('hookSpecificOutput', {}).get('permissionDecision') == 'deny'
        check(not denied if allowed else denied, command + ': ' + result.stdout + result.stderr)
        if not allowed:
            text = result.stdout + result.stderr
            check('review-commit-evidence' in result.stdout, 'fail-closed commit denial')
            check('review-finish' in text and 'verify --plan' in text, 'denied alternative: ' + text)
            if reason:
                check(reason in text, 'expected reason ' + reason + ' in ' + text)
        return result

    records = []
    for index, reviewer in enumerate(selected):
        raw = private / (reviewer + '.md')
        raw.write_text('### 評価: 可\n### 所見\n確認済み\n### 指摘事項\n\n| 重要度 | スコープ | ファイル:行 | 内容 | 推奨対応 |\n|--------|----------|------------|------|----------|\n\n### 監査ログ\nなし\n')
        records.append(dict(reviewer=reviewer, review_context=context, agent_id='child-' + str(index),
                            status='completed', started_at='2026-01-01T00:00:00Z',
                            ended_at='2026-01-01T00:01:00Z', output_file=str(raw)))
    manifest = private / 'manifest.json'
    dump(manifest, dict(schema_version=1, parent_agent_id=session, review_context=context,
                        selected_reviewers=selected, reviewers=records))
    content = private / 'review.json'
    dump(content, dict(schema_version='1.1.0', pr_number=71, review_context=context,
                       timestamp='__RITE_TS_PLACEHOLDER_7f3a9b2c__', commit_sha=context['commit_sha'],
                       reviewers=selected, findings=[], non_blocking_findings=[], guardrail_audit_log=[],
                       acceptance_criteria=[]))
    run(['bash', str(plugin / 'scripts/review-measured-gate.sh'), '--input', str(content),
         '--reject-preset-verification'])
    flow('review-finish', '--manifest', manifest, '--content-file', content)
    cycle = json.loads(state_path.read_text())['review_cycle']
    check(cycle['status'] == 'completed' and cycle['verdict'] == 'mergeable', 'empty findings are mergeable')
    hook(allowed=True)

with tempfile.TemporaryDirectory(prefix='rite-fix-scope-retained-') as tmp:
    root = Path(tmp)
    private = root / '.rite'
    private.mkdir()
    env = dict(os.environ)
    for key in ('CODEX_THREAD_ID', 'GROK_SESSION_ID', 'CLAUDE_SESSION_ID',
                'CLAUDE_CODE_SESSION_ID', 'RITE_SESSION_ID', 'RITE_HOST', 'RITE_STATE_ROOT',
                'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE'):
        env.pop(key, None)
    session = 'fix-scope-test'
    env.update(RITE_HOST='claude', CLAUDE_CODE_SESSION_ID=session, RITE_STATE_ROOT=tmp, TMPDIR=tmp)

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
    (root / 'src/a.py').write_text('original\n')
    run(['git', 'add', 'src'])
    run(['git', '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-q', '-m', 'fixture'])
    flow('set', '--phase', 'pr', '--next', 'review', '--pr', 71, '--issue', 42,
         '--worktree', str(root), '--require-worktree')
    selection = private / 'selection.json'
    dump(selection, ['code-quality-reviewer', 'acceptance-reviewer'])
    flow('review-start', '--selection', selection, '--stagnation')
    guard = plugin / 'hooks/pre-tool-bash-guard.sh'

    def hook(command='git commit -m fix', allowed=False, reason=None):
        payload = json.dumps(dict(tool_name='Bash', cwd=str(root), tool_input=dict(command=command)))
        result = subprocess.run(['bash', str(guard)], input=payload, cwd=root, env=env,
                                text=True, capture_output=True)
        denied = bool(result.stdout.strip()) and json.loads(result.stdout).get('hookSpecificOutput', {}).get('permissionDecision') == 'deny'
        check(not denied if allowed else denied, command + ': ' + result.stdout + result.stderr)
        if not allowed:
            text = result.stdout + result.stderr
            check('review-commit-evidence' in result.stdout, 'fail-closed commit denial')
            if reason:
                check(reason in text, 'expected reason ' + reason + ' in ' + text)
        return result

    flow('review-abandon', '--reason', 'test-retained')
    abandoned = json.loads(Path(flow('path').stdout.strip()).read_text())
    check(abandoned.get('review_cycle') is None and 'review_run' in abandoned, 'abandon retains the run')
    hook(allowed=True)
    state_path = Path(flow('path').stdout.strip())
    stopped = json.loads(state_path.read_text())
    stopped['review_run']['status'] = 'stopped'
    stopped['review_run']['stop_reason'] = 'circuit-breaker:max-cycles'
    dump(state_path, stopped)
    hook(reason='review run stopped')
print(str(checks) + ' checks passed')
PYTEST
