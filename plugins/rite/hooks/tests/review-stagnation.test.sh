#!/usr/bin/env bash
# Real review receipts, explicit clocks and verified repairs in isolated repositories.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 - "$SCRIPT_DIR/../.." <<'PYTEST'
import copy
import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

plugin = Path(sys.argv[1]).resolve()
checks = 0


def check(value, label):
    global checks
    assert value, label
    checks += 1


def dump(path, value):
    path.write_text(json.dumps(value), encoding='utf-8')


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

    def finish(self, roots=None, satisfied=(), non_blocking=False, severities=None):
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
        dump(content, dict(schema_version='1.1.0', pr_number=71, review_context=context,
                           timestamp='__RITE_TS_PLACEHOLDER_7f3a9b2c__', commit_sha=context['commit_sha'],
                           reviewers=['code-quality-reviewer'], findings=findings, non_blocking_findings=notes,
                           guardrail_audit_log=[], acceptance_criteria=[
                               dict(id=criterion, status='satisfied', evidence='measured fixture => pass', finding_id=None)
                               for criterion in satisfied]))
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
          and state['review_run_history'] == [old_run], 'completed ownership starts new Issue with clean cycle and archived history')
    f.flow('set', '--phase', 'pr', '--next', 'review', '--pr', 72)
    f.start()
    check(f.context()['run_id'] != old_run['run_id'] and f.state()['review_run_history'] == [old_run],
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

print('PASS: review stagnation: ' + str(checks) + ' assertions; real clocks, receipts, repairs and retained stops')
PYTEST
