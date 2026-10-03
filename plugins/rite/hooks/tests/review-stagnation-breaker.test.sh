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
    publish_stale, retry,
)
sys.path.insert(0, str(plugin / 'hooks/scripts/lib'))

f = Fixture()
try:
    f.start()
    f.finish()
    f.clock(86400, 'external_wait')
    f.clock(86400, 'interruption')
    f.observe()
    check(f.decision() == 'continue' and f.state()['review_run']['diagnosed_work_seconds'] == 0,
          'external wait and interruption never become work')
    for _ in range(3):
        f.cycle()
    check(f.decision() == 'continue' and not f.state()['review_run']['fixes'],
          'same HEAD rereviews cannot count as recurrence')
    f.plan()
    f.scope()
    (f.root / 'source.txt').write_text('unverified\n')
    f.commit()
    f.reject(lambda: f.start(ok=False), 'unverified changed HEAD cannot start review')
    refused = f.start(ok=False)
    check('base-intake fix plan' in refused.stderr and 'fix-plan.md, section: base 取り込み' in refused.stderr,
          'changed HEAD refusal points to the base intake route: ' + refused.stderr)
finally:
    f.close()

f = Fixture()
try:
    f.cycle(roots=('input defect', 'secondary defect', 'third defect'))
    f.fix()
    f.cycle(roots=('input defect', 'secondary defect'))
    f.fix()
    f.cycle(seconds=1801)
    check(f.decision() == 'replan' and f.state()['review_run']['current_decision']['reasons']
          == ['work-time', 'root-recurrence'], 'falling counts and simultaneous causes diagnose once')
    f.fix()
    f.cycle()
    check(f.decision() == 'continue', 'one post-replan repair is not non-convergence')
    f.fix()
    f.cycle()
    check(f.decision() == 'stop' and len(f.state()['review_run']['fixes']) == 4,
          'same root after two verified post-replan repairs without progress stops')
    before = f.state_path.read_bytes()
    f.observe()
    check(f.state_path.read_bytes() == before, 'stopped observation replay is idempotent')
    f.reject(lambda: f.start(ok=False), 'stopped run cannot restart')
    f.reject(lambda: f.flow('set', '--phase', 'review', '--next', 'review', '--active', 'true', ok=False),
             'ordinary set cannot reactivate stopped run')
    f.flow('set', '--phase', 'review', '--next', 'recover', '--active', 'false')
    check(f.state()['stop_reason'] == 'stagnation:non-convergent', 'ordinary stopped update retains reason')
    run = f.state()['review_run']
    f.flow('set', '--phase', 'review', '--next', 'stopped', '--active', 'false',
           '--stop-reason', 'circuit-breaker:stagnation')
    check(f.state()['review_run'] == run, 'iterate terminal notification retains non-convergent cause')
    f.reject(lambda: f.flow('review-close', ok=False), 'stopped run cannot record completion')
    f.reject(lambda: f.flow('review-defer', ok=False), 'stopped run cannot defer to another Issue')
finally:
    f.close()

f = Fixture()
try:
    f.cycle(seconds=1801)
    f.fix()
    f.cycle(roots=['new defect'], seconds=1801, satisfied=['AC-1'])
    f.fix()
    f.cycle(roots=['another defect'], seconds=1801, satisfied=['AC-1', 'AC-2'])
    check(f.decision() == 'continue' and len(f.state()['review_run']['replans']) == 2,
          'finite replan allowance and elapsed time alone never stop')
    f.fix()
    f.cycle(roots=(), seconds=1801, satisfied=('AC-1', 'AC-2', 'AC-3'))
    check(f.decision() == 'continue', 'root resolution and progress retain normal merge gate')
    f.flow('set', '--phase', 'ready', '--next', 'ready')
    check(f.state()['cycle_count'] == 4, 'ready transition preserves run counter and history')
    old_run = f.state()['review_run']
    f.flow('set', '--phase', 'cleanup', '--next', 'cleanup', '--active', 'false')
    f.flow('set', '--phase', 'init', '--next', 'branch', '--issue', 43, '--pr', 0, '--active', 'true')
    state = f.state()
    check(state.get('cycle_count', 0) == 0 and 'review_run' not in state and 'review_cycle' not in state
          and archived_run(state) == old_run, 'completed ownership starts new Issue with clean cycle and archived history')
    f.flow('set', '--phase', 'pr', '--next', 'review', '--pr', 72)
    f.start()
    check(f.context()['run_id'] != old_run['run_id'] and archived_run(f.state()) == old_run,
          'new review run has a new identity and preserves archived run across ordinary sets')
finally:
    f.close()

