#!/usr/bin/env bash
# Real review receipts, explicit clocks and verified repairs in isolated repositories.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 - "$SCRIPT_DIR/../.." "$SCRIPT_DIR" <<'PYTEST'
import copy
import datetime
import hashlib
import importlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, sys.argv[2])
import _review_stagnation_fixture as stagnation_fixture
from _review_stagnation_fixture import (
    Fixture, WORK_MEMORY, archived_run, check, diverge, dump, parked_of, plugin,
    publish_stale, retry, iterate,
)
sys.path.insert(0, str(plugin / 'hooks/scripts/lib'))

f = Fixture()
try:
    f.cycle(['input validation'], seconds=1801)
    plan = f.plan(replan=True)
    plan['verifications'].append(dict(id='related', kind='related', command='test -f source.txt',
                                      inputs=['source.txt'], environment=[]))
    plan['groups'][0]['verification_ids'] = ['full', 'related']
    plan['verifications'][0]['command'] = "bash -c 'exit 2'"
    dump(f.plan_path, plan)
    def amend(ok=True, reason='assert the expected failure'):
        return f.flow('review-replan', '--amend', '--reason', reason,
                      '--plan', f.plan_path, '--issue', f.issue_path, ok=ok)
    f.reject(lambda: amend(ok=False), 'amend without a registered replan is rejected')
    f.replan()
    f.scope()
    f.reject(lambda: f.scope('verify', ok=False), 'bad expected-failure command fails')
    before = f.state()
    check(len(before['review_run']['replans']) == 1, 'one diagnostic replan before amendment')
    plan['verifications'][0]['command'] = "bash -c 'exit 2'; actual=$?; test \"$actual\" -eq 2"
    dump(f.plan_path, plan)
    f.reject(lambda: f.replan(ok=False), 'ordinary replan rejects changed pinned command')
    f.reject(lambda: f.flow('review-replan', '--reason', 'assert the expected failure',
                            '--plan', f.plan_path, '--issue', f.issue_path, ok=False),
             '--reason without --amend is rejected')
    f.reject(lambda: f.flow('review-replan', '--amend', '--reason', '   ',
                            '--plan', f.plan_path, '--issue', f.issue_path, ok=False),
             'blank --reason is rejected')
    unchanged = copy.deepcopy(plan)
    dump(f.plan_path, f.state()['review_run']['replans'][0]['plan'])
    f.reject(lambda: amend(ok=False), 'amendment requires a command correction')
    dump(f.plan_path, plan)
    state_before = f.state_path.read_bytes()
    stopped = f.state()
    stopped['review_run'].update(status='stopped', stop_reason='circuit-breaker:divergence')
    dump(f.state_path, stopped)
    f.reject(lambda: amend(ok=False), 'stopped run cannot amend')
    f.state_path.write_bytes(state_before)
    verification_path = f.private / 'state' / ('fix-verification-' + f.session + '.json')
    checked_path = f.private / 'state' / ('fix-plan-' + f.session + '.json')
    evidence_before = verification_path.read_bytes()
    checked_before = checked_path.read_bytes()
    fake_bin = f.private / 'amend-bin'
    fake_bin.mkdir()
    fake_mv = fake_bin / 'mv'
    fake_mv.write_text('#!/bin/sh\nexit 7\n')
    fake_mv.chmod(0o755)
    old_path = f.env['PATH']
    f.env['PATH'] = str(fake_bin) + ':' + old_path
    f.reject(lambda: amend(ok=False), 'failed amendment persistence retains state')
    f.env['PATH'] = old_path
    check(verification_path.read_bytes() == evidence_before, 'failed persistence retains verification bytes')
    check(checked_path.read_bytes() == checked_before, 'failed persistence retains checked-plan bytes')
    broken = verification_path.read_bytes()
    verification_path.write_text('not-json')
    f.reject(lambda: amend(ok=False), 'malformed verification evidence fails loudly')
    check(verification_path.read_text() == 'not-json', 'malformed verification file is left in place')
    verification_path.write_bytes(broken)
    # Workflow record markers are explicitly not specification changes.
    f.with_issue(f.issue['body'] + '\n\n<!-- rite:nbr:comment-id:101 -->')
    plan['issue_body'] = f.issue['body']
    dump(f.plan_path, plan)
    first_reason = 'assert the expected failure'
    amend()
    saved = f.state()['review_run']['replans'][0]
    check(len(f.state()['review_run']['replans']) == 1, 'amendment does not add a diagnostic replan')
    check(saved['amendments'][0]['evidence']['fix-verification']['results']['full']['exit_code'] == 2,
          'amendment archives failed verification')
    check(saved['amendments'][0]['evidence']['fix-plan'] is not None, 'amendment archives checked-plan')
    check(f.state()['cycle_count'] == before['cycle_count'] and
          f.state()['review_run']['observations'] == before['review_run']['observations'],
          'amendment preserves cycle and observations')
    check(verification_path.read_bytes() == evidence_before and checked_path.read_bytes() == checked_before,
          'successful amendment does not rewrite external evidence files')
    replay = f.state_path.read_bytes()
    amend()
    check(f.state_path.read_bytes() == replay, 'exact amendment replay is byte-identical')
    f.reject(lambda: f.scope('verify', ok=False), 'amended plan requires fresh check')
    f.scope()
    related_verify = f.scope('verify')
    check('FIX_VERIFICATION=executed; id=related' in related_verify.stdout, 'related command executes on first success')
    check('pending_fix' in f.state()['review_run'], 'full corrected verification authorizes fix')
    for bad in ('scope', 'spec'):
        altered = copy.deepcopy(plan)
        if bad == 'scope':
            altered['constraints']['targets'].append('other.txt')
        else:
            altered['issue_body'] += '\n## Goal\nDifferent goal\n'
        dump(f.plan_path, altered)
        f.reject(lambda: amend(ok=False), 'amend rejects ' + bad + ' changes')
    first_plan = copy.deepcopy(plan)
    plan['verifications'][0]['command'] = 'test -s source.txt'
    dump(f.plan_path, plan)
    amend(reason='check source content too')
    check('pending_fix' not in f.state()['review_run'], 'subsequent amendment invalidates pending fix')
    audit = f.state()['review_run']['replans'][0]['amendments']
    check(len(f.state()['review_run']['replans']) == 1 and len(audit) == 2,
          'two corrections stay on one replan record')
    check(audit[1]['pending_fix'] is not None,
          'successive correction preserves old pending authorization as evidence only')
    check(audit[0]['evidence']['fix-verification']['results']['full']['exit_code'] == 2,
          'first amendment keeps archived exit 2')
    check(audit[1]['old_plan_hash'] == audit[0]['new_plan_hash'],
          'second amendment old hash is the first new hash')
    dump(f.plan_path, first_plan)
    f.reject(lambda: amend(ok=False, reason=first_reason),
             'superseded amendment plan and reason cannot replay')
    f.reject(lambda: f.scope('verify', ok=False), 'second correction needs fresh check')
    # The checked-plan file still approves the first correction: hash alone is insufficient.
    plan['verifications'][0]['command'] = "bash -c 'exit 2'; actual=$?; test \"$actual\" -eq 2"
    dump(f.plan_path, plan)
    amend(reason='restore the expected-failure assertion')
    f.reject(lambda: f.scope('verify', ok=False), 'returning to an old approved hash still needs fresh check')
    related_command = 'test -f source.txt && test -s source.txt'
    plan['verifications'][1]['command'] = related_command
    dump(f.plan_path, plan)
    amend(reason='also assert related file is non-empty')
    leftover = verification_path.read_bytes()
    f.scope()
    related_again = f.scope('verify')
    check('FIX_VERIFICATION=executed; id=related' in related_again.stdout,
          'changed related command re-executes despite leftover verification file')
    check(leftover != verification_path.read_bytes(),
          'changed related command rewrites leftover verification results')
    f.scope()
    (f.root / 'source.txt').write_text('corrected source\n')
    f.scope('verify')
    f.commit()
    f.start()
    check(f.state()['cycle_count'] == before['cycle_count'] + 1, 'corrected plan advances normal next review')
    f.reject(lambda: amend(ok=False), 'old amendment cannot replay into next context')
