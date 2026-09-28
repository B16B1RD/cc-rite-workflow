#!/usr/bin/env bash
# The adoption gate turns helper decisions into file / record / hold and saves every hold.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 - "$SCRIPT_DIR/../.." <<'PYTEST'
import atexit
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile

plugin = Path(sys.argv[1]).resolve()
gate = plugin / 'hooks/scripts/review-adoption-gate.sh'
checks = 0


def check(condition, message):
    global checks
    assert condition, message
    checks += 1


def git(repo, *args):
    return subprocess.run(['git', '-C', str(repo), *args], check=True, capture_output=True, text=True).stdout


work = Path(tempfile.mkdtemp())
atexit.register(shutil.rmtree, work)
repo = work / 'repo'
repo.mkdir()
git(repo, 'init', '-q')
git(repo, 'config', 'user.email', 't@example.com')
git(repo, 'config', 'user.name', 't')
(repo / 'tool.sh').write_text('#!/bin/bash\n[ -n "$1" ] || exit 1\necho "ok: $1"\n')
git(repo, 'add', '-A')
git(repo, 'commit', '-qm', 'base')
base = git(repo, 'rev-parse', 'HEAD').strip()
(repo / 'tool.sh').write_text('#!/bin/bash\necho "ok: $1"\n')
git(repo, 'commit', '-qam', 'head')
head = git(repo, 'rev-parse', 'HEAD').strip()

state = work / 'state'
issue_body = work / 'issue.md'
issue_body.write_text('## 受入条件\n\n- [ ] AC-1: tool rejects an empty NAME\n')
pr_body = work / 'pr.md'
pr_body.write_text('## Summary\n\n- keeps the guard\n')
ledger = work / 'ledger.md'
ledger.write_text('')
review = work / 'review.json'
review.write_text(json.dumps({'commit_sha': head, 'findings': [], 'non_blocking_findings': []}))
candidates = work / 'candidates.json'
adoption = state / '.rite/state/adoption-5-sweep.json'
hold_file = state / '.rite/state/adoption-hold-5-sweep.json'

bin_dir = work / 'bin'
bin_dir.mkdir()
(bin_dir / 'gh').write_text(
    '#!/bin/bash\nprintf \'%s\\n\' "$*" >> "$GH_LOG"\n'
    'case ",$GH_STATES," in *",$3=OPEN,"*) echo OPEN ;; *",$3=CLOSED,"*) echo CLOSED ;;'
    ' *) echo "could not resolve" >&2; exit 1 ;; esac\n')
(bin_dir / 'gh').chmod(0o755)
gh_log = work / 'gh.log'
env = dict(os.environ, PATH=f'{bin_dir}:{os.environ["PATH"]}', GH_LOG=str(gh_log), GH_STATES='7=OPEN')

CANDS = [{'id': 'F-01', 'severity': 'LOW', 'description': 'empty NAME passes', 'file': 'tool.sh', 'line': 2},
         {'id': 'F-02', 'severity': 'MEDIUM', 'description': 'usage text is stale', 'file': 'tool.sh', 'line': 3}]


def rec(ids=['F-01'], **fields):
    record = {'ids': list(ids), 'V': True, 'C': False, 'T': False, 'contract': {'ref': 'AC-1'},
              'evidence': 'tool "" prints ok: and exits 0', 'origin': 'pre_existing', 'present': True,
              'tracker': None, 'prior': None, 'reason': '', 'proposition': None,
              'acceptance': 'Given an empty NAME, When tool runs, Then it exits 1'}
    record.update(fields)
    return record


REJECT = dict(V=False, contract=None, evidence='', reason='the guard is documented / reconsider when usage changes')
unknown = dict(V='unknown', contract=None, evidence='', reason='not reproduced yet')