f = Fixture()
try:
    f.cycle(seconds=1801)
    f.plan(replan=True, insoluble=True)
    f.replan()
    check(f.decision() == 'stop' and f.state()['stop_reason'] == 'stagnation:scope-insoluble',
          'contractual insolubility retains alternatives and stops')
    run = f.state()['review_run']
    f.flow('set', '--phase', 'review', '--next', 'stopped', '--active', 'false',
           '--stop-reason', 'circuit-breaker:stagnation')
    check(f.state()['review_run'] == run and f.state()['stop_reason'] == 'stagnation:scope-insoluble',
          'iterate terminal notification retains scoped insolubility cause')
    f.reject(lambda: f.start(ok=False), 'insoluble run cannot restart')
finally:
    f.close()

f = Fixture()
try:
    f.cycle(seconds=1801)
    f.reject(lambda: f.flow('review-defer', ok=False), 'required replan cannot be deferred')
    f.plan(replan=True)
    f.replan()
    f.flow('review-defer')
    before = f.state_path.read_bytes()
    f.flow('review-defer')
    check(f.state_path.read_bytes() == before, 'defer replay is idempotent')
    check('completed_context' not in f.state()['review_run'], 'defer does not complete unresolved review')
    f.start()
    f.reject(lambda: f.flow('set', '--phase', 'init', '--next', 'next', '--issue', 43, '--pr', 0,
                           ok=False), 'previous deferred context cannot release a new pending cycle')
finally:
    f.close()

for seconds in [0, 1801]:
    f = Fixture()
    try:
        f.start()
        f.finish(roots=['fatal defect', 'advisory defect'], severities=['HIGH', 'MEDIUM'])
        f.clock(seconds)
        f.observe()
        receipt_path = Path(f.state()['review_cycle']['result_path'])
        f.run(['bash', str(plugin / 'scripts/review-findings-maps.sh'), '--review-source', 'local_file',
               '--review-source-path', str(receipt_path)])
        receipt = json.loads(receipt_path.read_text())
        check(len(receipt['findings']) == 1 and receipt['non_blocking_findings'][0]['id'] == 'F-02',
              'normal fatal triage persists advisory disposition')
        before = f.state_path.read_bytes()
        f.observe()
        check(f.state_path.read_bytes() == before, 'observation replay accepts only known triaged receipt')
        f.plan(replan=seconds > 1800)
        if seconds > 1800:
            f.replan()
            f.replan()
        f.scope()
        changed = copy.deepcopy(receipt)
        changed['findings'][0]['description'] = 'changed evidence'
        dump(receipt_path, changed)
        f.reject(lambda: f.scope(ok=False), 'triaged receipt evidence tampering remains rejected')
        if seconds > 1800:
            f.reject(lambda: f.replan(ok=False), 'replan replay cannot accept tampered receipt')
        dump(receipt_path, receipt)
        f.reject(lambda: f.flow('review-close', ok=False), 'unresolved fatal finding prevents completion')
        (f.root / 'source.txt').write_text('verified repair\n')
        f.scope('verify')
        f.commit()
        f.cycle(roots=[])
        check(f.decision() == 'continue', 'historical classified receipt permits next observation')
        f.flow('review-close')
        before = f.state_path.read_bytes()
        f.flow('review-close')
        check(f.state_path.read_bytes() == before, 'review completion replay preserves history')
        f.start()
        f.reject(lambda: f.flow('set', '--phase', 'init', '--next', 'next', '--issue', 43, '--pr', 0,
                               ok=False), 'previous completed context cannot close a new pending cycle')
    finally:
        f.close()

f = Fixture()
try:
    f.start()
    f.finish()
    f.clock(1801)
    original = copy.deepcopy(f.observed)
    for key, value in [('session_id', 'foreign'), ('run_id', 'foreign'), ('commit_sha', '0' * 40)]:
        candidate = copy.deepcopy(original)
        candidate['review_context'][key] = value
        dump(f.input, candidate)
        f.reject(lambda: f.observe(ok=False), 'foreign observation ' + key)
    candidate = copy.deepcopy(original)
    candidate['acceptance']['satisfied'] = ['invented-progress']
    dump(f.input, candidate)
    f.reject(lambda: f.observe(ok=False), 'fabricated progress differs from receipt')
    dump(f.input, original)
    receipt = Path(f.state()['review_cycle']['result_path'])
    receipt_bytes = receipt.read_bytes()
    receipt.write_text('{broken')
    f.reject(lambda: f.observe(ok=False), 'corrupt receipt precedes diagnosis')
    receipt.write_bytes(receipt_bytes)
    # flow-state's shell writer uses mv; replace it only in this isolated PATH.
    fake_bin = f.private / 'bin'
    fake_bin.mkdir()
    fake_mv = fake_bin / 'mv'
    fake_mv.write_text('#!/bin/sh\nexit 7\n')
    fake_mv.chmod(0o755)
    old_path = f.env['PATH']
    f.env['PATH'] = str(fake_bin) + ':' + old_path
    f.reject(lambda: f.observe(ok=False), 'atomic observation save failure')
    f.env['PATH'] = old_path
    f.observe()
    check(len(f.state()['review_run']['observations']) == 1, 'retry after failed persistence records once')
    f.plan(replan=True)
    f.replan()
    f.scope()
    (f.root / 'source.txt').write_text('verified edit\n')
    f.scope('verify')
    (f.root / 'source.txt').write_text('changed after verification\n')
    f.commit()
    f.reject(lambda: f.start(ok=False), 'different committed tree rejects verification reuse')