finally:
    f.temp.cleanup()

# A completed standalone cycle must not overwrite the run being restored.
for original_count, pending in ((1, False), (2, False), (2, True)):
    f = Fixture()
    try:
        f.cycle()
        if original_count == 2:
            f.fix()
            f.cycle(roots=('input defect', 'second defect'))
        f.flow('set', '--phase', 'review', '--next', 'stop', '--active', 'false',
               '--stop-reason', 'circuit-breaker:max-cycles')
        stopped = f.state()
        f.flow('set', '--phase', 'pr', '--next', 'review', '--issue', 0, '--pr', 80, '--active', 'true')
        f.flow('review-start', '--selection', f.selection)
        check('review_run' not in f.state(), 'standalone review has no diagnostic run')
        if pending:
            f.reject(lambda: f.flow('set', '--phase', 'pr', '--next', 'review', '--issue', 42,
                                    '--pr', 71, '--cycle-count', 0, ok=False),
                     'restore cannot discard a collecting standalone review')
        else:
            f.finish()
            f.flow('set', '--phase', 'pr', '--next', 'review', '--issue', 42, '--pr', 71, '--cycle-count', 0)
            for key in ('review_run', 'review_cycle', 'cycle_count', 'stop_reason', 'active'):
                check(f.state()[key] == stopped[key], 'standalone return preserves restored ' + key)
            f.flow('set', '--phase', 'pr', '--next', 'still stopped', '--active', 'false')
            f.reject(lambda: f.start(ok=False), 'standalone return preserves the review stop')
    finally:
        f.close()

# A defer settles its own context, not later evidence-free cycles of the run.
f = Fixture()
try:
    f.cycle(roots=['input defect'])
    f.flow('review-defer')
    deferred = f.state()['review_run']['deferred_context']
    f.fix()
    f.start()
    f.flow('review-abandon', '--reason', 'later cycle needs another HEAD')
    retained = f.state()
    check(retained['review_run']['deferred_context'] == deferred
          and retained['cycle_count'] > deferred['cycle_count'],
          'active retained fixture has an older actual defer marker')
    f.flow('set', '--phase', 'init', '--next', 'branch', '--issue', 43, '--pr', 0)
    parked = f.state()
    f.flow('set', '--phase', 'pr', '--next', 'review', '--issue', 42, '--pr', 71)
    check(f.state().get('review_run') == retained['review_run']
          and f.state()['cycle_count'] == retained['cycle_count'],
          'historical defer cannot erase a later active retained run')
    f.flow('set', '--phase', 'pr', '--next', 'resume')
    f.start()
    check(f.state()['review_cycle']['review_context']['run_id'] == retained['review_run']['run_id']
          and f.state()['review_cycle']['review_context']['cycle_count'] == retained['cycle_count'],
          'historical defer roundtrip restarts the same run and counter')
    f.clock(60)
    # Missing parked data must not make an old defer look like a current exit.
    legacy = copy.deepcopy(parked)
    legacy['review_run_history'][-1].pop('parked')
    dump(f.state_path, legacy)
    f.reject(lambda: f.flow('set', '--phase', 'pr', '--next', 'review', '--issue', 42, '--pr', 71, ok=False),
             'legacy active archive with defer cannot silently start a fresh run')
finally:
    f.close()

