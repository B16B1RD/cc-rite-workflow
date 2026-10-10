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


WORK_MEMORY = ('## 📜 rite 作業メモリ\n\n- **Issue**: #42\n\n'
               '### レビュー対応履歴\n<!-- レビュー対応時に自動記録 -->\n- **現在のループ回数**: 1\n\n'
               '### 次のステップ\n1. review\n')


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
        self.work_memory_stub()
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

    def work_memory_stub(self):
        """One Issue work memory comment behind a gh stub; review-close reads and appends to it."""
        self.wm_body = self.private / 'wm-comment.md'
        self.wm_log = self.private / 'wm-calls.log'
        self.wm_fail = self.private / 'wm-fail'
        self.wm_body.write_text(WORK_MEMORY, encoding='utf-8')
        stub = self.private / 'wm-bin'
        stub.mkdir()
        (stub / 'gh').symlink_to(plugin / 'hooks/tests/_work-memory-gh-stub.sh')
        self.env.update(PATH=str(stub) + os.pathsep + self.env['PATH'], RITE_TEST_WM_BODY=str(self.wm_body),
                        RITE_TEST_WM_LOG=str(self.wm_log), RITE_TEST_WM_FAIL=str(self.wm_fail),
                        RITE_TEST_BASE_REF='develop')

    def wm_calls(self, kind):
        calls = self.wm_log.read_text().splitlines() if self.wm_log.exists() else []
        return [call for call in calls if kind in call]

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

    def finish(self, roots=None, satisfied=(), non_blocking=False, severities=None, unverified=(), unmet=(),
               recommendations=None, skipped='no_ac_section'):
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
                # Lower severities stay advisory only as class B, as the class gate would record.
                if severity not in ('CRITICAL', 'HIGH'):
                    finding['consequence_class'] = 'B'
        notes = [dict(id='F-99', reviewer='code-quality-reviewer', severity='LOW', scope='nit-noted',
                      status='open', file='source.txt', line=1, description='Informational note', suggestion='consider')] if non_blocking else []
        table = [dict(id=criterion, status='satisfied', evidence='measured fixture => pass', finding_id=None)
                 for criterion in satisfied] + [
                 dict(id=criterion, status='unverified', evidence='needs a human check', finding_id=None)
                 for criterion in unverified] + [
                 dict(id=criterion, status='unmet', evidence='measured fixture => fail', finding_id='F-01')
                 for criterion in unmet]
        dump(content, dict(schema_version='1.1.0', pr_number=context['pr_number'], review_context=context,
                           timestamp='__RITE_TS_PLACEHOLDER_7f3a9b2c__', commit_sha=context['commit_sha'],
                           reviewers=['code-quality-reviewer'], findings=findings, non_blocking_findings=notes,
                           guardrail_audit_log=[], acceptance_criteria=table or dict(skipped=skipped)))
        if recommendations is not None:
            (self.root / '.rite/state').mkdir(parents=True, exist_ok=True)
            dump(self.root / '.rite/state' / ('pr-recommendations-%s.json' % context['pr_number']),
                 dict(commit_sha=context['commit_sha'], recommendations=recommendations))
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

    def reject(self, operation, label, reason=None):
        before = self.state_path.read_bytes()
        result = operation()
        check(result.returncode != 0 and 'ERROR:' in result.stderr
              and (reason is None or reason in result.stderr), label)
        check(self.state_path.read_bytes() == before, label + ': last state retained')


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



iterate = (plugin / 'skills/iterate/SKILL.md').read_text()