finally:
    f.close()

f = Fixture()
try:
    f.cycle()
    f.flow('set', '--phase', 'review', '--next', 'recover', '--active', 'false',
           '--stop-reason', 'circuit-breaker:divergence')
    check(f.decision() == 'stop', 'existing breaker is recorded before any new diagnosis')
    f.reject(lambda: f.start(ok=False), 'breaker cannot be bypassed by strict review-start')
    f.flow('set', '--phase', 'review', '--next', 'recover', '--active', 'false')
    check(f.state()['stop_reason'] == 'circuit-breaker:divergence', 'breaker reason persists across recover sets')
finally:
    f.close()

f = Fixture()
try:
    f.cycle(seconds=1801)
    f.fix()
    f.cycle(satisfied=['AC-1'])
    f.fix()
    f.cycle(satisfied=['AC-1'])
    check(f.decision() == 'replan' and f.state()['review_run']['status'] == 'active',
          'measured acceptance progress prevents non-convergence stop after two repairs')
finally:
    f.close()

f = Fixture()
try:
    f.cycle(roots=['input defect'])
    f.fix()
    f.cycle(roots=('input defect', 'second defect'))
    f.fix()
    f.cycle(roots=('input defect', 'second defect', 'third defect'), seconds=1801)
    check(f.decision() == 'stop' and f.state()['stop_reason'] == 'circuit-breaker:divergence'
          and not f.state()['review_run']['replans'], 'divergence precedes simultaneous time and recurrence diagnosis')
finally:
    f.close()

for roots, expected in [(['input defect'], 'stop'), ([], 'continue')]:
    f = Fixture()
    try:
        (f.root / 'rite-config.yml').write_text('safety:\n  max_review_cycles: 1\n')
        f.cycle(roots=roots, seconds=1801)
        check(f.decision() == expected, 'existing configured cycle cap with mergeable exception')
        if roots:
            check(f.state()['stop_reason'] == 'circuit-breaker:max-cycles', 'configured cap precedes replan')
    finally:
        f.close()

f = Fixture()
try:
    f.start()
    f.finish(non_blocking=True)
    f.clock(1801)
    f.observe()
    plan = f.plan(replan=True)
    f.reject(lambda: f.replan(ok=False), 'replan cannot omit non-blocking findings from reconsideration')
    note = copy.deepcopy(plan['groups'][0])
    note.update(root_cause='informational observation', finding_ids=['F-99'], action='nit-noted', paths=[])
    plan['groups'].append(note)
    dump(f.plan_path, plan)
    f.replan()
    check(f.decision() == 'continue', 'all findings have explicit replan dispositions')
finally:
    f.close()


def round_trip(fixture, reason):
    """Leave for another Issue, come back, and confirm the stop came back too."""
    before = fixture.state()['cycle_count']
    fixture.flow('set', '--phase', 'init', '--next', 'branch', '--issue', 43, '--branch', 'chore/issue-43', '--pr', 0)
    fixture.flow('set', '--phase', 'pr', '--next', 'review', '--issue', 42, '--pr', 71)
    state = fixture.state()
    check(state.get('review_run', {}).get('status') == 'stopped' and state.get('stop_reason') == reason,
          'T-14: the round trip restores the stop (' + reason + ')')
    check(state.get('cycle_count') == before,
          'T-14: the round trip does not zero the counter (' + reason + ')')
    check(state.get('active') is False,
          'T-14: the restored stop deactivates the session as the original stop did (' + reason + ')')
    fixture.reject(lambda: fixture.start(ok=False),
                   'T-14: the round trip cannot restart review (' + reason + ')')