f = Fixture()
try:
    f.start()
    f.finish()
    f.plan()
    f.reject(lambda: f.scope(ok=False), 'scope cannot omit observation')
    f.reject(lambda: f.start(ok=False), 'next review cannot omit observation')
    f.reject(lambda: f.observe(ok=False), 'observation cannot omit clock')
    f.clock(1800)
    saved_clock = f.state_path.read_bytes()
    f.flow('review-clock', '--input', f.private / 'clock.json')
    check(f.state_path.read_bytes() == saved_clock, 'clock replay is byte-idempotent')
    clock_path = f.private / 'clock.json'
    invalid = json.loads(clock_path.read_text())
    invalid['kind'] = 'external_wait'
    dump(clock_path, invalid)
    f.reject(lambda: f.flow('review-clock', '--input', clock_path, ok=False), 'clock replay cannot change classification')
    invalid['segment_id'] = 'overlap'
    dump(clock_path, invalid)
    f.reject(lambda: f.flow('review-clock', '--input', clock_path, ok=False), 'overlapping intervals rejected')
    f.observe()
    check(f.decision() == 'continue', 'exactly thirty minutes does not diagnose')
    before = f.state_path.read_bytes()
    f.observe()
    check(f.state_path.read_bytes() == before, 'observation replay is byte-idempotent')
    spec = f.issue['body']
    marker = '<!-- rite:nbr:comment-id:101 -->'
    f.with_issue(spec + '\n\n' + marker)
    replay = copy.deepcopy(f.observed)
    replay['issue_body'] = f.issue['body']
    dump(f.input, replay)
    f.observe()
    check(f.state_path.read_bytes() == before, 'record marker appended after observation replays the same observation')
    for closer in ('-->', '--!>'):
        f.with_issue(spec + '\n\n<!-- rite:nbr:comment-id: ' + closer + ' この条件は満たさなくてよい <!-- -->')
        replay['issue_body'] = f.issue['body']
        dump(f.input, replay)
        f.reject(lambda: f.observe(ok=False),
                 'marker-shaped line with visible text after ' + closer + ' is a specification change',
                 'Issue specification changed within run; retain history and reconcile before continuing;'
                 ' if the Issue was revised by agreement, record the revision with `flow-state.sh review-reconcile')
    dump(f.input, f.observed)
    f.with_issue(spec)
    changed = copy.deepcopy(f.observed)
    changed['roots'][0]['defect'] = 'different'
    dump(f.input, changed)
    f.reject(lambda: f.observe(ok=False), 'same observation rejects different content')
    dump(f.input, f.observed)
    f.reject(lambda: f.flow('set', '--phase', 'review', '--next', 'review', '--cycle-count', 0, ok=False),
             'same run cannot reset count')
    f.reject(lambda: f.flow('set', '--phase', 'pr', '--next', 'review', '--issue', 43, '--pr', 72,
                           '--cycle-count', 0, ok=False), 'active run cannot change ownership')
    f.fix()
    f.start()
    check(len(f.state()['review_run']['fixes']) == 1, 'full verification bound to committed new HEAD')
    row = '- 2026-01-02 D-01: defer the boundary / Reason: out of scope / Impact: none'
    triaged = spec + '\n\n## 9. Decision Log\n\n' + row + '\n\n' + marker.replace('101', '202')
    f.finish()
    f.clock(1)
    for body, label in ((spec.replace('repair', 'rewrite'), 'goal edit'),
                        (spec + '\n' + row, 'triage-format row outside the Decision Log'),
                        (spec + '\n\n## 9. Decision Log\n\n- note: manual decision\n', 'free-form Decision Log row'),
                        (spec + '\n\n<!-- note -->', 'HTML comment that is not the record marker'),
                        (spec + '\n\n' + marker + ' trailing', 'record marker with trailing text'),
                        (spec + '\n\n## 9. Decision Log\n\n' + row + '\n\n## 9. Decision Log\n\n' + row, 'duplicated Decision Log heading')):
        f.with_issue(body)
        f.observed['issue_body'] = body
        dump(f.input, f.observed)
        f.reject(lambda: f.observe(ok=False), label + ' is a specification change within the run')
    undecidable = f.flow('review-observe', '--input', f.input, '--issue', f.issue_path, ok=False)
    check('boundary undecidable' in undecidable.stderr, 'duplicated heading is reported as an undecidable boundary')
    f.with_issue(spec.replace('repair', 'rewrite'))
    f.observed['issue_body'] = spec
    dump(f.input, f.observed)
    f.reject(lambda: f.observe(ok=False), 'observation copied from an older Issue snapshot is rejected')
    f.with_issue(triaged)
    f.observed['issue_body'] = triaged
    dump(f.input, f.observed)
    f.observe()
    check(f.decision() == 'replan', 'thirty minutes plus one second requests diagnosis')
    observations = f.state()['review_run']['observations']
    check(len(observations) == 2 and observations[1]['input']['issue_body'] == triaged
          and observations[0]['input']['issue_body'] == spec,
          'created Decision Log row and record marker pass the specification check and keep the raw body')
    # The helpers resolve plugin-level scripts next to hooks, so the mutant keeps that layout.
    mutant = f.private / 'mutant-plugin/hooks'
    shutil.copytree(plugin / 'hooks', mutant)
    (mutant.parent / 'scripts').symlink_to(plugin / 'scripts')
    helper = mutant / 'scripts/lib/review-cycle.py'
    helper.write_text(helper.read_text().replace('def normalize_issue_body(body):\n', 'def normalize_issue_body(body):\n    return body\n', 1))
    replay = copy.deepcopy(f.observed)
    replay['issue_body'] = triaged.replace('202', '303')
    dump(f.input, replay)
    f.with_issue(replay['issue_body'])
    mutation = f.run(['bash', str(mutant / 'flow-state.sh'), 'review-observe', '--input', str(f.input), '--issue', str(f.issue_path)], ok=False)
    check(mutation.returncode != 0 and 'specification' in mutation.stderr, 'identity normalization mutation fails the marker replacement replay')
    f.observe()
    check(len(f.state()['review_run']['observations']) == 2, 'replaced record marker replays the same observation')
    f.plan()
    f.reject(lambda: f.scope(ok=False), 'required replan cannot be skipped by scope')
    f.reject(lambda: f.start(ok=False), 'required replan cannot be skipped by next review')
    edited = replay['issue_body'].replace('repair', 'rewrite')
    f.with_issue(edited)
    f.plan(replan=True)
    f.reject(lambda: f.replan(ok=False), 'goal edit within the run is rejected by replan')
    f.reject(lambda: f.scope(ok=False), 'goal edit within the run is rejected by the scope check')
    f.with_issue(replay['issue_body'] + '\n' + row.replace('D-01', 'D-02'))
    f.plan(replan=True)
    f.replan()
    f.with_issue(edited)
    f.reject(lambda: f.replan(ok=False), 'goal edit is rejected when the saved replan is replayed')
    f.with_issue(replay['issue_body'])
    before = f.state_path.read_bytes()
    f.replan()
    check(f.state_path.read_bytes() == before and len(f.state()['review_run']['replans']) == 1,
          'replan replay does not consume another allowance')
    f.scope()
    check(f.decision() == 'continue', 'validated alternative returns to fix')
finally:
    f.close()

# T-22: iterate's cycle gate lets a granted retry reach its review. The divergence
# verdict is held only in the cycle the grant was issued in; the cycle cap, the
# lost-result gate, a stopped run and a spent grant are not held.
def gate(fixture):
    return fixture.run(['bash', str(plugin / 'scripts/iterate-step.sh'), 'cycle-gate',
                        '--pr', '71', '--issue', '42', '--branch', 'fix/issue-42']).stdout


def marker(output, key):
    lines = [line for line in output.splitlines() if line.startswith('[CONTEXT] ' + key + '=')]
    check(len(lines) == 1, key + ' is emitted once:\n' + output)
    return lines[0]


f = Fixture()
try:
    # The gate reads the trend from saved results in file-name order. Results saved in the
    # same second get random collision suffixes, so keep each cycle in its own second.
    for roots in (['input defect'], ('input defect', 'second defect')):
        f.cycle(roots=roots)
        f.fix()
        time.sleep(1.1)
    f.cycle(roots=('input defect', 'second defect', 'third defect'), seconds=1801)
    check(f.state()['stop_reason'] == 'circuit-breaker:divergence', 'T-22: fixture reached divergence stop')
    f.plan()
    retry(f)
    f.fix()
    granted = f.state_path.read_bytes()
    output = gate(f)
    held = marker(output, 'ITERATE_CB')
    check(held.startswith('[CONTEXT] ITERATE_CB=ok;') and 'RETRY_HOLD=1' in held
          and 'TREND=1,2,3;' in held and 'TREND_VERDICT=fire;' in held,
          'T-22: a granted retry holds the divergence verdict:\n' + output)
    check(marker(output, 'ITERATE_LOST_GATE').startswith('[CONTEXT] ITERATE_LOST_GATE=ok;')
          and 'ITERATE_RESUME_HEAD=changed' in output and 'REVIEW_RESUME=1' not in output,
          'T-22: the hold comes from the divergence branch, not the resume or lost gate:\n' + output)
    check(f.state_path.read_bytes() == granted, 'T-22: the held gate writes no state')

    def held_not(label, expected, edit=None, receipt=None):
        results = sorted((f.root / '.rite/review-results').glob('71-*.json'))
        saved = {path: path.read_bytes() for path in results}
        if edit:
            state = f.state()
            edit(state)
            dump(f.state_path, state)
        if receipt:
            receipt(results)
        output = gate(f)
        check(expected in output and 'RETRY_HOLD=1' not in output, label + ':\n' + output)
        f.state_path.write_bytes(granted)
        for path, content in saved.items():
            path.write_bytes(content)
        return output

    held_not('T-22: the cycle cap fires during a retry', 'ITERATE_CB=fire; cycle=3; max=3; CB_REASON=max-cycles',
             receipt=lambda _: (f.root / 'rite-config.yml').write_text('safety:\n  max_review_cycles: 3\n'))
    (f.root / 'rite-config.yml').unlink()
    held_not('T-22: a run stopped with an undecided grant is not held', 'CB_REASON=divergence',
             edit=lambda state: state['review_run'].update(status='stopped'))
    held_not('T-22: the hold ends once the grant cycle has moved on', 'CB_REASON=divergence',
             edit=lambda state: state['review_run']['retry']['stop_context'].update(cycle_count=2))
    # A cycle past the three saved results leaves one lost while the divergence verdict and
    # the pending grant still stand, so without the lost gate going first this cycle is held.
    lost = held_not('T-22: a lost result is repaired before the hold', 'ITERATE_LOST_GATE=fire',
                    edit=lambda state: (state.__setitem__('cycle_count', 4),
                                        state['review_run']['retry']['stop_context'].update(cycle_count=4)))
    lost_gate = marker(lost, 'ITERATE_LOST_GATE')
    check(lost_gate.startswith('[CONTEXT] ITERATE_LOST_GATE=fire;')
          and all(field in lost_gate for field in ('lost=1;', 'cycle=4;', 'max=15;', 'TREND=1,2,3;', 'TREND_VERDICT=fire;')),
          'T-22: the lost case keeps the divergence verdict the hold applies to:\n' + lost)
    lost_cb = marker(lost, 'ITERATE_CB')
    check(lost_cb.startswith('[CONTEXT] ITERATE_CB=ok;') and 'INC=held' in lost_cb,
          'T-22: the lost gate holds the counter instead of the verdict:\n' + lost)
    held_not('T-22: a converging trend needs no hold', 'ITERATE_CB=ok',
             receipt=lambda results: results[-1].write_text(json.dumps(
                 dict(json.loads(results[-1].read_text()), findings=[]))))

    f.cycle(roots=('input defect', 'second defect', 'third defect', 'fourth defect'))
    check(f.state()['review_run']['retry']['outcome'] == 'unresolved', 'T-22: the retry review left blocking findings')
    (f.root / 'source.txt').write_text('another repair\n')
    f.commit()
    output = gate(f)
    check('ITERATE_CB=fire;' in output and 'CB_REASON=divergence' in output and 'RETRY_HOLD=1' not in output,
          'T-22: a spent grant lets divergence fire again:\n' + output)
