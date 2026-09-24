#!/usr/bin/env bash
# Exercise scope planning and validation through real persisted review receipts.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 - "$SCRIPT_DIR/../.." <<'PYTEST'
import copy
import json
import os
import re
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
        hook('env -u GIT_DIR git commit -m x', reason='run commit as a direct command')
        hook('sudo git commit -m x', reason='run commit as a direct command')
        hook('sudo git -C . commit -m x', reason='run commit as a direct command')
        hook('env -u GIT_DIR git --no-pager commit -m x', reason='run commit as a direct command')
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
        hook('git merge main', allowed=True)
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

# Mergeable is not verification evidence for later edits. An unverified commit
# is denied; the same HEAD can still open the next review. A verified commit
# must reach the next review-start (asserted in the use_run loop below).
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
    issue_file = private / 'issue.json'
    dump(issue_file, dict(number=42, body='## Acceptance Criteria\n- [ ] AC-1 pass'))
    clock_file = private / 'clock.json'
    dump(clock_file, dict(review_context=context, segment_id='real-test', kind='work',
                         started_at='2026-01-01T00:00:00Z', ended_at='2026-01-01T00:01:00Z'))
    flow('review-clock', '--input', clock_file)
    observation = private / 'observation.json'
    dump(observation, dict(review_context=context, issue_number=42,
                           issue_body='## Acceptance Criteria\n- [ ] AC-1 pass', roots=[],
                           acceptance=dict(satisfied=[], evidence='saved measurements')))
    flow('review-observe', '--input', observation, '--issue', issue_file)
    mergeable_head = run(['git', 'rev-parse', 'HEAD']).stdout
    hook(reason='fix plan record missing')
    (root / 'src/a.py').write_text('post review change\n')
    run(['git', 'add', 'src/a.py'])
    hook(reason='fix plan record missing')
    check(run(['git', 'rev-parse', 'HEAD']).stdout == mergeable_head,
          'unverified post-mergeable commit does not move HEAD')
    run(['git', 'checkout', 'HEAD', '--', 'src/a.py'])
    flow('review-start', '--selection', selection, '--stagnation')
    restarted = json.loads(state_path.read_text())
    check(restarted['review_cycle']['review_context']['commit_sha'] == mergeable_head.strip(),
          'same-HEAD review-start after mergeable keeps the frozen HEAD')
    check(restarted['review_cycle']['status'] == 'collecting', 'next review is collecting')
    check(run(['git', 'rev-parse', 'HEAD']).stdout == mergeable_head,
          'review-start does not change HEAD')