# T-01 / T-02 / T-11: the exit, what it keeps, and what it must not carry forward.
f = Fixture()
try:
    diverge(f)
    stopped_run = f.state()['review_run']
    # No cleanup first: this is the shape the new-Issue entry writes.
    f.flow('set', '--phase', 'init', '--next', 'branch', '--issue', 43, '--branch', 'chore/issue-43', '--pr', 0)
    moved = f.state()
    check(moved['issue_number'] == 43 and moved.get('cycle_count', 0) == 0
          and 'review_run' not in moved and 'review_cycle' not in moved,
          'T-01: stopped run releases the session to another Issue')
    check(archived_run(moved) == stopped_run, 'T-01: the stopped run is archived, not discarded')
    archived = archived_run(moved)
    check(archived['status'] == 'stopped' and archived['stop_reason'] == 'circuit-breaker:divergence'
          and archived['observations'], 'T-02: archived run retains its stop, reason and observations')
    check(not moved.get('stop_reason'), 'T-11: the new Issue starts without the previous stop reason')
    check(moved.get('active') is not False, 'T-11: the new Issue is not left deactivated by the previous stop')
finally:
    f.close()

# T-01: the ownership-cleanup route keeps working; the direct one is an addition.
f = Fixture()
try:
    diverge(f)
    stopped_run = f.state()['review_run']
    f.flow('set', '--phase', 'cleanup', '--next', 'cleanup', '--active', 'false')
    f.flow('set', '--phase', 'init', '--next', 'branch', '--issue', 43, '--pr', 0, '--active', 'true')
    check(f.state()['issue_number'] == 43 and archived_run(f.state()) == stopped_run,
          'T-01: cleanup then switch still archives the stopped run')
finally:
    f.close()

# T-03 / T-04: what a stop still refuses when no retry has been granted.
f = Fixture()
try:
    diverge(f)
    f.reject(lambda: f.start(ok=False), 'T-03: divergence-stopped run cannot start another review')
    f.reject(lambda: f.flow('review-close', ok=False), 'T-04: divergence-stopped run cannot be closed as complete')
    f.reject(lambda: f.flow('review-defer', ok=False), 'T-04: divergence-stopped run cannot be deferred')
finally:
    f.close()

# T-05: an unstopped run keeps the ownership requirement it always had.
f = Fixture()
try:
    f.cycle()
    check(f.state()['review_run']['status'] == 'active', 'T-05: fixture run is not stopped')
    f.reject(lambda: f.flow('set', '--phase', 'init', '--next', 'branch', '--issue', 43, '--pr', 0, ok=False),
             'T-05: active run still requires completed, deferred or cleaned-up ownership')
    f.flow('set', '--phase', 'cleanup', '--next', 'cleanup', '--active', 'false')
    f.flow('set', '--phase', 'init', '--next', 'branch', '--issue', 43, '--pr', 0, '--active', 'true')
    check(f.state()['issue_number'] == 43, 'T-05: the ownership-cleanup route is what releases an active run')
finally:
    f.close()

# T-06: the grant, and where the stop reason goes.
f = Fixture()
try:
    diverge(f)
    f.plan()
    retry(f)
    run = f.state()['review_run']
    check(run['status'] == 'active' and 'stop_reason' not in run and not f.state().get('stop_reason')
          and f.state()['active'] is True, 'T-06: a granted retry reopens the run')
    check(run['retry']['stop_reason'] == 'circuit-breaker:divergence'
          and run['retry']['stop_context'] == f.context() and run['retry']['outcome'] is None,
          'T-06: the grant retains the stop it answers')
    check(run['observations'] and run['fixes'], 'T-06: the grant keeps the run history it was issued against')
    f.scope()
finally:
    f.close()

# T-07: only divergence is retryable.
f = Fixture()
try:
    (f.root / 'rite-config.yml').write_text('safety:\n  max_review_cycles: 1\n')
    f.cycle(roots=['input defect'], seconds=1801)
    check(f.state()['stop_reason'] == 'circuit-breaker:max-cycles', 'T-07: fixture reached the cycle cap')
    f.plan()
    f.reject(lambda: retry(f, ok=False), 'T-07: circuit-breaker:max-cycles cannot be retried')
finally:
    f.close()

f = Fixture()
try:
    f.cycle(seconds=1801)
    f.plan(replan=True, insoluble=True)
    f.replan()
    check(f.state()['stop_reason'] == 'stagnation:scope-insoluble', 'T-07: fixture reached scoped insolubility')
    f.reject(lambda: retry(f, ok=False), 'T-07: stagnation:scope-insoluble cannot be retried')
finally:
    f.close()

# T-08: one grant per run, and the archive counts.
f = Fixture()
try:
    diverge(f)
    f.plan()
    retry(f)
    f.reject(lambda: retry(f, ok=False), 'T-08: a run cannot be granted a second retry')
