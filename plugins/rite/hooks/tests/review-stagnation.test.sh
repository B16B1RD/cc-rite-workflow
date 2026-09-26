#!/usr/bin/env bash
# Real review receipts, explicit clocks and verified repairs in isolated repositories.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 - "$SCRIPT_DIR/../.." <<'PYTEST'
import copy
import datetime
import hashlib
import importlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

plugin = Path(sys.argv[1]).resolve()
checks = 0

# Production _atomic_write is not a CLI. Drive it through a copy of flow-state.sh
# whose dispatcher is replaced, with SCRIPT_DIR pinned to the plugin hooks dir.
_ATOMIC_DRIVER = (plugin / 'hooks/flow-state.sh').read_text().replace(
    'SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"',
    'SCRIPT_DIR=' + json.dumps(str(plugin / 'hooks')),
    1,
).replace(
    'case "${1:-}" in',
    '''if [ -n "${RITE_ATOMIC_TARGET:-}" ]; then
  if [ "${RITE_TEST_HIDE_FLOCK:-}" = 1 ]; then
    command() {
      if [ "$1" = "-v" ] && [ "$2" = "flock" ]; then
        return 1
      fi
      builtin command "$@"
    }
    if command -v flock >/dev/null 2>&1; then
      echo "ERROR: T-R09 hide-flock failed; flock still visible" >&2
      exit 2
    fi
  fi
  content=$(python3 -c 'import pathlib,sys; sys.stdout.write(pathlib.Path(sys.argv[1]).read_text())' "$RITE_ATOMIC_CONTENT")
  _atomic_write "$RITE_ATOMIC_TARGET" "$content"
  exit $?
fi
case "${1:-}" in''',
    1,
)


def publish_stale(fixture, expected_hash, content, hide_flock=False):
    driver = fixture.private / 'atomic-write-driver.sh'
    driver.write_text(_ATOMIC_DRIVER)
    payload = fixture.private / 'stale-payload.json'
    if isinstance(content, bytes):
        payload.write_bytes(content)
    else:
        payload.write_text(content)
    env = dict(fixture.env,
               RITE_ATOMIC_TARGET=str(fixture.state_path),
               RITE_ATOMIC_CONTENT=str(payload),
               RITE_STATE_IF_MATCH=expected_hash)
    if hide_flock:
        env['RITE_TEST_HIDE_FLOCK'] = '1'
    return subprocess.run(['bash', str(driver)], cwd=fixture.root, env=env,
                          text=True, capture_output=True)


def check(value, label):
    global checks
    assert value, label
    checks += 1


def dump(path, value):
    path.write_text(json.dumps(value), encoding='utf-8')


def archived_run(state, index=0):
    """The parked run without the envelope that carries its frozen cycle."""
    entry = dict(state['review_run_history'][index])
    entry.pop('parked', None)
    return entry


def parked_of(state, index=0):
    return state['review_run_history'][index]['parked']