def run(records, cands=CANDS, kind='sweep', write=True, at=None, context=None, with_pr_body=True):
    candidates.write_text(json.dumps({'candidates': cands}))
    adoption.parent.mkdir(parents=True, exist_ok=True)
    path = state / f'.rite/state/adoption-5-{kind}.json'
    if write:
        path.write_text(json.dumps({'adoption': {'head': (at or head), 'records': records}}))
    elif path.exists():
        path.unlink()
    gh_log.write_text('')
    reviewed = review if at is None else work / f'review-{at}.json'
    if at is not None:
        reviewed.write_text(json.dumps({'commit_sha': at, 'findings': [], 'non_blocking_findings': []}))
    before = candidates.read_bytes(), review.read_bytes(), (path.read_bytes() if path.exists() else None)
    result = subprocess.run(
        ['bash', str(gate), '--pr', '5', '--kind', kind, '--state-root', str(state),
         '--candidates', str(candidates), '--review-result', str(reviewed), '--base', base,
         '--issue-body', str(issue_body), *(['--pr-body', str(pr_body)] if with_pr_body else []), '--ac-ids', 'AC-1',
         '--repo-root', str(repo), *(['--ledger', str(ledger)] if context is None else context)],
        capture_output=True, text=True, env=env, timeout=60)
    after = candidates.read_bytes(), review.read_bytes(), (path.read_bytes() if path.exists() else None)
    check(before == after, 'the gate changed an input')
    return result


def decided(records, **kwargs):
    result = run(records, **kwargs)
    check(result.returncode == 0, f'expected decided: {result.stdout}{result.stderr}')
    return {','.join(v['ids']): v for v in json.loads(result.stdout)['verdicts']}, result


def held(records, reason, **kwargs):
    result = run(records, **kwargs)
    check(result.returncode == 3, f'expected held {reason}: {result.stdout}{result.stderr}')
    out = json.loads(result.stdout)
    check(out == {'held': True, 'reason': reason, 'hold_file': str(hold_file).replace('sweep', kwargs.get('kind', 'sweep'))},
          out)
    marker = [l for l in result.stderr.splitlines() if l.startswith('[CONTEXT] ADOPTION_GATE=')]
    check(len(marker) == 1 and f'ADOPTION_GATE=held; kind={kwargs.get("kind", "sweep")}; reason={reason};' in marker[0],
          result.stderr)
    return json.loads(Path(out['hold_file']).read_text()), result


# No record file: every candidate is held with its full text, the source, the commit and the resume position.
saved, _ = held([], 'no_records', write=False)
check(saved['held_ids'] == ['F-01', 'F-02'] and saved['candidates'] == CANDS, saved)
check((saved['kind'], saved['pr'], saved['head'], saved['review_result']) == ('sweep', 5, head, str(review)), saved)
check('/rite:iterate 5' in saved['resume'] and '判定記録' in saved['resume'] and 'adoption-5-sweep.json' in saved['resume'],
      saved['resume'])
for kind, command in (('triage', '/rite:iterate 5'), ('followup', '/rite:cleanup 5')):
    other, _ = held([], 'no_records', kind=kind, write=False)
    check(command in other['resume'] and other['kind'] == kind, other)

# A pre-existing verified defect with an acceptance criterion is the only verdict that may be filed.
verdicts, result = decided([rec(), rec(['F-02'], **REJECT)])
check(verdicts['F-01']['verdict'] == 'file' and verdicts['F-01']['record']['acceptance'], verdicts)
check(verdicts['F-02']['verdict'] == 'record' and verdicts['F-02']['exit'] == 'REJECT', verdicts)
check('[CONTEXT] ADOPTION_GATE=decided; kind=sweep; file=1; record=1; pr=5' in result.stderr, result.stderr)
check(not hold_file.exists(), 'a decided run must remove the stale hold file')

# Filing without an acceptance criterion is held, not filed; the hold keeps every candidate of the run.
saved, _ = held([rec(acceptance=''), rec(['F-02'], **REJECT)], 'undecided')
check(saved['held_ids'] == ['F-01'] and saved['candidates'] == CANDS, saved)
check('acceptance' in saved['detail'], saved['detail'])

