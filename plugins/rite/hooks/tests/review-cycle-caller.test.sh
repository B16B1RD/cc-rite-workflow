#!/usr/bin/env bash
# Execute the documented caller blocks against isolated real workflow helpers.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 - "$SCRIPT_DIR/../.." <<'PY'
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

plugin = Path(sys.argv[1]).resolve()
review = (plugin / 'skills/pr-review/SKILL.md').read_text()
iterate = (plugin / 'skills/iterate/SKILL.md').read_text()
recover = (plugin / 'skills/recover/SKILL.md').read_text()
batch = (plugin / 'skills/batch-run/SKILL.md').read_text()
diagnostic = (plugin / 'references/review-stagnation.md').read_text()

def block(text, marker):
    assert text.count(marker) == 1, 'caller block missing or ambiguous: ' + marker
    at = text.index(marker)
    start = text.rfind('```bash\n', 0, at) + len('```bash\n')
    end = text.index('\n```', at)
    assert start >= len('```bash\n') and start <= at < end
    return text[start:end]

start_block = block(review, '# review-cycle-start')
finish_block = block(review, '# review-cycle-finish')
recover_block = block(recover, '# review-cycle-recover')
iterate_block = block(iterate, '# review-cycle-resume-gate')
entry_block = block(review, '# review-cycle-e2e-entry')
breaker_block = block(iterate, '# review-cycle-breaker-reset')