finally:
    f.close()

f = Fixture()
try:
    # A historical defer marker remains when a later cycle stops this run.
    f.cycle(roots=['input defect'])
    f.flow('review-defer')
    deferred = f.state()['review_run']['deferred_context']
    f.fix()
    f.cycle(roots=('input defect', 'second defect'))
    f.fix()
    f.cycle(roots=('input defect', 'second defect', 'third defect'), seconds=1801)
    check(f.state()['review_run']['deferred_context'] == deferred,
          'T-08: real defer survives the later divergence')
    f.plan()
    retry(f)
    f.cycle(roots=['input defect'])
    check(f.state()['review_run']['status'] == 'stopped', 'T-08: the granted retry ended unresolved')
    f.flow('set', '--phase', 'init', '--next', 'branch', '--issue', 43, '--branch', 'chore/issue-43', '--pr', 0)
    archived = archived_run(f.state())
    check('retry' in archived and archived['status'] == 'stopped',
          'T-08: the direct exit archives the spent grant, it does not reset the gate')
    f.flow('set', '--phase', 'pr', '--next', 'review', '--issue', 42, '--pr', 71)
    check('retry' in f.state().get('review_run', {}) and f.state().get('review_run', {}).get('status') == 'stopped',
          'T-08: returning to the PR brings the spent grant back with the run')
    check(isinstance(f.state().get('review_cycle'), dict),
          'T-08: returning also brings back the frozen cycle the grant is checked against')
    restored = f.state()
    check(restored['review_run'] == archived, 'T-08: stale defer loses no run history on restore')
    round_trip(f, restored['stop_reason'])
    check(f.state()['review_run'] == archived, 'T-08: repeated restore preserves the spent retry')
    f.reject(lambda: f.start(ok=False), 'T-08: restored stop refuses a fresh review')
    # Direct switching must restore before a new review can mint another run.
    stopped_snapshot = f.state()
    f.flow('set', '--phase', 'pr', '--next', 'review', '--issue', 43, '--pr', 72)
    f.start()
    f.flow('review-abandon', '--reason', 'second PR retained')
    retained_snapshot = f.state()
    corrupted = copy.deepcopy(retained_snapshot)
    corrupted['review_run_history'][-1].pop('parked')
    dump(f.state_path, corrupted)
    f.reject(lambda: f.flow('set', '--phase', 'pr', '--next', 'review', '--issue', 42, '--pr', 71, ok=False),
             'T-08: failed direct restore preserves the source run and all history')
    dump(f.state_path, retained_snapshot)
    f.flow('set', '--phase', 'pr', '--next', 'review', '--issue', 42, '--pr', 71)
    for key in ('review_run', 'review_cycle', 'cycle_count', 'stop_reason', 'active'):
        check(f.state()[key] == stopped_snapshot[key], 'T-08: retained-to-stopped restores ' + key)
    f.reject(lambda: f.start(ok=False), 'T-08: direct return cannot bypass the stop')
    f.flow('set', '--phase', 'pr', '--next', 'review', '--issue', 43, '--pr', 72)
    for key in ('review_run', 'cycle_count'):
        check(f.state()[key] == retained_snapshot[key], 'T-08: stopped-to-retained restores ' + key)
    check(not f.state().get('stop_reason') and f.state().get('active') is not False,
          'T-08: stopped source does not poison active destination')
    f.flow('set', '--phase', 'pr', '--next', 'resume')
    f.start()
    f.clock(60)
    f.flow('review-abandon', '--reason', 'direct restore consumers passed')
    f.flow('set', '--phase', 'pr', '--next', 'review', '--issue', 42, '--pr', 71)
    check(f.state()['review_run'] == archived, 'T-08: direct roundtrips preserve used retry and observations')
    f.plan()
    f.reject(lambda: retry(f, ok=False), 'T-08: the restored run cannot be granted another retry')
finally:
    f.close()