finally:
    f.close()


# T-26: a retry that cleared every blocking finding moved the run past the point
# it stopped at. Neither the cycle gate nor the observation fires on that point
# again; only a divergence after the retry does.
def diverged_and_retried(fixture):
    for roots in (['input defect'], ('input defect', 'second defect')):
        fixture.cycle(roots=roots)
        fixture.fix()
        time.sleep(1.1)
    fixture.cycle(roots=('input defect', 'second defect', 'third defect'), seconds=1801)
    check(fixture.state()['stop_reason'] == 'circuit-breaker:divergence', 'T-26: fixture reached divergence stop')
    fixture.plan()
    retry(fixture)
    fixture.fix()
    time.sleep(1.1)


def advanced_gate(fixture):
    (fixture.root / 'source.txt').write_text('after cycle ' + str(fixture.state()['cycle_count']) + '\n')
    fixture.commit()
    return gate(fixture)


def passes_gate(output, trend, label):
    cb = marker(output, 'ITERATE_CB')
    check(cb.startswith('[CONTEXT] ITERATE_CB=ok;') and 'TREND=' + trend + ';' in cb
          and 'TREND_VERDICT=ok;' in cb and 'RETRY_HOLD=0' in cb
          and 'ITERATE_RESUME_HEAD=changed' in output and 'REVIEW_RESUME=1' not in output
          and 'CB_REASON=' not in output, label + ':\n' + output)


def recommendation_fix(fixture):
    plan = fixture.plan()
    plan['groups'][0]['finding_ids'] = ['R-01']
    dump(fixture.plan_path, plan)
    fixture.scope()
    (fixture.root / 'source.txt').write_text('recommendation applied\n')
    fixture.scope('verify')
    fixture.commit()


f = Fixture()
try:
    diverged_and_retried(f)
    # The retry review is mergeable and registers a recommendation, whose fix
    # needs the next review.
    f.start()
    f.finish(roots=[], recommendations=[dict(id='R-01', reviewer='code-quality-reviewer', file='source.txt',
                                             line=1, description='comment contradicts the code')])
    f.clock(1)
    f.observe()
    check(f.state()['review_run']['retry']['outcome'] == 'resolved', 'T-26: the retry review cleared every finding')
    recommendation_fix(f)
    passes_gate(gate(f), '1,2,3,0', 'T-26: the gate does not fire on the point the retry moved past')

    time.sleep(1.1)
    f.cycle(roots=('input defect', 'second defect'))
    check(f.state()['review_run']['status'] == 'active',
          'T-26: blocking findings after the retry do not stop the run on the old point')
    f.fix()
    passes_gate(gate(f), '1,2,3,0,2', 'T-26: a rise that has not diverged yet passes the gate')

    time.sleep(1.1)
    f.cycle(roots=('input defect', 'second defect', 'third defect'))
    check(f.state()['review_run']['status'] == 'stopped'
          and f.state()['stop_reason'] == 'circuit-breaker:divergence',
          'T-26: a divergence after the retry stops the run')
    output = advanced_gate(f)
    cb = marker(output, 'ITERATE_CB')
    check(cb.startswith('[CONTEXT] ITERATE_CB=fire;') and 'CB_REASON=divergence' in cb
          and 'TREND=1,2,3,0,2,3;' in cb, 'T-26: a divergence after the retry fires the gate:\n' + output)
finally:
    f.close()

# The previous result is at the pin boundary and lacks the live run_id.
# The pin marker reports the configured boundary; it does not prove pin filtering.
f = Fixture()
try:
    (f.root / '.rite/review-results').mkdir(parents=True, exist_ok=True)
    dump(f.root / '.rite/review-results/71-19990101000000.json',
         dict(schema_version='1.1.0', pr_number=71, findings=[]))
    (f.root / '.rite/state').mkdir(parents=True, exist_ok=True)
    (f.root / '.rite/state/review-run-since-71.txt').write_text('71-19990101000000.json\n')
    diverged_and_retried(f)
    f.start()
    f.finish(roots=[], recommendations=[dict(id='R-01', reviewer='code-quality-reviewer', file='source.txt',
                                             line=1, description='comment contradicts the code')])
    f.clock(1)
    f.observe()
    recommendation_fix(f)
    output = gate(f)
    passes_gate(output, '1,2,3,0', 'T-26: the previous result is excluded from the trend after the retry')
    check('RUN_SINCE_USED=pin' in marker(output, 'ITERATE_CB'), 'T-26: the gate reports the configured run start pin:\n' + output)
finally:
    f.close()

# An unresolved retry keeps the old point. 1,2,3,1 fires only at cycle 3, so the
# gate would pass if the stop cycle were handed to the helper here.
f = Fixture()
try:
    diverged_and_retried(f)
    f.cycle(roots=['input defect'])
    check(f.state()['review_run']['retry']['outcome'] == 'unresolved', 'T-26: the retry review left a finding')
    output = advanced_gate(f)
    cb = marker(output, 'ITERATE_CB')
    check(cb.startswith('[CONTEXT] ITERATE_CB=fire;') and 'CB_REASON=divergence' in cb
          and 'TREND=1,2,3,1;' in cb, 'T-26: an unresolved retry keeps the old divergence point:\n' + output)