# Every fixture needs the same one-commit starting tree. Build it once and copy
# its independent Git metadata for each fixture instead of forking Git to init,
# add and commit on every construction.
_seed_temp = tempfile.TemporaryDirectory(prefix='rite-stagnation-seed-')
_seed_root = Path(_seed_temp.name)
_seed_env = dict(os.environ)
for _key in ('CODEX_THREAD_ID', 'GROK_SESSION_ID', 'CLAUDE_SESSION_ID', 'CLAUDE_CODE_SESSION_ID',
             'RITE_SESSION_ID', 'RITE_HOST', 'RITE_STATE_ROOT', 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE'):
    _seed_env.pop(_key, None)
subprocess.run(['git', 'init', '-q'], cwd=_seed_root, env=_seed_env, check=True)
(_seed_root / 'source.txt').write_text('initial\n')
subprocess.run(['git', 'add', 'source.txt'], cwd=_seed_root, env=_seed_env, check=True)
# Do not let detached auto-maintenance change lock files while fixtures copy
# this seed's Git metadata.
subprocess.run(['git', '-c', 'maintenance.auto=false',
                '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                'commit', '-q', '--allow-empty', '-m', 'fixture update'],
               cwd=_seed_root, env=_seed_env, check=True)


class Fixture:
    def __init__(self):
        self.temp = tempfile.TemporaryDirectory(prefix='rite-stagnation-')
        self.root = Path(self.temp.name)
        self.private = self.root / '.rite'
        self.private.mkdir()
        self.env = dict(os.environ)
        for key in ('CODEX_THREAD_ID', 'GROK_SESSION_ID', 'CLAUDE_SESSION_ID', 'CLAUDE_CODE_SESSION_ID',
                    'RITE_SESSION_ID', 'RITE_HOST', 'RITE_STATE_ROOT', 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE'):
            self.env.pop(key, None)
        self.session = 'stagnation-fixture'
        self.env.update(RITE_HOST='claude', CLAUDE_CODE_SESSION_ID=self.session,
                        RITE_STATE_ROOT=self.temp.name, TMPDIR=self.temp.name)
        shutil.copytree(_seed_root / '.git', self.root / '.git')
        check((self.root / '.git').is_dir(), 'independent Git fixture metadata copied')
        check((self.root / '.git/index').is_file(), 'fixture seed index copied')
        check((self.root / '.git/HEAD').is_file(), 'fixture seed HEAD copied')
        (self.root / '.git/info/exclude').write_text('.rite/\n')
        (self.root / 'source.txt').write_text('initial\n')
        self.flow('set', '--phase', 'pr', '--next', 'review', '--issue', 42, '--pr', 71)
        self.state_path = Path(self.flow('path').stdout.strip())
        self.selection = self.private / 'selection.json'
        dump(self.selection, ['code-quality-reviewer'])
        self.issue = dict(number=42, body='Contract: repair source.txt; preserve protected content.')
        self.issue_path = self.private / 'issue.json'
        dump(self.issue_path, self.issue)
        self.input = self.private / 'observation.json'
        self.plan_path = self.private / 'plan.json'
        self.time = datetime.datetime(2026, 1, 1, tzinfo=datetime.timezone.utc)
        self.serial = 0

    def close(self):
        self.temp.cleanup()

    def run(self, args, ok=True):
        result = subprocess.run(args, cwd=self.root, env=self.env, text=True, capture_output=True)
        if ok:
            check(result.returncode == 0, repr(args) + '\n' + result.stdout + result.stderr)
        return result

    def flow(self, *args, ok=True):
        return self.run(['bash', str(plugin / 'hooks/flow-state.sh'), *map(str, args)], ok)

    def state(self):
        return json.loads(self.state_path.read_text())

    def context(self):
        return self.state()['review_cycle']['review_context']

    def commit(self):
        self.run(['git', 'add', 'source.txt'])
        self.run(['git', '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                  'commit', '-q', '--allow-empty', '-m', 'fixture update'])

    def start(self, ok=True):
        return self.flow('review-start', '--selection', self.selection, '--stagnation', ok=ok)

    def finish(self, roots=None, satisfied=(), non_blocking=False, severities=None, unverified=()):
        if roots is None:
            roots = ['input defect']
        context = self.context()
        output = self.private / 'reviewer.md'
        output.write_text('### 評価: 要修正\n### 所見\n確認済み\n### 指摘事項\n再現済み\n### 監査ログ\nなし\n')
        manifest = self.private / 'manifest.json'
        dump(manifest, dict(schema_version=1, parent_agent_id=self.session, review_context=context,
                            selected_reviewers=['code-quality-reviewer'],
                            reviewers=[dict(reviewer='code-quality-reviewer', review_context=context,
                                            agent_id='review-child', status='completed',
                                            started_at='2026-01-01T00:00:00Z', ended_at='2026-01-01T00:01:00Z',
                                            output_file=str(output))]))
        findings = [dict(id='F-' + str(index + 1).zfill(2), reviewer='code-quality-reviewer',
                         severity='HIGH', scope='current-pr', status='open', file='source.txt', line=1,
                         description='Verification: repro ' + root + ' => failed', suggestion='repair')
                    for index, root in enumerate(roots)]
        content = self.private / 'review.json'
        if severities:
            for finding, severity in zip(findings, severities):
                finding['severity'] = severity
        notes = [dict(id='F-99', reviewer='code-quality-reviewer', severity='LOW', scope='nit-noted',
                      status='open', file='source.txt', line=1, description='Informational note', suggestion='consider')] if non_blocking else []
        dump(content, dict(schema_version='1.1.0', pr_number=context['pr_number'], review_context=context,
                           timestamp='__RITE_TS_PLACEHOLDER_7f3a9b2c__', commit_sha=context['commit_sha'],
                           reviewers=['code-quality-reviewer'], findings=findings, non_blocking_findings=notes,
                           guardrail_audit_log=[], acceptance_criteria=[
                               dict(id=criterion, status='satisfied', evidence='measured fixture => pass', finding_id=None)
                               for criterion in satisfied] + [
                               dict(id=criterion, status='unverified', evidence='needs a human check', finding_id=None)
                               for criterion in unverified]))
        self.run(['bash', str(plugin / 'scripts/review-measured-gate.sh'), '--input', str(content),
                  '--reject-preset-verification'])
        self.flow('review-finish', '--manifest', manifest, '--content-file', content)
        self.observed = dict(
            review_context=context, issue_number=42, issue_body=self.issue['body'],
            roots=[dict(defect=root, trigger='invalid input', violated_contract='input contract',
                        finding_ids=['F-' + str(index + 1).zfill(2)]) for index, root in enumerate(roots)],
            acceptance=dict(satisfied=list(satisfied), evidence='saved acceptance measurements'))
        dump(self.input, self.observed)

    def clock(self, seconds=0, kind='work', ok=True):
        self.serial += 1
        begin = self.time
        self.time += datetime.timedelta(seconds=seconds)
        data = dict(review_context=self.context(), segment_id='segment-' + str(self.serial), kind=kind,
                    started_at=begin.isoformat(), ended_at=self.time.isoformat())
        path = self.private / 'clock.json'
        dump(path, data)
        return self.flow('review-clock', '--input', path, ok=ok)

    def with_issue(self, body):
        self.issue['body'] = body
        dump(self.issue_path, self.issue)

    def observe(self, ok=True):
        return self.flow('review-observe', '--input', self.input, '--issue', self.issue_path, ok=ok)

    def decision(self):
        return self.state()['review_run']['current_decision']['action']

    def plan(self, replan=False, insoluble=False):
        ids = [fid for root in self.observed['roots'] for fid in root['finding_ids']]
        plan = dict(
            review_context=self.context(), issue_number=42, issue_body=self.issue['body'],
            constraints=dict(targets=['source.txt'], non_targets=['protected'], closed_targets=True, rationale='bounded'),
            groups=[dict(root_cause='grouped defects', finding_ids=ids, action='fix',
                         paths=['source.txt'], rationale='shared validation',
                         semantic=dict(approved=True, acceptance_criteria='restore contract', out_of_scope='preserve protected'),
                         verification_ids=['full'])],
            verifications=[dict(id='full', kind='full', command='test -s source.txt',
                                inputs=['source.txt'], environment=[])])
        if replan:
            plan['replan'] = dict(
                alternatives=[
                    dict(id='central', description='central input validation', paths=['source.txt'],
                         recurrence_prevention='full input regression', rejection_reason='' if not insoluble else 'contract prevents shared state'),
                    dict(id='local', description='local validation', paths=['source.txt'],
                         recurrence_prevention='full local regression', rejection_reason='duplicates contract enforcement')],
                selected_id=None if insoluble else 'central', selection_reason='preserve input contract',
                outcome='insoluble' if insoluble else 'continue')
        dump(self.plan_path, plan)
        return plan

    def scope(self, mode='check', ok=True):
        return self.run(['bash', str(plugin / 'hooks/scripts/review-fix-scope-check.sh'),
                         mode, '--plan', str(self.plan_path), '--issue', str(self.issue_path)], ok)

    def replan(self, ok=True):
        return self.flow('review-replan', '--plan', self.plan_path, '--issue', self.issue_path, ok=ok)

    def fix(self):
        if self.decision() == 'replan':
            self.plan(replan=True)
            self.replan()
        else:
            self.plan()
        self.scope()
        (self.root / 'source.txt').write_text('repair ' + str(self.state()['cycle_count']) + '\n')
        self.scope('verify')
        self.commit()

    def cycle(self, roots=None, seconds=0, satisfied=()):
        self.start()
        self.finish(roots, satisfied)
        self.clock(seconds)
        self.observe()

    def reject(self, operation, label):
        before = self.state_path.read_bytes()
        result = operation()
        check(result.returncode != 0 and 'ERROR:' in result.stderr, label)
        check(self.state_path.read_bytes() == before, label + ': last state retained')


# Explicit command corrections preserve diagnosis and failed execution evidence.
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
    mutant = f.private / 'mutant-hooks'
    shutil.copytree(plugin / 'hooks', mutant)
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

# Writer shapes and boundaries of the specification identity itself.
import contextlib
import importlib
import io
sys.path.insert(0, str(plugin / 'hooks/scripts/lib'))
identity = importlib.import_module('review-cycle')
same = identity.same_specification
row = '- 2026-01-02 D-01: defer the boundary / Reason: out of scope / Impact: none'
contract = ('## 1. Goal\n\nrepair source.txt\n\n<details>\n<summary>Implementation Contract</summary>\n\n'
            '## 5. Acceptance Criteria\n\n- AC-1: preserve protected content\n\n</details>\n\n---\n🤖 signature')
created = contract.replace('\n</details>', '\n## 9. Decision Log\n\n' + row + '\n\n</details>')
check(same(contract, created), 'section created before the contract details close is not a specification change')
check(same(created, created.replace('\n\n</details>', '\n' + row.replace('D-01', 'D-02') + '\n\n</details>')),
      'row appended to the created section is not a specification change')
check(same('## 9. Decision Log\n\n' + row + '\n\n## 10. Notes\n\nx', '## 10. Notes\n\nx'),
      'section followed by another heading is closed at that heading')
crlf = contract.replace('\n', '\r\n')
check(same(crlf, crlf + '\r\n\r\n<!-- rite:nbr:comment-id:101 -->\r\n'), 'record marker on a CRLF body is ignored')
check(same(contract, contract + '\n\n<!-- rite:nbr:comment-id:a b -->'), 'record marker with a broken value is ignored like the writer does')
edit = row.replace('defer', 'keep')
check(not same('```\n## 9. Decision Log\n' + row + '\n```', '```\n## 9. Decision Log\n' + edit + '\n```'),
      'Decision Log example inside a code fence is specification text')
for opener, inner in (('```', '~~~'), ('````', '```'), ('~~~', '```')):
    fence = '## 9. Decision Log\n' + opener + '\n' + inner + '\n'
    check(not same(fence + row + '\n' + opener, fence + edit + '\n' + opener),
          'a ' + inner + ' line does not close a ' + opener + ' fence')
check(not same('## 9. Decision Log\n~~~\n' + row + '\n~~~', '## 9. Decision Log\n~~~\n' + edit + '\n~~~'),
      'a tilde fence protects the rows inside it')
for closer, label in (('    ```', 'a closing line indented four spaces'), ('```bash', 'a closing line with trailing text')):
    fence = '## 9. Decision Log\n```\n' + closer + '\n'
    check(not same(fence + row + '\n```', fence + edit + '\n```'), label + ' does not close the fence')
check(same('## 9. Decision Log\n\n```inline``` code\n\n' + row, '## 9. Decision Log\n\n```inline``` code'),
      'a line with backticks after the opening run is inline code, not a fence')
check(not same('````\n## 9. Decision Log\n' + row + '\n````', '````\n## 9. Decision Log\n' + edit + '\n````'),
      'a four-backtick fence still opens')
check(same('## 9. Decision Log\n\n    ```\n' + row, '## 9. Decision Log\n\n    ```'),
      'code indented four spaces does not open a fence')
check(same('```\n## 9. Decision Log\n```\n', '```\n## 9. Decision Log\n```\n\n## 9. Decision Log\n\n' + row),
      'heading example inside a fence does not make the real section ambiguous')
check(same('## 9. Decision Log\n\n- note: manual\n', '## 9. Decision Log\n\n- note: manual\n\n' + row),
      'row appended after a free-form row closes the gap it leaves')
check(same('## 1. Goal\n\nx\n\n## 2. Scope\n\ny', '## 1. Goal\n\nx\n\n<!-- rite:nbr:comment-id:7 -->\n\n## 2. Scope\n\ny'),
      'record marker in the middle of the body closes the gap it leaves')
check(same('x\n\n---\nsignature', 'x\n\n## 9. Decision Log\n\n' + row + '\n\n---\nsignature'),
      'section created before the footer rule is closed at the rule')
check(not same('x', 'x\n\n## Decision Log\n\n' + row), 'a heading that is not exactly the Decision Log heading opens no section')
gap = '## 1. Goal\n\n\nrepair\n'
check(same('## 9. Decision Log\n\n' + row + '\n\n' + gap, gap) and not same(gap, gap.replace('\n\n\n', '\n\n')),
      'blank lines after a removed section keep their count')
stderr = io.StringIO()
with contextlib.redirect_stderr(stderr):
    raw = identity.normalize_issue_body(created + '\n## 9. Decision Log\n')
check(not same(contract, contract + '  '), 'trailing spaces are specification text')
check(same(contract, contract + '\n\n'), 'trailing line breaks are not a specification change')
check(raw == created + '\n## 9. Decision Log' and 'undecidable' in stderr.getvalue(),
      'duplicated heading keeps the body verbatim and says why')

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
    f.cycle(roots=['new defect'], seconds=1801, satisfied=['criterion-one'])
    f.fix()
    f.cycle(roots=['another defect'], seconds=1801, satisfied=['criterion-one', 'criterion-two'])
    check(f.decision() == 'continue' and len(f.state()['review_run']['replans']) == 2,
          'finite replan allowance and elapsed time alone never stop')
    f.fix()
    f.cycle(roots=(), seconds=1801, satisfied=('criterion-one', 'criterion-two', 'criterion-three'))
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
    f.cycle(satisfied=['criterion-one'])
    f.fix()
    f.cycle(satisfied=['criterion-one'])
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


# --- Breaker-stopped runs: the way out, and the one bounded way back in. ---


def diverge(fixture):
    """Drive a run to circuit-breaker:divergence with its HEAD on the frozen cycle."""
    fixture.cycle(roots=['input defect'])
    fixture.fix()
    fixture.cycle(roots=('input defect', 'second defect'))
    fixture.fix()
    fixture.cycle(roots=('input defect', 'second defect', 'third defect'), seconds=1801)
    check(fixture.state()['stop_reason'] == 'circuit-breaker:divergence', 'fixture reached divergence stop')


def retry(fixture, ok=True):
    return fixture.flow('review-retry', '--plan', fixture.plan_path, '--issue', fixture.issue_path, ok=ok)


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
    f.cycle(seconds=1801, satisfied=['criterion-one'])
    f.fix()
    f.cycle(roots=(), seconds=1801, satisfied=('criterion-one', 'criterion-two'))
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
        'if printf "%s" "$*" | grep -q headRefOid; then\n'
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

# A human attestation of unverified acceptance criteria is the ready / merge
# helper's own rewrite of the observed receipt; the run must still advance.
def attest(f, ids):
    stub = f.root / 'bin'
    if not stub.exists():
        stub.mkdir()
        (stub / 'gh').write_text(
            '#!/bin/bash\n'
            'ROOT=' + json.dumps(str(f.root)) + '\n'
            'if printf "%s" "$*" | grep -q headRefOid; then\n'
            '  git -C "$ROOT" rev-parse HEAD\n'
            '  exit 0\n'
            'fi\n'
            'exit 1\n')
        os.chmod(stub / 'gh', 0o755)
    env = dict(f.env, PATH=str(stub) + os.pathsep + f.env.get('PATH', ''))
    result = subprocess.run(
        ['bash', str(plugin / 'hooks/scripts/ready-reviewed-head-gate.sh'),
         '--pr', '71', '--repo', 'B16B1RD/cc-rite-workflow', '--plugin-root', str(plugin),
         '--results-dir', str(f.root / '.rite/review-results'), '--state-root', str(f.root),
         '--attest', ids],
        cwd=f.root, env=env, text=True, capture_output=True)
    check(result.returncode == 0 and 'REVIEWED_AC=attested' in result.stderr,
          'ready helper attests ' + ids + '\n' + result.stderr)


def attested_receipt(f, unverified=['AC-1'], roots=(), severities=None, triage=False):
    f.start()
    f.finish(list(roots), satisfied=['AC-4'], unverified=list(unverified), severities=severities)
    f.clock()
    f.observe()
    path = Path(f.state()['review_cycle']['result_path'])
    if triage:
        f.run(['bash', str(plugin / 'scripts/review-findings-maps.sh'), '--review-source', 'local_file',
               '--review-source-path', str(path)])
    before = json.loads(path.read_text())
    f.reject(lambda: f.flow('review-close', ok=False), 'unattested unverified criterion prevents completion')
    attest(f, ','.join(unverified))
    after = json.loads(path.read_text())
    rows = {row['id']: row for row in before['acceptance_criteria']}
    for row in after['acceptance_criteria']:
        if row['id'] in unverified:
            check(row['status'] == 'human-verified' and row['head'] == after['commit_sha']
                  and {k: v for k, v in row.items() if k not in ('status', 'head', 'at')}
                  == {k: v for k, v in rows[row['id']].items() if k != 'status'},
                  'attest changes only status, head and at of ' + row['id'])
        else:
            check(row == rows[row['id']], 'attest leaves ' + row['id'] + ' untouched')
    check({k: v for k, v in after.items() if k != 'acceptance_criteria'}
          == {k: v for k, v in before.items() if k != 'acceptance_criteria'},
          'attest leaves the rest of the receipt untouched')
    return path, after


f = Fixture()
try:
    path, receipt = attested_receipt(f)
    for label, tamper in (
            ('audit log added after attest', lambda r: r['guardrail_audit_log'].append(dict(note='late'))),
            ('satisfied criterion evidence changed', lambda r: r['acceptance_criteria'][0].update(evidence='edited')),
            ('attested criterion evidence changed', lambda r: r['acceptance_criteria'][1].update(evidence='edited')),
            ('attested criterion gains an unknown key', lambda r: r['acceptance_criteria'][1].update(note='extra')),
            ('attestation for another HEAD', lambda r: r['acceptance_criteria'][1].update(head='0' * 40)),
            ('unverified criterion rewritten as satisfied',
             lambda r: r['acceptance_criteria'][1].update(status='satisfied')),
            ('satisfied criterion rewritten as attested',
             lambda r: r['acceptance_criteria'][0].update(status='human-verified', head=r['commit_sha'],
                                                          at='2026-01-01T00:00:00Z'))):
        changed = copy.deepcopy(receipt)
        tamper(changed)
        dump(path, changed)
        f.reject(lambda: f.flow('set', '--phase', 'ready', '--next', 'merge', ok=False),
                 'attested receipt rejects ' + label)
    dump(path, receipt)
    before = f.state_path.read_bytes()
    f.observe(ok=False)
    check(f.state_path.read_bytes() == before, 'observation replay after attest adds no observation')
    f.flow('set', '--phase', 'ready', '--next', 'merge')
    check(f.state()['phase'] == 'ready', 'attested unverified criterion permits ready')
    f.flow('review-close')
    check(f.state()['review_run'].get('completed_context') == f.context(),
          'attested unverified criterion permits completion')
    f.flow('set', '--phase', 'init', '--next', 'next', '--issue', 43, '--pr', 0)
    check(f.state()['issue_number'] == 43, 'attested run releases the session to the next Issue')
finally:
    f.close()

f = Fixture()
try:
    path, receipt = attested_receipt(f, roots=['advisory defect'], severities=['MEDIUM'], triage=True)
    check(not receipt['findings'], 'triage moved the advisory finding before attest')
    f.flow('set', '--phase', 'ready', '--next', 'merge')
    f.flow('review-close')
    check(f.state()['review_run'].get('completed_context') == f.context(),
          'attest over a triaged receipt permits ready and completion')
finally:
    f.close()

# T-22 / T-23 / T-24: cleanup deletes the saved receipt after the review has
# ended. Leaving the PR must not depend on that file when the run is closed,
# deferred or stopped, and must still depend on it when the run is none of those.
def drop_receipt(fixture):
    path = Path(fixture.state()['review_run']['observations'][-1]['result_path'])
    path.unlink()
    check(not path.exists(), 'fixture deleted the observed receipt')
    return path


def leave(fixture, ok=True):
    fixture.flow('set', '--phase', 'cleanup', '--next', 'cleanup', '--active', 'false')
    return fixture.flow('set', '--phase', 'init', '--next', 'branch', '--issue', 43,
                        '--branch', 'chore/issue-43', '--pr', 0, '--active', 'true', ok=ok)


for marker in ('review-close', 'review-defer'):
    f = Fixture()
    try:
        f.cycle(roots=[])
        f.flow(marker)
        ended_run = f.state()['review_run']
        drop_receipt(f)
        leave(f)
        state = f.state()
        check(state['issue_number'] == 43 and 'review_run' not in state and state.get('cycle_count', 0) == 0
              and archived_run(state) == ended_run,
              'T-22 (AC-1): a run ended by ' + marker + ' releases the session after cleanup deleted its receipt')
    finally:
        f.close()

f = Fixture()
try:
    f.cycle()
    missing = drop_receipt(f)
    result = leave(f, ok=False)
    check(result.returncode != 0 and str(missing) in result.stderr
          and 'requires completed or deferred review' not in result.stderr,
          'T-23 (AC-2): an unended run still re-reads its receipt when leaving the PR\n' + result.stderr)
    check(f.state()['issue_number'] == 42, 'T-23 (AC-2): the refused switch keeps the current Issue')
finally:
    f.close()

f = Fixture()
try:
    diverge(f)
    stopped_run = f.state()['review_run']
    drop_receipt(f)
    f.flow('set', '--phase', 'init', '--next', 'branch', '--issue', 43, '--branch', 'chore/issue-43', '--pr', 0)
    archived = archived_run(f.state())
    check(f.state()['issue_number'] == 43 and archived == stopped_run
          and archived['status'] == 'stopped' and archived['stop_reason'] == 'circuit-breaker:divergence',
          'T-24 (AC-3): a stopped run releases the session without its receipt and keeps its stop')
finally:
    f.close()

print('PASS: review stagnation: ' + str(checks) + ' assertions; real clocks, receipts, repairs and retained stops')
PYTEST