# A held run writes nothing, so the candidates decided as file or record are saved in the hold as well.
THREE = CANDS + [{'id': 'F-03', 'severity': 'LOW', 'description': 'no shebang check', 'file': 'tool.sh', 'line': 1}]
saved, _ = held([rec(['F-01'], **REJECT), rec(['F-02']), rec(['F-03'], **unknown)], 'undecided', cands=THREE)
check(saved['held_ids'] == ['F-03'] and saved['candidates'] == THREE, saved)
# A same-commit rerun without the candidate decided as file keeps it in the hold with its full text.
saved, _ = held([rec(['F-01'], **REJECT), rec(['F-03'], **unknown)], 'held_candidates_dropped', cands=[THREE[0], THREE[2]])
check(THREE[1] in saved['candidates'] and 'F-02' in saved['held_ids'], saved)
check('作り直して' in saved['resume'] and '戻して' not in saved['resume'], saved['resume'])
hold_file.unlink()

# RESOLVED and a pre-existing LINK record the disposition; a PR-origin LINK stays blocking and is held.
resolved = dict(present=False, evidence='the guard is back at HEAD')
verdicts, _ = decided([rec(**resolved), rec(['F-02'], tracker=7)])
check(verdicts['F-01']['verdict'] == 'record' and verdicts['F-01']['exit'] == 'RESOLVED', verdicts)
check(verdicts['F-02']['verdict'] == 'record' and verdicts['F-02']['exit'] == 'LINK', verdicts)
removed = {'diff': ['tool.sh:-2'], 'path': 'removing the guard lets an empty NAME through'}
saved, _ = held([rec(origin='pr', origin_cause=removed, tracker=7), rec(['F-02'], **REJECT)], 'undecided')
check(saved['held_ids'] == ['F-01'], saved)

# PR-origin and unknown-origin adoptions keep the PR open: held, never filed or recorded.
for fields in ({'origin': 'pr', 'origin_cause': removed}, {'origin': 'unknown'}):
    saved, _ = held([rec(**fields), rec(['F-02'], **REJECT)], 'undecided')
    check(saved['held_ids'] == ['F-01'], (fields, saved))

# DIAGNOSE: held unless accepted as an investigation, which is filed with its acceptance criterion.
proposition = {'claim': 'an empty NAME passes', 'reach': 'tool ""', 'reach_source': 'tool.sh:2', 'done': 'exit code observed'}
held([rec(**unknown), rec(['F-02'], **REJECT)], 'undecided')
held([rec(origin='pr', origin_cause=removed, proposition=proposition, investigate=True, **unknown),
      rec(['F-02'], **REJECT)], 'undecided')
verdicts, _ = decided([rec(proposition=proposition, investigate=True, **unknown), rec(['F-02'], **REJECT)])
check(verdicts['F-01']['verdict'] == 'file' and verdicts['F-01']['action'] == 'investigate', verdicts)

# A helper ERROR holds every candidate and names the helper's reason.
saved, _ = held([rec()], 'adoption_error')
check(saved['held_ids'] == ['F-01', 'F-02'] and 'candidates_uncovered' in saved['detail'], saved)

# Rerunning after the records are fixed decides and removes the hold left by the previous run.
held([rec(**unknown), rec(['F-02'], **REJECT)], 'undecided')
check(hold_file.exists(), 'the hold must persist until the rerun')
decided([rec(), rec(['F-02'], **REJECT)])
check(not hold_file.exists(), 'the rerun must clear the hold')

# Severity never changes a verdict.
first, _ = decided([rec(), rec(['F-02'], **REJECT)])
second, _ = decided([rec(), rec(['F-02'], **REJECT)], cands=[dict(c, severity='CRITICAL') for c in CANDS])
check(first == second, (first, second))