finally:
    f.close()

# A resolved grant without its stop cycle cannot bound the check; the gate stops.
f = Fixture()
try:
    diverged_and_retried(f)
    f.cycle(roots=())
    state = f.state()
    del state['review_run']['retry']['stop_context']['cycle_count']
    dump(f.state_path, state)
    (f.root / 'source.txt').write_text('after the retry\n')
    f.commit()
    result = f.run(['bash', str(plugin / 'scripts/iterate-step.sh'), 'cycle-gate',
                    '--pr', '71', '--issue', '42', '--branch', 'fix/issue-42'], ok=False)
    check(result.returncode != 0 and 'ITERATE_CB=' not in result.stdout
          and 'review_run.retry.stop_context.cycle_count' in result.stderr,
          'T-26: a resolved grant without its stop cycle stops the gate:\n' + result.stdout + result.stderr)
finally:
    f.close()

back = iterate.split('「戻る」の行（`divergence` のみ）:', 1)[1].split('```', 2)[1]
# The way back must name the only path the retry review accepts: the fix-scope check
# before the repair and verify before the commit, as f.fix() does above.
check(back.index('review-retry') < back.index('review-fix-scope-check.sh check')
      < back.index('review-fix-scope-check.sh verify') < back.index('/rite:iterate {pr_number}'),
      'T-22: the way back names the checked and verified repair before re-running iterate')
check('再試行権が未決着の間は' in (plugin / 'references/review-stagnation.md').read_text(),
      'T-22: the retry contract states the held divergence verdict')


def approval_record(fixture, reason='user asked for a new run'):
    return dict(
        kind='explicit-fresh-entry',
        run_id=fixture.state()['review_run']['run_id'],
        review_context=fixture.context(),
        issue_number=42, pr_number=71,
        reason=reason, requested_at='2026-01-02T00:00:00Z')


def restart(fixture, record=None, run_id=None, ok=True):
    record = record or approval_record(fixture)
    path = fixture.private / 'approval.json'
    dump(path, record)
    run_id = run_id or record['run_id']
    return fixture.flow('review-restart', '--selection', fixture.selection,
                        '--expected-run-id', run_id, '--approval', path, ok=ok)


# Explicit authorized fresh-entry: a new run, not retry, not a silent iterate reset.
f = Fixture()
try:
    diverge(f)
    stopped = f.state()
    f.reject(lambda: f.start(ok=False), 'T-R01: start still refuses a stopped run')
    empty = approval_record(f)
    empty['reason'] = '   '
    f.reject(lambda: restart(f, empty, ok=False), 'T-R01: empty approval reason is refused')
    wrong = approval_record(f)
    f.reject(lambda: restart(f, wrong, run_id='00000000-0000-0000-0000-000000000000', ok=False),
             'T-R01: wrong expected run id is refused')
    check(f.state() == stopped, 'T-R01: refused restart leaves state identical')
finally:
    f.close()

f = Fixture()
try:
    diverge(f)
    old = f.state()['review_run']
    old_context = f.context()
    old_id = old['run_id']
    record = approval_record(f)
    restart(f, record)
    live = f.state()
    parked = live['review_run_history'][-1]
    check(live['review_run']['run_id'] != old_id and live['cycle_count'] == 1
          and live['review_cycle']['status'] == 'collecting'
          and live['review_cycle']['review_context']['cycle_count'] == 1,
          'T-R02: restart freezes a new cycle-1 run')
    check(parked['run_id'] == old_id and parked['status'] == 'stopped'
          and parked['parked']['superseded_by'] == live['review_run']['run_id']
          and parked['parked']['restart']['reason'] == record['reason']
          and parked['parked']['restart']['requested_at'] == record['requested_at']
          and parked['parked']['restart']['old_context'] == old_context,
          'T-R02: archive keeps the stop and the approval body')
    check(live['review_run']['clock'] == [] and live['review_run']['observations'] == []
          and 'pending_fix' not in live['review_run'] and not live.get('stop_reason'),
          'T-R02: new run does not inherit verification credit')
    check(parked['clock'] and parked['observations'] and parked['fixes'] and parked['replans'] is not None,
          'T-R02: parked histories stay on the old run')
    replay = f.state_path.read_bytes()
    restart(f, record, run_id=old_id)
    check(f.state_path.read_bytes() == replay, 'T-R04: same approval does not mint another run')
finally:
    f.close()

f = Fixture()
try:
    diverge(f)
    f.plan()
    retry(f)
    check(f.state()['review_run']['status'] == 'active' and 'retry' in f.state()['review_run'],
          'T-R03: review-retry still reopens the same run')
finally:
    f.close()

f = Fixture()
try:
    (f.root / 'rite-config.yml').write_text('safety:\n  max_review_cycles: 1\n')
    f.run(['git', 'add', 'rite-config.yml'])
    f.run(['git', '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
           'commit', '-q', '-m', 'fixture config'])
    f.cycle(roots=['input defect'], seconds=1801)
    check(f.state()['stop_reason'] == 'circuit-breaker:max-cycles', 'T-R03: fixture reached max-cycles')
    f.plan()
    f.reject(lambda: retry(f, ok=False), 'T-R03: max-cycles still cannot be retried')
    restart(f)
    check(f.state()['cycle_count'] == 1 and f.state()['review_run']['status'] == 'active',
          'T-R03: max-cycles can take the explicit restart')
finally:
    f.close()

f = Fixture()
try:
    diverge(f)
    old_id = f.state()['review_run']['run_id']
    restart(f)
    new_id = f.state()['review_run']['run_id']
    f.flow('review-abandon', '--reason', 'switch after authorized restart')
    f.flow('set', '--phase', 'init', '--next', 'branch', '--issue', 43, '--branch', 'chore/issue-43', '--pr', 0)
    f.flow('set', '--phase', 'pr', '--next', 'review', '--issue', 42, '--pr', 71)
    back = f.state()
    check(back.get('review_run', {}).get('run_id') == new_id
          and back['review_run']['status'] == 'active'
          and back.get('review_run', {}).get('run_id') != old_id,
          'T-R05: round trip restores the new run, not the superseded stop')
    check(any(entry.get('run_id') == old_id and entry.get('parked', {}).get('superseded_by') == new_id
              for entry in back.get('review_run_history', [])),
          'T-R05: superseded stop stays archived')
finally:
    f.close()

f = Fixture()
try:
    f.start()
    f.reject(lambda: restart(f, approval_record(f), f.context()['run_id'], ok=False),
             'T-R08: collecting cycle cannot restart')
finally:
    f.close()

f = Fixture()
try:
    diverge(f)
    clock_dir = f.root / '.rite' / 'state'
    clock_dir.mkdir(parents=True, exist_ok=True)
    (clock_dir / ('review-clock-' + f.session + '.json')).write_text('{}')
    f.reject(lambda: restart(f, ok=False), 'T-R08: open clock refuses restart without inventing times')
finally:
    f.close()

f = Fixture()
try:
    diverge(f)
    (f.root / 'new-impl.sh').write_text('echo new\n')
    f.reject(lambda: restart(f, ok=False), 'T-R10: untracked implementation files block restart')