# T-12 / T-13: what leaving parks, and what returning brings back.
f = Fixture()
try:
    diverge(f)
    stopped_run = f.state()['review_run']
    frozen = f.state()['review_cycle']
    before = f.state()['cycle_count']
    f.flow('set', '--phase', 'init', '--next', 'branch', '--issue', 43, '--branch', 'chore/issue-43', '--pr', 0)
    moved = f.state()
    check('review_run' not in moved and 'review_cycle' not in moved and not moved.get('stop_reason'),
          'T-12: leaving clears the live run, cycle and stop reason')
    check(archived_run(moved) == stopped_run, 'T-12: the parked entry carries the run itself')
    check(parked_of(moved) == dict(cycle_count=before, review_cycle=frozen),
          'T-12: the parked entry carries the counter and the frozen cycle')

    f.flow('set', '--phase', 'pr', '--next', 'review', '--issue', 42, '--pr', 71)
    back = f.state()
    check(back.get('review_run') == stopped_run and back.get('review_cycle') == frozen,
          'T-13: returning restores the run and its frozen cycle')
    check(back.get('cycle_count') == before and back.get('stop_reason') == 'circuit-breaker:divergence',
          'T-13: returning restores the counter and the stop reason')
    check(back.get('review_run_history', []) == [], 'T-13: a restored entry leaves the history')
    check(len(back.get('review_run', {}).get('observations', [])) == 3,
          'T-13: the observations come back with the run')
finally:
    f.close()

# T-14: the round trip is not a reset, whatever stopped the run.
f = Fixture()
try:
    diverge(f)
    round_trip(f, 'circuit-breaker:divergence')
finally:
    f.close()

f = Fixture()
try:
    (f.root / 'rite-config.yml').write_text('safety:\n  max_review_cycles: 1\n')
    f.cycle(roots=['input defect'], seconds=1801)
    check(f.state()['stop_reason'] == 'circuit-breaker:max-cycles', 'T-14: fixture reached the cycle cap')
    round_trip(f, 'circuit-breaker:max-cycles')
finally:
    f.close()

f = Fixture()
try:
    f.cycle(seconds=1801)
    f.plan(replan=True, insoluble=True)
    f.replan()
    check(f.state()['stop_reason'] == 'stagnation:scope-insoluble', 'T-14: fixture reached scoped insolubility')
    round_trip(f, 'stagnation:scope-insoluble')
finally:
    f.close()

# T-15: a restored divergence keeps the one door back; a restored cap does not.
f = Fixture()
try:
    diverge(f)
    f.flow('set', '--phase', 'init', '--next', 'branch', '--issue', 43, '--branch', 'chore/issue-43', '--pr', 0)
    f.flow('set', '--phase', 'pr', '--next', 'review', '--issue', 42, '--pr', 71)
    f.plan()
    retry(f)
    check(f.state()['review_run']['status'] == 'active'
          and f.state()['review_run']['retry']['stop_reason'] == 'circuit-breaker:divergence',
          'T-15: a restored divergence can still be retried')
finally:
    f.close()

f = Fixture()
try:
    (f.root / 'rite-config.yml').write_text('safety:\n  max_review_cycles: 1\n')
    f.cycle(roots=['input defect'], seconds=1801)
    f.flow('set', '--phase', 'init', '--next', 'branch', '--issue', 43, '--branch', 'chore/issue-43', '--pr', 0)
    f.flow('set', '--phase', 'pr', '--next', 'review', '--issue', 42, '--pr', 71)
    f.plan()
    f.reject(lambda: retry(f, ok=False), 'T-15: a restored cycle cap is still not retryable')
finally:
    f.close()

# T-16: restoring does not depend on the parked run having a frozen cycle. A run
# that drops an evidence-free cycle keeps no frozen counterpart, and the caller
# that parks that shape records why the pairing is absent; the counter has to
# come home either way, or that shape is the one exit with no way back. This
# module's own paths always park a paired run, so the shape is built here.
f = Fixture()
try:
    diverge(f)
    stopped_run = f.state()['review_run']
    before = f.state()['cycle_count']
    f.flow('set', '--phase', 'init', '--next', 'branch', '--issue', 43, '--branch', 'chore/issue-43', '--pr', 0)
    cycleless = json.loads(f.state_path.read_text())
    entry = dict(stopped_run, parked=dict(cycle_count=before))
    cycleless['review_run_history'] = [entry]
    f.state_path.write_text(json.dumps(cycleless))
    f.flow('set', '--phase', 'pr', '--next', 'review', '--issue', 42, '--pr', 71)
    back = f.state()
    check(back.get('cycle_count') == before and 'review_cycle' not in back,
          'T-16: the counter comes back without inventing a frozen cycle')
    check(back.get('review_run') == stopped_run and back.get('stop_reason') == 'circuit-breaker:divergence',
          'T-16: the stop comes back with it')
    check(back.get('review_run_history', []) == [], 'T-16: the restored entry leaves the history')
finally:
    f.close()