# All contexts are injected, so gh is reached only for the tracker state.
decided([rec(), rec(['F-02'], **REJECT)])
check(gh_log.read_text() == '', gh_log.read_text())
decided([rec(), rec(['F-02'], tracker=7)])
check(gh_log.read_text().splitlines() == ['issue view 7 --json state --jq .state'], gh_log.read_text())

# The resume names the way out of each held reason and is printed in the WARNING as well.
saved, result = held([rec(origin='pr', origin_cause=removed), rec(['F-02'], **REJECT)], 'undecided')
check('コードを直して push し /rite:iterate 5 で再レビュー' in saved['resume'] and '判定記録' not in saved['resume'],
      saved['resume'])
check(saved['resume'] in result.stderr, result.stderr)
saved, _ = held([rec(origin='pr', origin_cause=removed), rec(['F-02'], **unknown)], 'undecided')
check('コードを直して push し' in saved['resume'] and '判定記録' in saved['resume'], saved['resume'])
saved, _ = held([rec(origin='pr', origin_cause=removed), rec(['F-02'], **REJECT)], 'undecided', kind='followup')
check('人間に報告' in saved['resume'] and 'PM' not in saved['resume'] and 'push' not in saved['resume'], saved['resume'])
decided([rec(), rec(['F-02'], **REJECT)])

# A context that cannot be read is held without touching the records; the callee's diagnostic is kept.
saved, result = held([rec(), rec(['F-02'], **REJECT)], 'context_unavailable', context=[])
check('owner/repo' in saved['detail'] and 'could not resolve' in saved['detail'], saved['detail'])
check('could not resolve' in result.stderr and '判定記録は直さない' in saved['resume'], (result.stderr, saved['resume']))
check('adoption-5-sweep.json' not in saved['resume'], saved['resume'])
saved, result = held([rec(), rec(['F-02'], **REJECT)], 'context_unavailable', context=['--owner-repo', 'o/r'])
check('却下台帳の記録コメント' in saved['detail'] and 'ERROR' in saved['detail'], saved['detail'])
check('NONBLOCKING_RECORD_BODY=failed' in result.stderr, result.stderr)
saved, result = held([rec(), rec(['F-02'], **REJECT)], 'context_unavailable', with_pr_body=False,
                     context=['--owner-repo', 'o/r', '--ledger', str(ledger)])
check('PR 本文' in saved['detail'] and 'could not resolve' in saved['detail'], saved['detail'])
check('could not resolve' in result.stderr.splitlines(), result.stderr)
decided([rec(), rec(['F-02'], **REJECT)])

# Triage renumbers ids on a rerun. A candidate held on the same commit that the rerun no longer
# carries is held again with its full text instead of being dropped.
triage_hold = state / '.rite/state/adoption-hold-5-triage.json'
triage_hold.unlink(missing_ok=True)
first = [dict(CANDS[0], id='C-1'), dict(CANDS[1], id='C-2')]
held([], 'no_records', kind='triage', cands=first, write=False)
saved, result = held([rec(['C-1'], **REJECT)], 'held_candidates_dropped', kind='triage', cands=[dict(CANDS[1], id='C-1')])
check(saved['held_ids'] == ['C-1', 'held-C-1'], saved)
check({k: v for k, v in saved['candidates'][1].items() if k != 'id'} == {k: v for k, v in CANDS[0].items() if k != 'id'},
      saved['candidates'])