finally:
    f.close()

f = Fixture()
try:
    diverge(f)
    old_id = f.state()['review_run']['run_id']
    f.flow('set', '--phase', 'init', '--next', 'branch', '--issue', 43, '--branch', 'chore/issue-43', '--pr', 0)
    forged = f.state()
    entry = forged['review_run_history'][-1]
    check(entry['run_id'] == old_id and entry['status'] == 'stopped', 'T-R11: parked entry is the stop')
    entry['parked']['superseded_by'] = 'forged-new-run'
    entry['parked']['restart'] = dict(
        old_run_id='00000000-0000-0000-0000-000000000000',
        old_context={'run_id': 'other'},
        reason='forged', requested_at='2026-01-02T00:00:00Z',
        new_run_id='forged-new-run', head='deadbeef', at='2026-01-02T00:00:00Z')
    dump(f.state_path, forged)
    f.reject(lambda: f.flow('set', '--phase', 'pr', '--next', 'review', '--issue', 42, '--pr', 71, ok=False),
             'T-R11: forged supersession does not skip restoring the stop')
finally:
    f.close()

flow_src = (plugin / 'hooks/flow-state.sh').read_text()
check('if [ "$operation" != finish ]' in flow_src
      and 'RITE_STATE_IF_MATCH="$expected_hash" _atomic_write' in flow_src,
      'T-R09: review mutators other than finish publish with expected-state')

f = Fixture()
try:
    diverge(f)
    f.plan()
    stopped_bytes = f.state_path.read_bytes()
    old_hash = hashlib.sha256(stopped_bytes).hexdigest()
    copy_path = f.private / 'stopped-copy.json'
    copy_path.write_bytes(stopped_bytes)
    retry_out = subprocess.run(
        ['python3', str(plugin / 'hooks/scripts/lib/review-cycle.py'), 'retry',
         '--state', str(copy_path), '--session', f.session,
         '--results-dir', str(f.root / '.rite/review-results'),
         '--plan', str(f.plan_path), '--issue', str(f.issue_path)],
        cwd=f.root, env=f.env, text=True, capture_output=True)
    check(retry_out.returncode == 0, 'T-R09: retry against a stopped snapshot still computes')
    stale_retry = retry_out.stdout
    check(stale_retry.lstrip().startswith('{'), 'T-R09: retry emitted a candidate')
    restart(f)
    new_id = f.state()['review_run']['run_id']
    live_hash = hashlib.sha256(f.state_path.read_bytes()).hexdigest()
    check(live_hash != old_hash, 'T-R09: restart changed the bytes a stale retry hashed')
    before = f.state_path.read_bytes()
    for hide, label in ((False, 'flock'), (True, 'no-flock')):
        published = publish_stale(f, old_hash, stale_retry, hide_flock=hide)
        check(published.returncode != 0 and 'expected-state mismatch' in published.stderr,
              'T-R09: stale retry publish is rejected (' + label + ')\n' + published.stderr)
        check(f.state_path.read_bytes() == before,
              'T-R09: new run remains after stale retry (' + label + ')')
    published = publish_stale(f, old_hash, stopped_bytes, hide_flock=False)
    check(published.returncode != 0 and 'expected-state mismatch' in published.stderr,
          'T-R09: stale set snapshot publish is rejected\n' + published.stderr)
    check(f.state()['review_run']['run_id'] == new_id
          and f.state()['review_run']['status'] == 'active',
          'T-R09: stale publishers do not replace the new run')
finally:
    f.close()

f = Fixture()
try:
    f.cycle(['input defect'])
    check(f.state()['cycle_count'] == 1 and f.state()['review_run']['status'] == 'active',
          'T-R06: cycle 1 completed with counter still 1')
    (f.root / 'source.txt').write_text('post-cycle-1 change\n')
    f.commit()
    results = f.root / '.rite/review-results'
    scope = subprocess.run(
        ['bash', str(plugin / 'scripts/review-cycle-scope.sh'), '--pr', '71',
         '--results-dir', str(results)],
        cwd=f.root, env=f.env, text=True, capture_output=True)
    check(scope.returncode == 0 and 'REVIEW_CYCLE_SCOPE=incremental' in scope.stderr,
          'T-R06: same-run cycle 2 is incremental while live cycle_count is 1\n' + scope.stderr)
    check('new_run_first_cycle' not in scope.stderr,
          'T-R06: cycle_count==1 is not a full-scope gate')
finally:
    f.close()

f = Fixture()
try:
    diverge(f)
    old_id = f.state()['review_run']['run_id']
    restart(f)
    new_id = f.state()['review_run']['run_id']
    results = f.root / '.rite/review-results'
    results.mkdir(parents=True, exist_ok=True)
    head = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=f.root, text=True,
                          capture_output=True, check=True).stdout.strip()
    dump(results / '71-19700101000000.json', dict(
        schema_version='1.1.0', pr_number=71, commit_sha=head,
        review_context=dict(session_id=f.session, run_id=old_id, pr_number=71,
                            cycle_count=3, commit_sha=head),
        findings=[], non_blocking_findings=[], reviewers=['code-quality-reviewer']))
    scope = subprocess.run(
        ['bash', str(plugin / 'scripts/review-cycle-scope.sh'), '--pr', '71',
         '--results-dir', str(results)],
        cwd=f.root, env=f.env, text=True, capture_output=True)
    check(scope.returncode == 0 and 'reason=foreign_run_json' in scope.stderr,
          'T-R06: leftover JSON from the old run is foreign, not previous\n' + scope.stderr)
    check('REVIEW_CYCLE_SCOPE=incremental' not in scope.stderr,
          'T-R06: leftover JSON does not become prev')
    gh = f.root / 'bin'
    gh.mkdir()
    (gh / 'gh').write_text(
        '#!/bin/bash\n'
        'ROOT=' + json.dumps(str(f.root)) + '\n'
        'if grep -q headRefOid <<< "$*"; then\n'
        '  git -C "$ROOT" rev-parse HEAD\n'
        '  exit 0\n'
        'fi\n'
        'exit 1\n')
    os.chmod(gh / 'gh', 0o755)
    ready_env = dict(f.env, PATH=str(gh) + os.pathsep + f.env.get('PATH', ''))
    ready = subprocess.run(
        ['bash', str(plugin / 'hooks/scripts/ready-reviewed-head-gate.sh'),
         '--pr', '71', '--repo', 'B16B1RD/cc-rite-workflow',
         '--plugin-root', str(plugin), '--results-dir', str(results),
         '--state-root', str(f.root)],
        cwd=f.root, env=ready_env, text=True, capture_output=True)
    check(ready.returncode != 0 and 'live_run_receipt_missing' in ready.stderr,
          'T-R07: old same-HEAD receipt does not ready the new live run')
    dump(results / '71-19700101000001.json', dict(
        schema_version='1.1.0', pr_number=71, commit_sha=head,
        review_context=dict(session_id=f.session, run_id=new_id, pr_number=71,
                            cycle_count=1, commit_sha=head),
        findings=[], non_blocking_findings=[], reviewers=['code-quality-reviewer'],
        acceptance_criteria=dict(skipped='no_ac_section')))
    ready_ok = subprocess.run(
        ['bash', str(plugin / 'hooks/scripts/ready-reviewed-head-gate.sh'),
         '--pr', '71', '--repo', 'B16B1RD/cc-rite-workflow',
         '--plugin-root', str(plugin), '--results-dir', str(results),
         '--state-root', str(f.root)],
        cwd=f.root, env=ready_env, text=True, capture_output=True)
    check(ready_ok.returncode == 0 and 'READY_REVIEWED_HEAD=match' in ready_ok.stderr,
          'T-R07: new-run receipt is the only match')