# Verified fix commit must open the next review on the new HEAD.
with tempfile.TemporaryDirectory(prefix='rite-fix-scope-next-review-') as tmp:
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
            check('review-finish' in text and 'verify --plan' in text and '--issue' in text,
                  'denied alternative names check/verify with plan and issue: ' + text)
            if reason:
                check(reason in text, 'expected reason ' + reason + ' in ' + text)
        return result

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
                       reviewers=selected, findings=findings, non_blocking_findings=[],
                       guardrail_audit_log=[], acceptance_criteria=[]))
    run(['bash', str(plugin / 'scripts/review-measured-gate.sh'), '--input', str(content),
         '--reject-preset-verification'])
    flow('review-finish', '--manifest', manifest, '--content-file', content)
    issue = {'number': 42, 'body': '## 4. 対象範囲\n### 4.1 対象\n- `src/a.py`\n'
             '### 4.2 対象外\n- `protected`\n## 5. 受入条件\n- 全指摘を一括修正する\n'}
    issue_file, plan_file = private / 'issue.json', private / 'plan.json'
    dump(issue_file, issue)
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
    plan = dict(review_context=context, issue_number=42, issue_body=issue['body'],
                constraints=dict(targets=['src/a.py'], non_targets=['protected'], closed_targets=False,
                                 rationale='Issue target候補なので開集合'),
                groups=[dict(root_cause='共有する入力判定の欠落', finding_ids=['F-01', 'F-02'], action='fix',
                             paths=['src/a.py'], rationale='入力判定の修正で両指摘を解消する',
                             semantic=dict(approved=True, acceptance_criteria='全指摘を一括修正するACに適合',
                                           out_of_scope='protectedは変更しない'), verification_ids=['related'])],
                verifications=[dict(id='related', kind='related',
                                    command="printf 'related\\n' >> .rite/related.log",
                                    inputs=['src/a.py'], environment=['SCOPE_TEST_ENV']),
                               dict(id='full', kind='full',
                                    command="printf 'full\\n' >> .rite/full.log",
                                    inputs=['src/a.py'], environment=[])])
    dump(plan_file, plan)
    run(['bash', str(helper), 'check', '--plan', str(plan_file), '--issue', str(issue_file)])
    source.write_text('fixed\n')
    run(['bash', str(helper), 'verify', '--plan', str(plan_file), '--issue', str(issue_file), '--kind', 'all'])
    hook(allowed=True)
    message_file = private / 'commit-message.txt'
    message_file.write_text('fix: preserve receipt\n\nRoot cause: the "review context" was skipped.\n'
                            'Keep `git commit` evidence bound to HEAD.\n')
    env.update(GIT_AUTHOR_NAME='Test', GIT_AUTHOR_EMAIL='test@example.invalid',
               GIT_COMMITTER_NAME='Test', GIT_COMMITTER_EMAIL='test@example.invalid')
    run(['git', 'add', '--', 'src/a.py'])
    run(['git', 'commit', '-F', str(message_file)])
    verified_head = run(['git', 'rev-parse', 'HEAD']).stdout.strip()
    check(verified_head != context['commit_sha'], 'verified commit moved HEAD')
    flow('review-start', '--selection', selection, '--stagnation')
    restarted = json.loads(state_path.read_text())
    restarted_ctx = restarted['review_cycle']['review_context']
    check(restarted_ctx['commit_sha'] == verified_head, 'next review freezes the verified HEAD')
    check(restarted_ctx['cycle_count'] == context['cycle_count'] + 1, 'verified commit advances the cycle')
    check(restarted['review_cycle']['status'] == 'collecting', 'next review is collecting')
    check(restarted['review_run'].get('pending_fix') is None, 'advance consumes pending_fix')
    check(len(restarted['review_run']['fixes']) == 1, 'verified HEAD is recorded as a fix')

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
    hook('git merge --continue', allowed=True)
    hook('git merge main', allowed=True)
    state_path = Path(flow('path').stdout.strip())
    stopped = json.loads(state_path.read_text())
    stopped['review_run']['status'] = 'stopped'
    stopped['review_run']['stop_reason'] = 'circuit-breaker:max-cycles'
    dump(state_path, stopped)
    hook(reason='review run stopped')
    hook('git merge --continue', reason='review run stopped')
    hook('git merge main', reason='review run stopped')