# T-18: a parked stop this PR cannot restore stops the set instead of falling
# through to the fresh run parking exists to withhold.
f = Fixture()
try:
    diverge(f)
    f.flow('set', '--phase', 'init', '--next', 'branch', '--issue', 43, '--branch', 'chore/issue-43', '--pr', 0)
    raw = json.loads(f.state_path.read_text())
    legacy = {k: v for k, v in raw['review_run_history'][0].items() if k != 'parked'}
    raw['review_run_history'] = [legacy]
    f.state_path.write_text(json.dumps(raw))
    f.reject(lambda: f.flow('set', '--phase', 'pr', '--next', 'review', '--issue', 42, '--pr', 71, ok=False),
             'T-18: a stop parked without its frozen cycle and counter refuses the return')
    check('review_run' not in f.state() and f.state().get('cycle_count', 0) == 0,
          'T-18: the refused return starts no run of its own')
finally:
    f.close()

f = Fixture()
try:
    diverge(f)
    f.flow('set', '--phase', 'init', '--next', 'branch', '--issue', 43, '--branch', 'chore/issue-43', '--pr', 0)
    f.reject(lambda: f.flow('set', '--phase', 'pr', '--next', 'review', '--pr', 71, ok=False),
             'T-18: raising the PR without its Issue refuses rather than skipping the parked stop')
    check('review_run' not in f.state(), 'T-18: the refused return leaves the parked stop in the history')
    f.flow('set', '--phase', 'pr', '--next', 'review', '--issue', 42, '--pr', 71)
    check(f.state()['review_run']['status'] == 'stopped',
          'T-18: naming the Issue restores the parked stop as usual')
finally:
    f.close()

# T-19: close/defer of the current parked context ends an active run. Those
# settled runs stay archived; older markers must not settle a later cycle.
f = Fixture()
try:
    f.cycle(seconds=1801, satisfied=['AC-1'])
    f.fix()
    f.cycle(roots=(), seconds=1801, satisfied=('AC-1', 'AC-2'))
    f.flow('review-close')
    closed_run = f.state()['review_run']
    check('completed_context' in closed_run and f.state()['cycle_count'] == 2,
          'T-19: fixture closed a run with a spent counter')
    f.flow('set', '--phase', 'cleanup', '--next', 'cleanup', '--active', 'false')
    f.flow('set', '--phase', 'init', '--next', 'branch', '--issue', 43, '--branch', 'chore/issue-43', '--pr', 0)
    f.flow('set', '--phase', 'pr', '--next', 'review', '--issue', 42, '--pr', 71)
    back = f.state()
    check('review_run' not in back and back.get('cycle_count', 0) == 0,
          'T-19: returning to a closed run starts the next round instead of resuming it')
    check(archived_run(back) == closed_run, 'T-19: the closed run stays in the history')
finally:
    f.close()

f = Fixture()
try:
    f.cycle(seconds=1801)
    f.plan(replan=True)
    f.replan()
    f.flow('review-defer')
    deferred_run = f.state()['review_run']
    f.flow('set', '--phase', 'cleanup', '--next', 'cleanup', '--active', 'false')
    f.flow('set', '--phase', 'init', '--next', 'branch', '--issue', 43, '--branch', 'chore/issue-43', '--pr', 0)
    f.flow('set', '--phase', 'pr', '--next', 'review', '--issue', 42, '--pr', 71)
    check('review_run' not in f.state() and f.state().get('cycle_count', 0) == 0,
          'T-19: returning to a deferred run does not resume it either')
    check(archived_run(f.state()) == deferred_run, 'T-19: the deferred run stays in the history')
finally:
    f.close()

# T-20: park() keeps the counter for a run with no frozen cycle. The set path
# cannot deliver that shape here — current() requires the pairing before park()
# is reached — so the contract is asserted against the function the caller that
# drops an evidence-free cycle will call. Being a contract check, it says nothing
# about the system: it cannot see a caller that stops feeding park() that shape,
# a current() that keeps rejecting it, or a counter lost before park() is reached.
# Once a caller does deliver it, pin those three through the set path as well.
sys.path.insert(0, str(plugin / 'hooks/scripts/lib'))
stagnation = importlib.import_module('review-stagnation')

unpaired = stagnation.park(dict(cycle_count=4), dict(pr_number=71, status='stopped'))
check(unpaired['parked'] == dict(cycle_count=4),
      'T-20: a state with no frozen cycle parks the counter alone')
paired = stagnation.park(dict(cycle_count=4, review_cycle=dict(status='completed')), dict(pr_number=71))
check(paired['parked'] == dict(cycle_count=4, review_cycle=dict(status='completed')),
      'T-20: a state with a frozen cycle parks both')
subject = dict(pr_number=71)
wrapped = stagnation.park(dict(cycle_count=4), subject)
check(wrapped['pr_number'] == 71 and 'parked' not in subject,
      'T-20: parking copies the run rather than writing the envelope into it')