finally:
    f.close()

# An agreed Issue revision continues the same run instead of opening a fresh budget.
HINT = 'review-reconcile'


def revision_record(fixture, reason='user agreed to revise the criterion', requested_at='2026-01-03T00:00:00Z'):
    return dict(kind='specification-change', run_id=fixture.state()['review_run']['run_id'],
                review_context=fixture.context(), issue_number=42, pr_number=71,
                reason=reason, requested_at=requested_at)


def reconcile(fixture, record=None, ok=True):
    path = fixture.private / 'revision.json'
    dump(path, record or revision_record(fixture))
    return fixture.flow('review-reconcile', '--issue', fixture.issue_path, '--approval', path, ok=ok)


def refused_with_hint(fixture, operation, label, message):
    before = fixture.state_path.read_bytes()
    result = operation()
    check(result.returncode != 0 and message in result.stderr and HINT in result.stderr, label)
    check(fixture.state_path.read_bytes() == before, label + ': last state retained')


def plan_for(fixture, body):
    plan = fixture.plan()
    plan['issue_body'] = body
    dump(fixture.plan_path, plan)


hint_source = importlib.import_module('review-cycle')
check(('## ' + hint_source.SPEC_CHANGE_SECTION + '\n') in (plugin / 'references/review-stagnation.md').read_text(),
      'T-SC00: the recovery hint names a section that exists in the reference')

# Revision recorded on an observed cycle, then the reviewed HEAD is re-reviewed.
f = Fixture()
try:
    f.cycle(roots=['input defect'])
    old_spec, context = f.issue['body'], f.context()
    run_id, phase = f.state()['review_run']['run_id'], f.state()['phase']
    revised = old_spec.replace('repair', 'rewrite')
    f.reject(lambda: reconcile(f, ok=False), 'T-SC01: an unchanged Issue has nothing to reconcile', 'nothing to reconcile')
    (f.root / 'source.txt').write_text('in-progress edit\n')
    f.reject(lambda: reconcile(f, ok=False), 'T-SC01: with work in progress the missing revision is reported first',
             'nothing to reconcile')
    (f.root / 'source.txt').write_text('initial\n')
    f.with_issue(revised)
    plan_for(f, revised)
    refused_with_hint(f, lambda: f.scope(ok=False), 'T-SC02: a revised fix plan stops before reconcile',
                      'fix specification differs from diagnosed observation')
    plan_for(f, old_spec)
    refused_with_hint(f, lambda: f.scope(ok=False), 'T-SC02: an old fix plan stops against the latest Issue',
                      'Issue specification changed or mismatched')
    for field, value, reason in (('kind', 'explicit-fresh-entry', 'approval kind'),
                                 ('run_id', 'other-run', 'approval run id'),
                                 ('review_context', dict(context, cycle_count=9), 'approval review_context'),
                                 ('pr_number', 72, 'approval PR'),
                                 ('issue_number', 43, 'approval issue'),
                                 ('reason', '  ', 'approval reason'),
                                 ('requested_at', '  ', 'approval requested_at')):
        bad = revision_record(f)
        bad[field] = value
        f.reject(lambda: reconcile(f, bad, ok=False), 'T-SC03: mismatched approval ' + field + ' is refused', reason)
    record = revision_record(f)
    result = reconcile(f, record)
    printed = json.loads(result.stdout)
    state = f.state()
    recorded = state['review_run']['reconciliations']
    check(printed['reconciliations'] == recorded and len(recorded) == 1
          and recorded[0]['review_context'] == context and recorded[0]['after_cycle'] == context['cycle_count']
          and recorded[0]['issue_body'] == revised and recorded[0]['reason'] == record['reason']
          and recorded[0]['requested_at'] == record['requested_at'],
          'T-SC04: reconcile records the approval, context, boundary and revised body on the run')
    check(phase == 'review' and state['phase'] == 'fix' and state['next_action'] == '/rite:iterate 71'
          and state['review_run']['run_id'] == run_id and state['cycle_count'] == 1,
          'T-SC04: reconcile keeps run and counter, moves phase from review to fix and names the re-review')
    replay = f.state_path.read_bytes()
    reconcile(f, record)
    check(f.state_path.read_bytes() == replay, 'T-SC05: the same approval is a byte-identical no-op')
    output = gate(f)
    check('REVIEW_RESUME=1' not in output and 'ITERATE_RESUME_HEAD' not in output,
          "T-SC04: iterate's cycle gate starts a new cycle instead of resuming the reviewed one:\n" + output)
    for body in (revised, old_spec):
        plan_for(f, body)
        f.reject(lambda: f.scope(ok=False), 'T-SC06: no fix plan passes before the revised re-review',
                 'already recorded')
    fixes = len(f.state()['review_run']['fixes'])
    f.start()
    f.finish(roots=['input defect'])
    f.clock(1)
    f.observe()
    run = f.state()['review_run']
    check(run['run_id'] == run_id and f.state()['cycle_count'] == 2 and len(run['fixes']) == fixes,
          'T-SC07: the re-review stays in the run, advances the counter and counts no fix')
    check([entry['input']['issue_body'] for entry in run['observations']] == [old_spec, revised],
          'T-SC07: the old observation is retained and the new one carries the revised Issue')
    check(run['current_decision']['action'] == 'continue' and run['trend'].get('TREND_DIVERGENCE') == 'insufficient',
          'T-SC07: the revised observation is judged by the unchanged gates')
    f.fix()
    check('pending_fix' in f.state()['review_run'], 'T-SC07: the revised observation admits a checked and verified fix')
    advanced = f.state()
    reconcile(f, record)
    check(f.state() == advanced, 'T-SC05: replaying the approval after the context advanced changes nothing')
finally:
    f.close()

# The other states a revision cannot be recorded in, and an approval reused for another body.
f = Fixture()
try:
    f.start()
    f.reject(lambda: reconcile(f, ok=False), 'T-SC15: a collecting cycle cannot be reconciled',
             'all reviewers must be collected')
    f.finish()
    f.clock()
    f.observe()
    revised = f.issue['body'].replace('repair', 'rewrite')
    f.with_issue(revised)
    f.commit()
    f.reject(lambda: reconcile(f, ok=False), 'T-SC15: a revision after HEAD moved is refused',
             'HEAD differs from review context')
    f.run(['git', 'reset', '-q', '--hard', 'HEAD~1'])
    receipt = Path(f.state()['review_run']['observations'][-1]['result_path'])
    saved = receipt.read_bytes()
    document = json.loads(saved)
    document['findings'][0]['description'] += ' (edited)'
    dump(receipt, document)
    f.reject(lambda: reconcile(f, ok=False), 'T-SC15: a changed review receipt is refused',
             'observed review receipt is missing or changed')
    receipt.write_bytes(saved)
    record = revision_record(f)
    reconcile(f, record)
    f.with_issue(revised.replace('rewrite', 'rework'))
    reconcile(f, record)
    recorded = f.state()['review_run']['reconciliations']
    check(len(recorded) == 2 and recorded[-1]['issue_body'] == f.issue['body'],
          'T-SC15: an approval reused for another body is recorded again, not replayed')