# Taking the base branch into a reviewed branch: every merge route that moves HEAD
# meets the same evidence check, and a base-intake plan carries the intake into the
# next cycle of the same run even when the base touches the Issue's Non-Target files.
for closed_targets in (False, True):
    with tempfile.TemporaryDirectory(prefix='rite-base-intake-') as tmp:
        root = Path(tmp)
        private = root / '.rite'
        private.mkdir()
        env = dict(os.environ)
        for key in ('CODEX_THREAD_ID', 'GROK_SESSION_ID', 'CLAUDE_SESSION_ID',
                    'CLAUDE_CODE_SESSION_ID', 'RITE_SESSION_ID', 'RITE_HOST', 'RITE_STATE_ROOT',
                    'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE'):
            env.pop(key, None)
        session = 'fix-scope-test'
        env.update(RITE_HOST='claude', CLAUDE_CODE_SESSION_ID=session, RITE_STATE_ROOT=tmp, TMPDIR=tmp,
                   GIT_AUTHOR_NAME='Test', GIT_AUTHOR_EMAIL='test@example.invalid',
                   GIT_COMMITTER_NAME='Test', GIT_COMMITTER_EMAIL='test@example.invalid')

        def run(args, ok=True, cwd=None):
            result = subprocess.run(args, cwd=cwd or root, env=env, text=True, capture_output=True)
            if ok:
                check(result.returncode == 0, repr(args) + '\n' + result.stdout + result.stderr)
            return result

        def flow(*args, ok=True):
            return run(['bash', str(plugin / 'hooks/flow-state.sh'), *map(str, args)], ok=ok)

        guard = plugin / 'hooks/pre-tool-bash-guard.sh'

        def hook(command, allowed=False, reason=None, cwd=None):
            payload = json.dumps(dict(tool_name='Bash', cwd=str(cwd or root), tool_input=dict(command=command)))
            result = subprocess.run(['bash', str(guard)], input=payload, cwd=cwd or root, env=env,
                                    text=True, capture_output=True)
            denied = bool(result.stdout.strip()) and json.loads(result.stdout).get('hookSpecificOutput', {}).get('permissionDecision') == 'deny'
            check(not denied if allowed else denied, command + ': ' + result.stdout + result.stderr)
            if not allowed:
                text = result.stdout + result.stderr
                check('review-commit-evidence' in result.stdout, 'merge denial is the review evidence check: ' + command)
                # The existing guidance stays; the intake route is added to it.
                check('review-finish' in text and 'git commit -F <message-file>' in text
                      and 'base-intake fix plan' in text, 'denial keeps and extends the guidance: ' + text)
                if reason:
                    check(reason in text, 'expected reason ' + reason + ' in ' + text)
            return result

        run(['git', 'init', '-q', '-b', 'trunk'])
        (root / '.git/info/exclude').write_text('.rite/\nrite-config.yml\n')
        (root / 'rite-config.yml').write_text('branch:\n  base: "trunk"  # reviewed PRs merge here\n')
        (root / 'src').mkdir()
        (root / 'src/a.py').write_text('original\n')
        (root / 'protected').mkdir()
        (root / 'protected/secret.py').write_text('original\n')
        run(['git', 'add', 'src', 'protected'])
        run(['git', 'commit', '-q', '-m', 'fixture'])
        # A branch that is not the base: its Non-Target change is Issue work, never intake.
        run(['git', 'switch', '-q', '-c', 'side'])
        (root / 'protected/secret.py').write_text('side\n')
        run(['git', 'commit', '-q', '-am', 'side'])
        run(['git', 'switch', '-q', 'trunk'])
        run(['git', 'switch', '-q', '-c', 'feat'])
        (root / 'src/a.py').write_text('feature\n')
        (root / 'src/feature.py').write_text('feature only\n')
        run(['git', 'add', '-A'])
        run(['git', 'commit', '-q', '-m', 'feature'])
        run(['git', 'switch', '-q', 'trunk'])
        (root / 'src/a.py').write_text('base\n')
        (root / 'protected/secret.py').write_text('base\n')
        (root / 'src/base-only.py').write_text('base only\n')
        run(['git', 'add', '-A'])
        run(['git', 'commit', '-q', '-m', 'base'])
        run(['git', 'update-ref', 'refs/remotes/origin/trunk', 'trunk'])
        # A commit on top of the base is not the base either.
        run(['git', 'switch', '-q', '-c', 'desc'])
        (root / 'protected/secret.py').write_text('desc\n')
        run(['git', 'commit', '-q', '-am', 'desc'])
        run(['git', 'switch', '-q', 'feat'])
        body = '## Acceptance Criteria\n- [ ] AC-1 pass\n\n### 4.2 Non-Target Files\n\n- `protected/secret.py`: keep\n'
        issue_file = private / 'issue.json'
        dump(issue_file, dict(number=42, body=body))
        flow('set', '--phase', 'pr', '--next', 'review', '--pr', 71, '--issue', 42, '--branch', 'feat',
             '--worktree', str(root), '--require-worktree')
        selection = private / 'selection.json'
        selected = ['code-quality-reviewer', 'acceptance-reviewer']
        dump(selection, selected)
        flow('review-start', '--selection', selection, '--stagnation')
        state_path = Path(flow('path').stdout.strip())
        context = json.loads(state_path.read_text())['review_cycle']['review_context']
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
        clock_file = private / 'clock.json'
        dump(clock_file, dict(review_context=context, segment_id='intake-test', kind='work',
                              started_at='2026-01-01T00:00:00Z', ended_at='2026-01-01T00:01:00Z'))
        flow('review-clock', '--input', clock_file)
        observation = private / 'observation.json'
        dump(observation, dict(review_context=context, issue_number=42, issue_body=body, roots=[],
                               acceptance=dict(satisfied=[], evidence='saved measurements')))
        flow('review-observe', '--input', observation, '--issue', issue_file)
        flow('review-close')
        reviewed_head = run(['git', 'rev-parse', 'HEAD']).stdout.strip()

        # Routes that would move HEAD without verified evidence are refused alike.
        intake = 'git merge --no-commit --no-ff'
        hook('git merge main', reason='cannot be verified during review')
        hook('git -C ' + str(root) + ' merge main', reason='cannot be verified during review')
        hook('git merge -m --no-commit main', reason='cannot be verified during review')
        hook('git merge main; echo done', reason='cannot be verified during review')
        steps = hook('git merge origin/main', reason='cannot be verified during review')
        check('git merge --no-commit --no-ff origin/<base>' in steps.stdout and 'verify --kind all' in steps.stdout
              and 'push' in steps.stdout, 'the refusal carries the intake steps: ' + steps.stdout)
        # git reads these options last-one-wins, so a later option overrides an exemption.
        for command in ('git merge --no-commit --commit main', 'git merge --ff-only --no-ff main',
                        'git merge --squash --no-squash main', 'git merge --message --no-commit main',
                        'git merge -nm --no-commit main'):
            hook(command, reason='cannot be verified during review')
        for command in ('sudo git merge main', 'env -u GIT_DIR git merge --continue', 'timeout 60 git merge main'):
            hook(command, reason='run merge as a direct command')
        # A substitution runs its command even inside double quotes or backquotes, in a subshell.
        hook('out="$(git merge origin/trunk 2>&1)"', reason='run merge as a direct command')
        hook('echo "`git merge main`"', reason='run merge as a direct command')
        hook('v=`git merge main`', reason='run merge as a direct command')
        hook('x="$(git commit -m y)"', reason='run commit as a direct command')
        hook('x="$(echo "(a (b) c)"; git -C .. merge main)"', reason='run merge as a direct command')
        # A cd inside a substitution stays in its subshell.
        hook('x="$(cd "$HOME" && pwd)"; git merge main', reason='cannot be verified during review')
        hook('x="$(cd "$HOME")"; git commit -m y', reason='fix plan record missing')
        hook('git commit -m "$(cat <<\'EOF\'\nno end\n)"', reason='unfinished heredoc')
        hook('git commit -m "$(echo x"', reason='unfinished command substitution')
        # git takes a unique prefix of a long option; an abbreviation cannot be read safely.
        for command in ('git merge --no-commit --commi main', 'git merge --mess --no-commit main'):
            hook(command, reason='abbreviated git merge option')
        for command in (intake + ' main', 'git merge --squash main', 'git merge --abort',
                        'git merge --quit', 'git merge --ff-only main', 'git merge --commit --no-commit main',
                        'git log --merges', 'cd "$HOME" && git merge-base HEAD main',
                        'NOTE="?? (merge check failed)"; git status', 'NOTE="x; git merge main"; git status',
                        'cd "$HOME" && git merge --abort', 'sudo git merge --abort', 'git -C "$HOME" merge --quit'):
            hook(command, allowed=True)
        # cleanup's base update runs in a reviewed session and only fast-forwards.
        cleanup = caller_block((plugin / 'skills/cleanup/SKILL.md').read_text(),
                               'git merge --ff-only origin/{base_branch} 2>/dev/null; do')
        hook(cleanup, allowed=True)
        # The heredoc message form is the everyday commit: its body is data, whatever it says.
        def heredoc(text, verb='git commit -m'):
            return verb + ' "$(cat <<\'EOF\'\n' + text + '\n\nCo-Authored-By: x <y@z>\nEOF\n)"'
        bodies = ("fix: it's done", 'fix: tidy\n\ncd ..', 'fix: explain\n\nrun git merge origin/main first',
                  'fix: explain\n\nthen git commit -m again', 'fix: handle (edge) case)',
                  'fix: quote "x" and `y`')
        for text in bodies:
            targets = run(['bash', str(helper), 'commit-target', '--command', heredoc(text), '--cwd', str(root)])
            lines = targets.stdout.splitlines()
            check(len(lines) == 1 and lines[0].split('\t')[0] == 'index'
                  and Path(lines[0].split('\t')[1]) == root.resolve(), 'heredoc commit targets the index: ' + text)
            hook(heredoc(text), reason='fix plan record missing')
            hook(heredoc(text, 'gh pr comment 71 --body'), allowed=True)
        for command in ('git commit -F /tmp/msg.txt', 'git add -A && git commit -m "fix: a\n\nbody"'):
            hook(command, reason='fix plan record missing')
        # Every fenced bash block in the plugin that runs git commit / git merge still parses.
        docs = [path for folder in ('skills', 'references') for path in sorted((plugin / folder).rglob('*.md'))]
        blocks = [block for path in docs
                  for block in re.findall(r'```bash\n(.*?)\n```', path.read_text(encoding='utf-8'), re.S)
                  if re.search(r'git[^\n]*\b(commit|merge)\b', block)]
        check(len(blocks) >= 10, 'the corpus finds the plugin commit blocks')
        for block in blocks:
            parsed = run(['bash', str(helper), 'commit-target', '--command', block, '--cwd', str(root)], ok=False)
            check(not any(word in parsed.stderr for word in ('unfinished', 'ambiguous', 'Traceback')),
                  'plugin block parses: ' + block[:80] + '\n' + parsed.stderr)
        # Pattern 9 keeps reading only git commit: merges do not become wiki-gated commits.
        targets = run(['bash', str(helper), 'commit-target', '--command', 'git merge --continue',
                       '--cwd', str(root)])
        check(targets.stdout.strip() == '', 'commit-target does not report git merge')
        targets = run(['bash', str(helper), 'commit-target', '--command', 'sudo git merge --abort; echo commit',
                       '--cwd', str(root)])
        check(targets.stdout.strip() == '', 'commit-target ignores a wrapped merge')
        plain = hook(intake + ' main && git commit -m intake', reason='fix plan record missing')
        check('this concludes a merge' not in plain.stdout, 'no merge in progress, no intake hint: ' + plain.stdout)
        # A merge outside the reviewed worktree is not this review's business.
        with tempfile.TemporaryDirectory(prefix='rite-other-repo-') as other:
            run(['git', 'init', '-q'], cwd=other)
            hook('git merge main', allowed=True, cwd=Path(other))
        # From another worktree of the same repository, a merge aimed back at the review is refused.
        with tempfile.TemporaryDirectory(prefix='rite-linked-') as linked:
            run(['git', 'worktree', 'add', '-q', '--detach', linked, 'HEAD'])
            hook('git merge main', allowed=True, cwd=Path(linked))
            hook('cd "$WT" && git merge main', reason='target is dynamic', cwd=Path(linked))
            hook('git -C "$WT" merge main', reason='target is dynamic', cwd=Path(linked))
            hook('git -C"$WT" merge main', reason='target is dynamic', cwd=Path(linked))
            run(['git', 'worktree', 'remove', '--force', linked])

        def plan_for(groups, **constraints):
            plan = dict(review_context=context, issue_number=42, issue_body=body,
                        constraints=dict(targets=['src'] if closed_targets else [],
                                         non_targets=['protected/secret.py'],
                                         closed_targets=closed_targets, rationale='base intake test'),
                        groups=groups,
                        verifications=[dict(id='V-full', kind='full', command='true', inputs=['src'],
                                            environment=[])])
            plan['constraints'].update(constraints)
            path = private / 'intake-plan.json'
            dump(path, plan)
            return path

        def group(paths, action='base-intake', verification=None, cause='base intake'):
            return dict(root_cause=cause, finding_ids=[], action=action, paths=paths, rationale='merged base',
                        semantic=dict(approved=True, acceptance_criteria='AC-1', out_of_scope='base content'),
                        verification_ids=['V-full'] if verification is None else verification)

        def rejected(plan_path, reason):
            result = run(['bash', str(helper), 'check', '--plan', str(plan_path), '--issue', str(issue_file)],
                         ok=False)
            check(result.returncode != 0 and reason in result.stderr, 'expected ' + reason + ': ' + result.stderr)

        # A base-intake plan exempts nothing without a merge of the base in progress.
        rejected(plan_for([group(['src/a.py'])]), 'base intake requires a merge in progress')
        run(['git', 'merge', '--no-commit', '--no-ff', 'side'], ok=False)
        run(['git', 'add', '-A'])
        rejected(plan_for([group(['protected/secret.py'])]), 'is not origin/trunk or its ancestor')
        run(['git', 'merge', '--abort'])
        run(['git', 'merge', '--no-commit', '--no-ff', 'desc'], ok=False)
        run(['git', 'add', '-A'])
        rejected(plan_for([group(['protected/secret.py'])]), 'is not origin/trunk or its ancestor')
        run(['git', 'merge', '--abort'])
        merge = run(['git', 'merge', '--no-commit', '--no-ff', 'origin/trunk'], ok=False)
        check(merge.returncode != 0 and (root / '.git/MERGE_HEAD').exists(), 'base intake stops on the conflict')
        (root / 'src/a.py').write_text('resolved\n')
        run(['git', 'add', '-A'])
        # Both conclusion routes wait for the same plan, and name the intake route.
        hook('git commit --no-edit', reason='this concludes a merge')
        concludes = hook('git merge --continue', reason='this concludes a merge')
        check('push' in concludes.stdout and '/rite:iterate' in concludes.stdout
              and 'otherwise git merge --abort' in concludes.stdout, 'the hint carries the rest of the route')
        hook('git --git-dir=.git merge main', reason='without alternate git-dir')
        hook('git --git-dir=.git merge --abort', allowed=True)

        merged = ['protected/secret.py', 'src/a.py', 'src/base-only.py']
        # A path the base did not change keeps the Issue's target constraints.
        rejected(plan_for([group(merged + ['protected'])]), 'Non-Target violation: protected')
        # The intake exemption belongs to the intake group, not to a fix group.
        other_fix = dict(group(['protected/secret.py'], action='fix', cause='other'), finding_ids=['EXT-1'])
        external = plan_for([group(merged), other_fix])
        with_external = json.loads(external.read_text())
        with_external['external_findings'] = [dict(id='EXT-1', thread_id='t', description='d')]
        dump(external, with_external)
        rejected(external, 'Non-Target violation: protected/secret.py')
        rejected(plan_for([group(merged), group(['src/a.py'], cause='again')]), 'combine base intake into one group')
        rejected(plan_for([group(merged, verification=[])]), 'every disposition requires verification')
        rejected(plan_for([group([])]), 'base intake requires the merged paths')
        rejected(plan_for([group(merged), group(['src/a.py'], action='fix', cause='fix')]), 'group finding IDs required')
        if closed_targets:
            # A file only the feature changed is Issue work and keeps the closed targets.
            rejected(plan_for([group(merged + ['src/feature.py'])], targets=['protected']),
                     'closed target violation: src/feature.py')
        config = root / 'rite-config.yml'
        saved_config = config.read_text()
        config.unlink()
        rejected(plan_for([group(merged)]), 'rite-config.yml not found')
        for text in ('branch:\n  prefix: x\n', 'branch:\n  base: null\n', 'wiki:\n  base: trunk\n'):
            config.write_text(text)
            rejected(plan_for([group(merged)]), 'branch.base is not set in')
        config.write_bytes(b'branch:\n  base: \xff\n')
        rejected(plan_for([group(merged)]), 'cannot read rite-config.yml')
        if os.getuid() != 0:
            config.write_text(saved_config)
            config.chmod(0)
            rejected(plan_for([group(merged)]), 'cannot read rite-config.yml')
            config.chmod(0o644)
        config.write_text(saved_config)
        good = plan_for([group(merged)])
        run(['bash', str(helper), 'check', '--plan', str(good), '--issue', str(issue_file)])
        run(['bash', str(helper), 'verify', '--plan', str(good), '--issue', str(issue_file), '--kind', 'all'])
        hook('git commit --no-edit', allowed=True)
        hook('git merge --continue', allowed=True)
        hook('git -C src commit --no-edit', allowed=True)
        hook('git commit --no-edit', allowed=True, cwd=root / 'src')
        run(['git', 'commit', '--no-edit'])
        check(run(['git', 'rev-parse', 'HEAD^1']).stdout.strip() == reviewed_head, 'intake is a merge onto the reviewed HEAD')
        before = json.loads(state_path.read_text())
        flow('review-start', '--selection', selection, '--stagnation')
        after = json.loads(state_path.read_text())
        next_context = after['review_cycle']['review_context']
        check(next_context['run_id'] == context['run_id'], 'intake continues the same run')
        check(after['cycle_count'] == before['cycle_count'] + 1 == 2, 'intake opens exactly the next cycle')
        check('pending_fix' not in after['review_run'] and len(after['review_run']['fixes']) == 1,
              'verified intake is consumed as the change between cycles')
        check(next_context['commit_sha'] == run(['git', 'rev-parse', 'HEAD']).stdout.strip(),
              'next cycle reviews the intake commit')

print(str(checks) + ' checks passed')
PYTEST