with tempfile.TemporaryDirectory(prefix='rite-review-caller-') as temp:
    work = Path(temp)
    env = {k: v for k, v in os.environ.items() if k not in (
        'CODEX_THREAD_ID', 'CLAUDE_CODE_SESSION_ID', 'RITE_SESSION_ID', 'RITE_STATE_ROOT')}
    env.update(RITE_STATE_ROOT=str(work), RITE_HOST='claude', CLAUDE_CODE_SESSION_ID='caller-test')

    def run(args, success=True):
        output = subprocess.run(args, cwd=work, env=env, text=True, capture_output=True)
        if success:
            assert output.returncode == 0, output.stdout + output.stderr
        return output

    def flow(*args, success=True):
        return run(['bash', str(plugin / 'hooks/flow-state.sh'), *map(str, args)], success)

    def state():
        return json.loads(flow('get', '--jq-filter', '.').stdout)

    selection = work / 'selection.json'
    manifest = work / 'manifest.json'
    content = work / 'rite-review-result-4242.json'
    replacements = {
        'plugin_root': str(plugin), 'reviewer_selection_file': str(selection),
        'reviewer_completions_file': str(manifest), 'review_tmp_dir': str(work),
        'pr_number': '4242', 'issue_number': '4241', 'branch_name': 'caller-test', 'save_pending_id': '',
        'cb_reason': 'max-cycles', 'head_ref': 'caller-test'}

    def execute(body, success=True):
        for key, value in replacements.items():
            body = body.replace('{' + key + '}', value)
        return run(['bash', '-c', body], success)

    run(['git', 'init', '-q'])
    run(['git', '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
         'commit', '-q', '--allow-empty', '-m', 'fixture'])
    # Disabled worktree entry reaches the actual initializer without pre-created state.
    (work / 'rite-config.yml').write_text('multi_session:\n  enabled: false\n')
    init_block = block(iterate, '# review-state-initialize')
    state_path = Path(flow('path').stdout.strip())
    state_path.parent.mkdir(parents=True, exist_ok=True)
    # Both documented entrances must preserve malformed existing state byte-for-byte.
    selection.write_text(json.dumps(['test-reviewer']))
    for caller in (init_block, start_block):
        for corrupt in ('{"review_cycle":', 'null', '[]', ''):
            state_path.write_text(corrupt)
            output = execute(caller, False)
            assert output.returncode != 0, 'corrupt state accepted'
            assert 'cannot read review state' in output.stderr
            assert state_path.read_text() == corrupt, 'corrupt state overwritten'
    state_path.unlink()
    execute(init_block)
    assert state()['pr_number'] == 4242 and state()['phase'] == 'pr'
    assert state()['issue_number'] == 4241
    assert 'PR_REVIEW_IN_E2E=true' in execute(entry_block).stdout
    # Standalone pr-review must also initialize without iterate or a worktree.
    state_path = Path(flow('path').stdout.strip())
    state_path.unlink()
    selection.write_text(json.dumps(['security-reviewer', 'test-reviewer', 'code-quality-reviewer', 'acceptance-reviewer']))
    assert execute(finish_block, False).returncode != 0, 'finish without begin must fail'
    execute(start_block)
    initialized = state_path.read_bytes()
    wrong = start_block.replace('{pr_number}', '9999')
    assert execute(wrong, False).returncode != 0, 'different PR state overwritten'
    assert state_path.read_bytes() == initialized
    frozen = state()['review_cycle']
    assert state()['cycle_count'] == 1 and len(frozen['selected_reviewers']) == 4
    execute(start_block)
    assert state()['cycle_count'] == 1, 'begin retry double-counted'

    # A full roster larger than three available slots cannot be consolidated after one wave.
    context = frozen['review_context']
    records = []
    for index, name in enumerate(frozen['selected_reviewers']):
        raw = work / (name + '.md')
        raw.write_text('### 評価: 可\n### 所見\n確認済み\n### 指摘事項\nなし\n### 監査ログ\nなし\n')
        records.append(dict(reviewer=name, review_context=context, agent_id='child-' + str(index),
                            status='completed', started_at='2026-01-01T00:00:00Z',
                            ended_at='2026-01-01T00:01:00Z', output_file=str(raw)))
    data = dict(schema_version=1, parent_agent_id='caller-test', review_context=context,
                selected_reviewers=frozen['selected_reviewers'], reviewers=records[:3])
    manifest.write_text(json.dumps(data))
    result = dict(schema_version='1.1.0', pr_number=4242, timestamp='__RITE_TS_PLACEHOLDER_7f3a9b2c__',
                  commit_sha=context['commit_sha'], review_context=context, overall_assessment='mergeable',
                  reviewers=frozen['selected_reviewers'], findings=[], non_blocking_findings=[], guardrail_audit_log=[])
    content.write_text(json.dumps(result))
    run(['bash', str(plugin / 'scripts/review-measured-gate.sh'), '--input', str(content), '--reject-preset-verification'])
    assert execute(finish_block, False).returncode != 0, 'partial wave accepted'
    assert state()['review_cycle']['status'] == 'collecting'
    assert flow('set', '--phase', 'ready', '--next', 'ready', success=False).returncode != 0

    (work / 'rite-config.yml').write_text('safety:\n  max_review_cycles: 1\n')
    resumed = execute(iterate_block)
    assert 'REVIEW_RESUME=1' in resumed.stdout and 'ITERATE_CB=fire' not in resumed.stdout
    assert state()['cycle_count'] == 1, 'iterate resumed by starting another cycle'

    data['reviewers'] = records
    manifest.write_text(json.dumps(data))
    execute(finish_block)
    finished = state()
    assert finished['review_cycle']['status'] == 'completed', 'finish caller omitted'
    assert Path(finished['review_cycle']['result_path']).is_file()
    assert not finished.get('handoff'), 'finish must not publish success before final gates'
    paths_before = list((work / '.rite/review-results').glob('*.json'))
    replay = execute(recover_block)
    assert 'JSON_SAVED=true' in replay.stderr and 'REVIEW_SAVE_DONE=1' in replay.stderr
    assert list((work / '.rite/review-results').glob('*.json')) == paths_before, 'recover duplicated saved result'
    assert state()['cycle_count'] == 1

    # Removing the real finish command must be observable by the caller's postcondition.
    path = Path(flow('path').stdout.strip())
    collecting = finished.copy()
    collecting['review_cycle'] = {**finished['review_cycle'], 'status': 'collecting'}
    path.write_text(json.dumps(collecting))
    omitted = re.sub(r'bash \{plugin_root\}/hooks/flow-state\.sh review-finish \\\n.*? \|\| \{', ': || {', finish_block, flags=re.S)
    assert omitted != finish_block
    execute(omitted)
    assert state()['review_cycle']['status'] == 'collecting'
    assert flow('set', '--phase', 'ready', '--next', 'ready', success=False).returncode != 0
    execute(recover_block)
    assert state()['review_cycle']['status'] == 'completed', 'recover finish caller omitted'
    flow('set', '--phase', 'ready', '--next', 'ready')

    # Advisory fixes still enter fix, but only review-start can begin the next review.
    flow('set', '--phase', 'fix', '--next', 'advisory fix', '--handoff', '/rite:pr-review 4242')
    assert flow('set', '--phase', 'review', '--next', 'skip review', success=False).returncode != 0
    saved_path = Path(state()['review_cycle']['result_path'])
    saved_bytes = saved_path.read_bytes()
    saved_path.unlink()
    lost = execute(iterate_block)
    assert 'ITERATE_LOST_GATE=fire' in lost.stdout and 'HANDOFF_CLEAR=ok' in lost.stdout
    assert state()['phase'] == 'fix' and state()['cycle_count'] == 1
    saved_path.write_bytes(saved_bytes)
    fired = execute(iterate_block)
    assert 'ITERATE_CB=fire' in fired.stdout and 'HANDOFF_CLEAR=ok' in fired.stdout
    assert state()['phase'] == 'fix'
    execute(breaker_block)
    assert state()['phase'] == 'fix' and state().get('cycle_count', 0) == 0
    run(['git', '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
         'commit', '-q', '--allow-empty', '-m', 'fix fixture'])
    execute(start_block)
    assert state()['phase'] == 'review' and state()['cycle_count'] == 1
    assert state()['review_cycle']['review_context']['run_id'] != context['run_id']
    assert state()['review_cycle']['review_context']['commit_sha'] != context['commit_sha']
    assert flow('set', '--phase', 'fix', '--next', 'skip finish', success=False).returncode != 0

    # Issue-backed callers must collect diagnostics before advancing.
    state_path.unlink()
    flow('set', '--phase', 'pr', '--pr', 4242, '--issue', 4241,
         '--branch', 'caller-test', '--next', 'review')
    execute(start_block)
    context = state()['review_cycle']['review_context']
    assert state()['review_run']['run_id'] == context['run_id']
    replacements.update(clock_kind='work', clock_close_mode='normal')
    open_clock = block(diagnostic, '# review-clock-open')
    close_clock = block(diagnostic, '# review-clock-close')
    execute(open_clock)
    assert execute(open_clock, False).returncode != 0, 'open clock overwritten'
    execute(close_clock)
    assert len(state()['review_run']['clock']) == 1

    for record in records:
        record['review_context'] = context
    data.update(review_context=context, reviewers=records)
    manifest.write_text(json.dumps(data))
    result.update(review_context=context, commit_sha=context['commit_sha'],
                  acceptance_criteria={'skipped': 'no_ac_section'})
    result.pop('measured_gate', None)
    content.write_text(json.dumps(result))
    run(['bash', str(plugin / 'scripts/review-measured-gate.sh'), '--input', str(content),
         '--reject-preset-verification'])
    execute(finish_block)
    assert flow('set', '--phase', 'ready', '--next', 'omitted observation',
                success=False).returncode != 0
    issue = work / 'issue.json'
    observed = work / 'observation.json'
    issue.write_text(json.dumps({'number': 4241, 'body': 'Review the change.'}))
    observed.write_text(json.dumps(dict(review_context=context, issue_number=4241,
        issue_body='Review the change.', roots=[],
        acceptance=dict(satisfied=[], evidence='The specification has no acceptance table.'))))
    replacements.update(review_observation_file=str(observed), review_issue_file=str(issue))
    observe_block = block(review, '# review-stagnation-observe')
    execute(observe_block)
    execute(observe_block)
    assert len(state()['review_run']['observations']) == 1, 'observation replay duplicated'
    assert 'ITERATE_STAGNATION=continue' in execute(block(iterate, '# iterate-stagnation-route')).stdout
    successful = state()
    flow('set', '--phase', 'ready', '--next', 'verified')

    # Saving a clock and crashing before removal must submit exactly the same interval.
    replacements['clock_kind'] = 'external_wait'
    execute(open_clock)
    clock_file = work / '.rite/state/review-clock-caller-test.json'
    clock_data = json.loads(clock_file.read_text())
    clock_data['ended_at'] = clock_data['started_at']
    clock_file.write_text(json.dumps(clock_data))
    flow('review-clock', '--input', str(clock_file))
    execute(close_clock)
    assert not clock_file.exists() and len(state()['review_run']['clock']) == 2
    replacements.update(clock_kind='work', clock_close_mode='recover')
    execute(open_clock)
    execute(close_clock)
    assert state()['review_run']['clock'][-1]['kind'] == 'interruption'
    assert flow('set', '--phase', 'ready', '--next', 'reset', '--cycle-count', 0,
                success=False).returncode != 0, 'recover can erase review history'

    # The real terminal callers retain the run and stop the batch at its current item.
    execute(breaker_block)
    stopped = state()
    assert stopped['cycle_count'] == 1 and stopped['review_run']['status'] == 'stopped'
    assert stopped['active'] is False
    assert execute(start_block, False).returncode != 0, 'stopped run restarted'
    replacements.update(current_issue='4241', run_mode='merge', breaker_failed='true')
    resumed = execute(block(batch, '# batch-run-resume-stage'))
    assert 'RUN_RESUME_STAGE=stop; reason=stagnation_stopped' in resumed.stdout
    queue = work / '.rite/state/run-queue-caller-test.json'
    queue.write_text(json.dumps(dict(issues=[4241, 4243], cursor=0, active=True, mode='merge')))
    execute(block(batch, '# batch-run-stop'))
    retained = json.loads(queue.read_text())
    assert retained['cursor'] == 0 and retained['active'] is False
    assert retained['failed'] == [4241] and retained['issues'] == [4241, 4243]

    # Default draft batches close the verified review, then execute the real next-Issue initializer.
    state_path.write_text(json.dumps(successful))
    replacements.update(sweep_origin='[fix:replied-only]')
    retained_close = execute(block(iterate, 'close_phase=$(bash'))
    assert 'ITERATE_RUN_CLOSE=retained' in retained_close.stdout
    assert 'completed_context' not in state()['review_run'], 'reply-only exit promoted to completion'
    replacements.update(sweep_origin='[review:mergeable]')
    closed = execute(block(iterate, 'close_phase=$(bash'))
    assert 'ITERATE_RUN_CLOSE=completed' in closed.stdout
    completed = state()['review_run']
    assert completed['completed_context'] == context and state()['cycle_count'] == 1
    replacements.update(issue_number='4243')
    execute(block((plugin / 'skills/open/SKILL.md').read_text(), '# open-initial-state'))
    assert state()['issue_number'] == 4243 and 'review_run' not in state()
    assert state()['review_run_history'] == [completed] and state().get('cycle_count', 0) == 0
    flow('set', '--phase', 'pr', '--pr', 4244, '--next', 'next review')
    replacements.update(pr_number='4244')
    execute(start_block)
    assert state()['review_run']['run_id'] != context['run_id'] and state()['cycle_count'] == 1
    assert state()['review_run_history'] == [completed]

    # Existing output gates precede the deferred success handoff.
    assert '状態更新・result の前に記載順で評価する' in review
    assert '全 gate pass を確認してから 8.0 の該当する状態更新を実行する' in review
    print('PASS: extracted start / finish / iterate / recover callers; partial waves; missing-call rejection; idempotent resume; lost/breaker phase preservation')
PY