# T-17: a receipt swapped after the observation is not a retryable state.
f = Fixture()
try:
    diverge(f)
    f.plan()
    saved = f.state()['review_run']['observations'][-1]
    receipt = json.loads(Path(saved['result_path']).read_text())
    receipt['findings'][0]['description'] = receipt['findings'][0]['description'] + ' (rewritten)'
    Path(saved['result_path']).write_text(json.dumps(receipt))
    f.reject(lambda: retry(f, ok=False), 'T-17: a changed receipt cannot be retried')
    check(f.state()['review_run']['status'] == 'stopped' and 'retry' not in f.state()['review_run'],
          'T-17: the refused retry leaves the stop and grants nothing')
finally:
    f.close()

# T-09: a broken precondition grants nothing and leaves the stop standing.
f = Fixture()
try:
    diverge(f)
    f.plan()
    f.commit()
    f.reject(lambda: retry(f, ok=False), 'T-09: a moved HEAD cannot be retried')
    check(f.state()['review_run']['status'] == 'stopped'
          and f.state()['review_run']['stop_reason'] == 'circuit-breaker:divergence',
          'T-09: the run is still stopped after a refused retry')
finally:
    f.close()

f = Fixture()
try:
    diverge(f)
    broken = f.plan()
    broken['groups'][0]['finding_ids'] = broken['groups'][0]['finding_ids'][:1]
    dump(f.plan_path, broken)
    f.reject(lambda: retry(f, ok=False), 'T-09: a plan that leaves blocking findings undisposed cannot be retried')
    check('retry' not in f.state()['review_run'], 'T-09: a refused retry records no grant')
finally:
    f.close()

# T-09: a recorded replan still binds the plan a retry may be granted against.
f = Fixture()
try:
    f.cycle(seconds=1801)
    check(f.decision() == 'replan', 'fixture requires a replan at the stop context')
    required = f.plan(replan=True)
    f.replan()
    f.flow('set', '--phase', 'review', '--next', 'stopped', '--active', 'false',
           '--stop-reason', 'circuit-breaker:divergence')
    check(f.state()['review_run']['status'] == 'stopped', 'fixture stopped at a replanned context')
    f.plan()
    f.reject(lambda: retry(f, ok=False), 'T-09: a retry cannot substitute a plan for the required replan')
    dump(f.plan_path, required)
    retry(f)
    check(f.state()['review_run']['status'] == 'active', 'T-09: the required replan is a retryable plan')
finally:
    f.close()

# T-10: the grant buys one review, and an unresolved one ends it.
f = Fixture()
try:
    diverge(f)
    f.plan()
    retry(f)
    f.fix()
    f.cycle(roots=['input defect'])
    run = f.state()['review_run']
    check(run['status'] == 'stopped' and run['stop_reason'] == 'circuit-breaker:divergence'
          and run['current_decision']['reasons'] == ['retry-unresolved'],
          'T-10: unresolved findings return the run to its stop')
    check(run['retry']['outcome'] == 'unresolved', 'T-10: the grant records that it was spent')
    check(f.state()['active'] is False and f.state()['stop_reason'] == 'circuit-breaker:divergence',
          'T-10: the session is deactivated with the original reason')
    f.plan()
    f.reject(lambda: retry(f, ok=False), 'T-10: a spent grant is not reissued')
    f.reject(lambda: f.start(ok=False), 'T-10: the re-stopped run cannot start another review')
finally:
    f.close()

# T-21: concluding a retry does not excuse the run from the checks every other
# stop path makes. A receipt rewritten behind an earlier observation has to be
# caught on the retry's own review, not only on the paths that reach the breaker.
f = Fixture()
try:
    diverge(f)
    f.plan()
    retry(f)
    f.fix()
    first = f.state()['review_run']['observations'][0]
    receipt = json.loads(Path(first['result_path']).read_text())
    receipt['findings'][0]['description'] = receipt['findings'][0]['description'] + ' (rewritten)'
    Path(first['result_path']).write_text(json.dumps(receipt))
    f.start()
    f.finish(['input defect'])
    f.clock(1)
    f.reject(lambda: f.observe(ok=False),
             'T-21: a rewritten historical receipt stops the retry review too')
finally:
    f.close()

f = Fixture()
try:
    diverge(f)
    f.plan()
    retry(f)
    f.fix()
    f.cycle(roots=())
    run = f.state()['review_run']
    check(run['status'] == 'active' and run['retry']['outcome'] == 'resolved',
          'T-10: a retry that clears every blocking finding continues the run')
finally:
    f.close()


print('PASS: review stagnation breaker: ' + str(stagnation_fixture.checks) + ' assertions; real clocks, receipts, repairs and retained stops')
PYTEST