check('1 件' in saved['detail'] and 'C-1' in saved['detail'] and '候補へ戻して' in saved['resume'], saved)
check(saved['resume'] in result.stderr, result.stderr)
# Putting the dropped candidate back with its full text under a new id decides and clears the hold.
decided([rec(['C-1'], **REJECT), rec(['C-2'])], kind='triage', cands=[dict(CANDS[1], id='C-1'), dict(CANDS[0], id='C-2')])
check(not triage_hold.exists(), 'the decided rerun must clear the triage hold')
# Triage candidates live nowhere else, so a new commit is still compared against the previous hold.
held([], 'no_records', kind='triage', cands=first, write=False)
(repo / 'notes.md').write_text('moved on\n')
git(repo, 'add', '-A')
git(repo, 'commit', '-qm', 'next')
next_head = git(repo, 'rev-parse', 'HEAD').strip()
saved, _ = held([rec(['C-1'], **REJECT)], 'held_candidates_dropped', kind='triage', cands=[dict(CANDS[1], id='C-1')],
                at=next_head)
check(saved['head'] == next_head and saved['held_ids'] == ['C-1', 'held-C-1'], saved)
check({k: v for k, v in saved['candidates'][1].items() if k != 'id'} == {k: v for k, v in CANDS[0].items() if k != 'id'},
      saved['candidates'])
check('候補へ戻して' in saved['resume'] and '作り直して' not in saved['resume'], saved['resume'])
decided([rec(['C-1'], **REJECT), rec(['C-2'], **REJECT)], kind='triage',
        cands=[dict(CANDS[1], id='C-1'), dict(CANDS[0], id='C-2')], at=next_head)
check(not triage_hold.exists(), 'the decided run on the new commit must clear the triage hold')
# Sweep rebuilds its candidates from the review results: a run on a new commit with no candidate
# decides and retires the previous hold.
held([], 'no_records', write=False)
verdicts, _ = decided([], cands=[], write=False, at=next_head)
check(verdicts == {} and not hold_file.exists(), 'a decided sweep run on a new commit must clear the sweep hold')
# No candidate at all: nothing to judge, unless the triage hold still has candidates.
verdicts, _ = decided([], kind='triage', cands=[], write=False)
check(verdicts == {}, verdicts)
held([], 'no_records', kind='triage', cands=first, write=False)
saved, _ = held([], 'held_candidates_dropped', kind='triage', cands=[], write=False)
check(saved['held_ids'] == ['C-1', 'C-2'], saved)
triage_hold.unlink()

# A hold that cannot be saved or a previous hold that cannot be read stops the gate without writing.
blocked = work / 'blocked'
(blocked / '.rite').mkdir(parents=True)
(blocked / '.rite/state').write_text('')
candidates.write_text(json.dumps({'candidates': CANDS}))
result = subprocess.run(
    ['bash', str(gate), '--pr', '5', '--kind', 'sweep', '--state-root', str(blocked), '--candidates', str(candidates),
     '--review-result', str(review), '--base', base, '--issue-body', str(issue_body), '--pr-body', str(pr_body),
     '--ac-ids', 'AC-1', '--ledger', str(ledger)],
    capture_output=True, text=True, env=env, timeout=60)
check(result.returncode == 1 and result.stdout == '', (result.returncode, result.stdout))
check('ADOPTION_GATE=error; kind=sweep; reason=hold_write_failed; pr=5' in result.stderr, result.stderr)
hold_file.unlink(missing_ok=True)
tmp_slot = Path(f'{hold_file}.tmp')
tmp_slot.mkdir()
result = run([], write=False)
tmp_slot.rmdir()
check(result.returncode == 1 and result.stdout == '', (result.returncode, result.stdout))
check('ADOPTION_GATE=error; kind=sweep; reason=hold_write_failed' in result.stderr, result.stderr)
check(not hold_file.exists(), 'a failed save must not leave a hold file')
hold_file.write_text('{"head": ')
result = run([rec(), rec(['F-02'], **REJECT)])
check(result.returncode == 1 and result.stdout == '', (result.returncode, result.stdout))
check('ADOPTION_GATE=error; kind=sweep; reason=hold_unreadable' in result.stderr, result.stderr)
check(hold_file.read_text() == '{"head": ', 'an unreadable hold must be kept')
hold_file.unlink()

print(f'review-adoption-gate: {checks} checks passed')
PYTEST