finally:
    f.close()

# A cycle refused for the revision still needs its saved receipt.
f = Fixture()
try:
    f.cycle()
    f.fix()
    f.start()
    f.finish()
    f.with_issue(f.issue['body'].replace('repair', 'rewrite'))
    receipts = sorted(Path(f.temp.name, '.rite/review-results').glob('71-*.json'))
    receipts[-1].unlink()
    f.reject(lambda: reconcile(f, ok=False), 'T-SC15: an unobserved cycle without its saved receipt is refused',
             'saved review receipt missing')
finally:
    f.close()

# Revision that makes the next observation fail, recorded twice.
f = Fixture()
try:
    f.cycle(roots=['input defect'])
    old_spec = f.issue['body']
    first, second = old_spec.replace('repair', 'rewrite'), old_spec.replace('preserve', 'retain')
    f.with_issue(first)
    reconcile(f, revision_record(f))
    f.with_issue(second)
    f.start()
    f.finish(roots=['input defect'])
    f.clock(1)
    refused_with_hint(f, lambda: f.observe(ok=False), 'T-SC08: a second unrecorded revision stops the observation',
                      'Issue specification changed within run')
    stale = copy.deepcopy(f.observed)
    stale['issue_body'] = first
    dump(f.input, stale)
    refused_with_hint(f, lambda: f.observe(ok=False), 'T-SC08: an observation copied before the revision stops',
                      'latest Issue specification differs from observation')
    dump(f.input, f.observed)
    later = revision_record(f, reason='second agreed revision', requested_at='2026-01-04T00:00:00Z')
    reconcile(f, later)
    state = f.state()
    records = state['review_run']['reconciliations']
    check(len(records) == 2 and records[1]['review_context'] == f.context() and records[1]['after_cycle'] == 1
          and records[1]['issue_body'] == second and state['next_action'] == '/rite:recover 42',
          'T-SC09: an unobserved cycle is reconciled with the boundary before it')
    check(state['phase'] == 'review' and 'REVIEW_RESUME=1' in gate(f),
          'T-SC09: the unobserved route keeps phase review so iterate resumes the cycle to save its observation')
    third = second.replace('source.txt', 'the source file')
    f.with_issue(third)
    revised_again = copy.deepcopy(f.observed)
    revised_again['issue_body'] = third
    dump(f.input, revised_again)
    refused = f.observe(ok=False)
    check(refused.returncode != 0 and 'Issue specification changed within run' in refused.stderr
          and HINT in refused.stderr and 'already recorded' not in refused.stderr,
          'T-SC09: a further revision in the same cycle is pointed at reconcile, not at the recorded one')
    f.with_issue(first)
    dump(f.input, stale)
    f.reject(lambda: f.observe(ok=False), 'T-SC09: only the latest revision is the specification',
             'Issue specification changed within run')
    f.with_issue(second)
    dump(f.input, f.observed)
    f.observe()
    check(len(f.state()['review_run']['observations']) == 2, 'T-SC09: the hinted route saves the revised observation')
finally:
    f.close()

# States the revision cannot reopen.
f = Fixture()
try:
    f.cycle(seconds=1801)
    check(f.decision() == 'replan', 'T-SC10: fixture requires a replan')
    f.plan(replan=True)
    f.replan()
    f.with_issue(f.issue['body'].replace('repair', 'rewrite'))
    refused_with_hint(f, lambda: f.replan(ok=False), 'T-SC10: a registered replan stops on the revised Issue',
                      'latest Issue specification differs from replan')
finally:
    f.close()

f = Fixture()
try:
    f.cycle(seconds=1801)
    f.with_issue(f.issue['body'].replace('repair', 'rewrite'))
    reconcile(f)
    run = f.state()['review_run']
    check(run['current_decision']['action'] == 'continue' and run['reconciliations'][0]['replan_reasons'] == ['work-time'],
          'T-SC10: a pending replan is carried by the revision instead of blocking it')
    f.start()
    f.finish()
    f.clock(1)
    f.observe()
    check(f.decision() == 'replan' and f.state()['review_run']['current_decision']['reasons'] == ['work-time'],
          'T-SC10: the first observation under the revised Issue owes the carried replan')
    f.plan(replan=True)
    f.replan()
    check(len(f.state()['review_run']['replans']) == 1, 'T-SC10: the replan passes on the revised Issue')
    f.scope()
    (f.root / 'source.txt').write_text('repaired under the replan\n')
    f.scope('verify')
    f.commit()
    f.cycle()
    check(f.decision() == 'continue' and 'work-time' not in f.state()['review_run']['current_decision']['reasons'],
          'T-SC10: the carried replan is owed only once')
finally:
    f.close()

# A revision found mid-fix, and a run with nothing observed yet.
f = Fixture()
try:
    f.cycle()
    f.with_issue(f.issue['body'].replace('repair', 'rewrite'))
    (f.root / 'source.txt').write_text('edited under the old plan\n')
    f.reject(lambda: reconcile(f, ok=False), 'T-SC12: uncommitted edits stop the revision before review-start',
             'restore edits made under the old plan')
    (f.root / 'source.txt').write_text('initial\n')
    (f.root / 'added-under-old-plan.txt').write_text('new file\n')
    f.reject(lambda: reconcile(f, ok=False), 'T-SC12: a file created under the old plan also stops the revision',
             'restore edits made under the old plan')
    (f.root / 'added-under-old-plan.txt').unlink()
    reconcile(f)
    f.start()
    check(f.state()['cycle_count'] == 2, 'T-SC12: restored edits let the re-review start')
finally:
    f.close()

f = Fixture()
try:
    f.start()
    f.finish()
    f.clock(1)
    f.with_issue(f.issue['body'].replace('repair', 'rewrite'))
    before = f.state_path.read_bytes()
    result = f.observe(ok=False)
    check(result.returncode != 0 and 'latest Issue specification differs from observation' in result.stderr
          and HINT not in result.stderr, 'T-SC13: a run with no observation is not pointed at reconcile')
    check(f.state_path.read_bytes() == before, 'T-SC13: last state retained')
    f.reject(lambda: reconcile(f, ok=False), 'T-SC13: reconcile names the missing observation',
             'rebuild the observation input')
finally:
    f.close()


f = Fixture()
try:
    diverge(f)
    f.with_issue(f.issue['body'].replace('repair', 'rewrite'))
    f.reject(lambda: reconcile(f, ok=False), 'T-SC11: a stopped run cannot be reconciled', 'review run stopped')
    f.plan()
    refused = retry(f, ok=False)
    check(refused.returncode != 0 and HINT not in refused.stderr, 'T-SC11: a stopped run is not pointed at reconcile')
finally:
    f.close()

print('PASS: review stagnation retry: ' + str(stagnation_fixture.checks) + ' assertions; real clocks, receipts, repairs and retained stops')
PYTEST
