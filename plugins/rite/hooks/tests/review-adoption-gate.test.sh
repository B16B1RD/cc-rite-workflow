#!/usr/bin/env bash
# The adoption gate turns helper decisions into file / record / fix / hold and saves every hold.
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


def run(records, cands=CANDS, kind='sweep', write=True, at=None, context=None, with_pr_body=True, pr=5, issue=None, fix_loop=None):
    candidates.write_text(json.dumps({'candidates': cands}))
    adoption.parent.mkdir(parents=True, exist_ok=True)
    path = state / f'.rite/state/adoption-{pr}-{kind}.json'
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
        ['bash', str(gate), '--pr', str(pr), '--kind', kind, '--state-root', str(state),
         '--candidates', str(candidates), '--review-result', str(reviewed), '--base', base,
         '--issue-body', str(issue_body), *(['--pr-body', str(pr_body)] if with_pr_body else []), '--ac-ids', 'AC-1',
         '--repo-root', str(repo), *(['--issue', str(issue)] if issue is not None else []),
         *(['--ledger', str(ledger)] if context is None else context),
         *(['--fix-loop', fix_loop] if fix_loop else [])],
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
    expected_hold = state / f'.rite/state/adoption-hold-{kwargs.get("pr", 5)}-{kwargs.get("kind", "sweep")}.json'
    check({k: v for k, v in out.items() if k != 'verdicts'} == {'held': True, 'reason': reason, 'hold_file': str(expected_hold)},
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
# A decided sweep run keeps the hold: the caller removes it after its external writes.
check(hold_file.exists(), 'a decided sweep run keeps the hold for the caller to release')
hold_file.unlink()

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
check('候補へ戻して' in saved['resume'] and 'nb-sweep-collect.sh' in saved['resume'], saved['resume'])
hold_file.unlink()

# RESOLVED and a pre-existing LINK record the disposition; a PR-origin LINK stays blocking and is held.
resolved = dict(present=False, evidence='the guard is back at HEAD')
verdicts, _ = decided([rec(**resolved), rec(['F-02'], tracker=7)])
check(verdicts['F-01']['verdict'] == 'record' and verdicts['F-01']['exit'] == 'RESOLVED', verdicts)
check(verdicts['F-02']['verdict'] == 'record' and verdicts['F-02']['exit'] == 'LINK', verdicts)
removed = {'diff': ['tool.sh:-2'], 'path': 'removing the guard lets an empty NAME through'}
saved, _ = held([rec(origin='pr', origin_cause=removed, tracker=7), rec(['F-02'], **REJECT)], 'undecided')
check(saved['held_ids'] == ['F-01'], saved)
hold_file.unlink()
# After the merge the OPEN tracker takes a PR-origin or unknown-origin root cause: a followup LINK
# is recorded (never filed, never held); a CLOSED tracker is not a LINK and stays held.
for fields in ({'origin': 'pr', 'origin_cause': removed}, {'origin': 'unknown'}):
    verdicts, result = decided([rec(tracker=7, **fields), rec(['F-02'], **REJECT)], kind='followup')
    check((verdicts['F-01']['verdict'], verdicts['F-01']['exit'], verdicts['F-01']['tracker'], verdicts['F-01']['pr_blocking'])
          == ('record', 'LINK', 7, True), (fields, verdicts))
    check('kind=followup; file=0; record=2' in result.stderr, result.stderr)
env['GH_STATES'] = '7=CLOSED'
held([rec(origin='pr', origin_cause=removed, tracker=7), rec(['F-02'], **REJECT)], 'undecided', kind='followup')
env['GH_STATES'] = '7=OPEN'
(state / '.rite/state/adoption-hold-5-followup.json').unlink()

# A triage PR-origin adoption is fixed in the same PR (verdict fix, nothing held) on a mergeable
# review inside /rite:iterate (--fix-loop yes) until the cycle reaches safety.max_review_cycles
# (default 15), where its fix could not be re-reviewed and it is held. At the stop on unverified
# acceptance criteria and in a standalone review (--fix-loop no, or no flag) nothing would read the
# registration: held.
# A sweep PR-origin adoption stays held. An unknown-origin adoption is held in triage as well.
plain_review = review.read_text()
for cycle, expected in ((3, 'fix'), (15, 'hold')):
    review.write_text(json.dumps({'commit_sha': head, 'review_context': {'cycle_count': cycle},
                                  'findings': [], 'non_blocking_findings': []}))
    records = [rec(origin='pr', origin_cause=removed), rec(['F-02'], **REJECT)]
    if expected == 'fix':
        verdicts, result = decided(records, kind='triage', fix_loop='yes')
        check((verdicts['F-01']['verdict'], verdicts['F-01']['action']) == ('fix', 'fix_in_pr'), verdicts)
        check(verdicts['F-02']['verdict'] == 'record', verdicts)
        (state / '.rite/state/adoption-hold-5-triage.json').unlink()
        for loop in (None, 'no'):
            saved, _ = held(records, 'undecided', kind='triage', fix_loop=loop)
            check(saved['held_ids'] == ['F-01'], (loop, saved))
            (state / '.rite/state/adoption-hold-5-triage.json').unlink()
    else:
        saved, _ = held(records, 'undecided', kind='triage', fix_loop='yes')
        check(saved['held_ids'] == ['F-01'], saved)
        check('コードを直して push し' in saved['resume'], saved['resume'])
        (state / '.rite/state/adoption-hold-5-triage.json').unlink()
    saved, _ = held(records, 'undecided', kind='sweep')
    check(saved['held_ids'] == ['F-01'], (cycle, saved))
    hold_file.unlink()
    saved, _ = held([rec(origin='unknown'), rec(['F-02'], **REJECT)], 'undecided', kind='triage')
    check(saved['held_ids'] == ['F-01'], (cycle, saved))
    (state / '.rite/state/adoption-hold-5-triage.json').unlink()
# Sweep uses the same fix-loop capacity as triage; the default stays held.
for cycle in (3, 15):
    review.write_text(json.dumps({'commit_sha': head, 'review_context': {'cycle_count': cycle},
                                  'findings': [], 'non_blocking_findings': []}))
    records = [rec(origin='pr', origin_cause=removed), rec(['F-02'], **REJECT)]
    if cycle == 3:
        verdicts, result = decided(records, kind='sweep', fix_loop='yes')
        check(verdicts['F-01']['verdict'] == 'fix' and verdicts['F-02']['verdict'] == 'record', verdicts)
    else:
        saved, result = held(records, 'undecided', kind='sweep', fix_loop='yes')
        check('cycle_cap' in saved['resume'] and '手作業' in saved['resume'], saved['resume'])
    hold_file.unlink(missing_ok=True)
# Mixed holds expose only evaluated FIX verdicts to the sweep caller.
review.write_text(json.dumps({'commit_sha': head, 'review_context': {'cycle_count': 3},
                              'findings': [], 'non_blocking_findings': []}))
saved, result = held([rec(origin='pr', origin_cause=removed),
                     rec(['F-02'], acceptance='')], 'undecided', kind='sweep', fix_loop='yes')
check(saved['held_ids'] == ['F-02'], saved)
check([v['verdict'] for v in json.loads(result.stdout)['verdicts']] == ['fix', 'hold'], result.stdout)
hold_file.unlink()
review.write_text(plain_review)

# A --fix-loop value other than yes / no (an unsubstituted placeholder) stops the gate: exit 2, no hold.
for bad in ('{fix_loop}', 'maybe'):
    result = run([rec(origin='pr', origin_cause=removed), rec(['F-02'], **REJECT)], kind='triage', fix_loop=bad)
    check(result.returncode == 2 and '--fix-loop must be yes or no' in result.stderr, (bad, result.returncode, result.stderr))
    check(not (state / '.rite/state/adoption-hold-5-triage.json').exists(), bad)
# Without a readable cycle the registration capacity is unknown: every candidate is held.
review.write_text(plain_review)
saved, _ = held([rec(origin='pr', origin_cause=removed), rec(['F-02'], **REJECT)], 'adoption_error', kind='triage', fix_loop='yes')
check('cycle_count' in saved['detail'], saved['detail'])
(state / '.rite/state/adoption-hold-5-triage.json').unlink()

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
check(hold_file.exists(), 'the decided rerun leaves the hold for the caller')
hold_file.unlink()

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
check(triage_hold.exists(), 'the decided triage rerun leaves the hold for the caller')
triage_hold.unlink()
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
check(triage_hold.exists(), 'the decided triage run on the new commit leaves the hold for the caller')
triage_hold.unlink()
# Sweep and followup keep their hold on any commit as well: a run on a new commit without the
# held candidates is held again, never retired.
held([], 'no_records', write=False)
saved, _ = held([], 'held_candidates_dropped', cands=[], write=False, at=next_head)
check(saved['head'] == next_head and saved['held_ids'] == ['F-01', 'F-02'], saved)
check('nb-sweep-collect.sh' in saved['resume'], saved['resume'])
# Carrying the held candidates under new ids and judging them on the new commit decides. The
# hold stays until the sweep's ledger record releases it, so a stop before then carries them again.
carried = [dict(c, id='5-20260101000000.json#' + c['id']) for c in CANDS]
verdicts, _ = decided([rec([carried[0]['id']], **resolved), rec([carried[1]['id']], **REJECT)], cands=carried, at=next_head)
check(verdicts[carried[0]['id']]['exit'] == 'RESOLVED' and verdicts[carried[1]['id']]['exit'] == 'REJECT', verdicts)
check(hold_file.exists(), 'the decided sweep run leaves the carried candidates in the hold until the caller releases it')
decided([rec([carried[0]['id']], **resolved), rec([carried[1]['id']], **REJECT)], cands=carried, at=next_head)
hold_file.unlink()
# A followup rebuilds its candidates, so its decided run removes the hold itself.
followup_hold = state / '.rite/state/adoption-hold-5-followup.json'
held([], 'no_records', kind='followup', write=False)
saved, _ = held([], 'held_candidates_dropped', kind='followup', cands=[], write=False, at=next_head)
check(saved['held_ids'] == ['F-01', 'F-02'] and 'follow-up' in saved['resume'], saved)
decided([rec(), rec(['F-02'], **REJECT)], kind='followup')
check(not followup_hold.exists(), 'a decided followup run removes its hold')
# Dropped candidates are renamed one by one, so a hold that already carries held- ids keeps them unique.
triage_hold.write_text(json.dumps({'kind': 'triage', 'pr': 5, 'head': head, 'review_result': str(review),
    'reason': 'no_records', 'detail': '', 'held_ids': ['C-1', 'held-C-1'], 'resume': 'r',
    'candidates': [dict(CANDS[0], id='C-1'), dict(CANDS[1], id='held-C-1')]}))
other = {'id': 'C-1', 'severity': 'LOW', 'description': 'another finding', 'file': 'tool.sh', 'line': 9}
saved, _ = held([], 'held_candidates_dropped', kind='triage', cands=[other], write=False)
check(saved['held_ids'] == ['C-1', 'held-C-1', 'held-held-C-1'] and len({c['id'] for c in saved['candidates']}) == 3, saved)
triage_hold.unlink()
# A REJECT recorded in the ledger under [reviewer, file_line] is reused as the prior of the same
# out-of-scope candidate in the next cycle; a contradicting judgement is arbitrated, not filed.
ledger.write_text('### 却下台帳\n\n| finding_id | file:line | 判定 | 判定文 | 出典 |\n|------------|-----------|------|--------|------|\n'
                  '| code-quality-reviewer | tool.sh:3 | REJECT | the usage text is intentional | 5-20260101000000.json |\n')
rec_c = {'id': 'C-1', 'source': '推奨', 'reviewer': 'code-quality-reviewer', 'file_line': 'tool.sh:3', 'severity': 'LOW',
         'content': 'usage text is stale'}
prior = {'finding_id': 'code-quality-reviewer', 'file_line': 'tool.sh:3', 'disposition': 'REJECT',
         'premise': 'the usage text is intentional'}
verdicts, _ = decided([rec(['C-1'], prior=prior, **REJECT)], kind='triage', cands=[rec_c])
check(verdicts['C-1']['exit'] == 'REJECT' and verdicts['C-1']['verdict'] == 'record', verdicts)
triage_hold.unlink(missing_ok=True)
saved, _ = held([rec(['C-1'], prior=prior)], 'undecided', kind='triage', cands=[rec_c])
check('RECONCILE' in saved['detail'], saved['detail'])
triage_hold.unlink()
ledger.write_text('')
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

# Cross-PR history comes from the gate itself and survives PR-specific cleanup.
history_path = state / '.rite/state/adoption-history-101-followup.json'
completed = rec(present=False, evidence='the empty NAME guard is restored')
decided([completed], cands=CANDS[:1], pr=101, issue=100, kind='followup')
history_before = history_path.read_bytes()
history = json.loads(history_before)
check((history['pr'], history['kind'], history['head']) == (101, 'followup', head), history)
check(history['entries'][0]['record'] == completed and history['entries'][0]['decision']['exit'] == 'RESOLVED', history)


def pending(record, pr=102, issue=100, reason='pending'):
    saved, _ = held([record], 'undecided', cands=CANDS[:1], pr=pr, issue=issue, kind='followup')
    check(len(saved['reconciliation']) == 1, saved)
    request = saved['reconciliation'][0]
    check(request['reason'] == reason and request['ids'] == ['F-01'], request)
    check(saved['held_ids'] == ['F-01'] and saved['candidates'] == CANDS[:1], saved)
    return request


def answer(request, trigger='recurrence', resolution='fix_implementation'):
    return {'fingerprint': request['fingerprint'], 'trigger': trigger, 'resolution': resolution,
            'premise': 'empty NAME is still rejected by the interface',
            'reason': 'the new caller reaches the same missing guard',
            'evidence': 'tool "" prints ok again', 'observations': ''}


request = pending(rec())
check(set(request['signals']) == {'contract_match', 'completed_contract'}, request)
check([h['source']['pr'] for h in request['history']] == [101], request)
adjudicated = rec(reconciliation=answer(request))
verdicts, _ = decided([adjudicated], cands=CANDS[:1], pr=102, issue=100, kind='followup')
check(verdicts['F-01']['exit'] == 'ADOPT' and verdicts['F-01']['verdict'] == 'file', verdicts)
repeated, _ = decided([adjudicated], cands=CANDS[:1], pr=102, issue=100, kind='followup')
check(repeated == verdicts, 'same-PR saved history must not invalidate its own answer')
saved_answer = json.loads((state / '.rite/state/adoption-history-102-followup.json').read_text())
check(saved_answer['entries'][0]['reconciliation'] == adjudicated['reconciliation'], saved_answer)
other_pr_files = {p: p.read_bytes() for p in (state / '.rite/state').glob('*102-*')}
purged = subprocess.run(['bash', str(plugin / 'hooks/scripts/cleanup-pr-state-purge.sh'), '--pr', '101',
                         '--state-root', str(state)], capture_output=True, text=True, env=env, timeout=30)
check(purged.returncode == 0 and 'PARTIAL_FAILURE' not in purged.stderr, purged.stderr)
check(history_path.read_bytes() == history_before, 'cleanup must preserve prior contract dispositions')
check(all(p.read_bytes() == content for p, content in other_pr_files.items()), 'cleanup touched another PR')
# Merely mentioning the same file does not match a different contract; AC text also belongs to an Issue.
verdicts, _ = decided([rec()], cands=CANDS[:1], pr=103, issue=999, kind='followup')
check(verdicts['F-01']['exit'] == 'ADOPT', verdicts)
# Updating only the matched history makes a previously accepted answer stale.
# PR 101 now also matches PR 102, so its parent explicitly disposes that request first.
prior_update = dict(completed, evidence='a second run confirms the restored guard')
prior_request = pending(prior_update, pr=101)
decided([dict(prior_update, reconciliation=answer(prior_request, 'none', 'normal'))], cands=CANDS[:1],
        pr=101, issue=100, kind='followup')
pending(adjudicated, reason='stale')
# A proposed contract change preserves the hold; the parent cannot authorize filing it.
fresh = pending(rec())
pending(rec(reconciliation=answer(fresh, resolution='change_contract')), reason='contract_change')
# "none" resumes ordinary V/C/T when there is no conflicting prior adoption.
for fields, expected in (({}, 'ADOPT'), ({'V': False, 'reason': 'the cited interface is satisfied'}, 'REJECT')):
    record = rec(**fields)
    fresh = pending(record)
    verdicts, _ = decided([dict(record, reconciliation=answer(fresh, 'none', 'normal'))], cands=CANDS[:1],
                          pr=102, issue=100, kind='followup')
    check(verdicts['F-01']['exit'] == expected, verdicts)

# File contracts match their cited text, not only their location or candidate filename.
# Isolate this family from AC fixtures while still creating every history via the gate.
state = work / 'file-contract-state'
adoption = state / '.rite/state/adoption-5-sweep.json'
contract = {'ref': 'tool.sh:2', 'text': 'echo "ok: $1"'}
decided([rec(contract=contract, **resolved)], cands=CANDS[:1], pr=201, kind='followup')
same = pending(rec(contract=contract), pr=202, issue=None)
check('contract_match' in same['signals'], same)
other = rec(contract={'ref': 'tool.sh:1', 'text': '#!/bin/bash'})
verdicts, _ = decided([other], cands=CANDS[:1], pr=203, kind='followup')
check(verdicts['F-01']['exit'] == 'ADOPT', 'same file with another contract must not request arbitration')
# A still-present adoption in another PR cannot be reversed into a rejection by consolidation.
unresolved = rec(contract=other['contract'], V=False, reason='the same defect is still present')
fresh = pending(unresolved, pr=205, issue=None)
reversal = dict(answer(fresh, 'reversal', 'consolidate'), observations='the new caller reaches the same defect')
pending(dict(unresolved, reconciliation=reversal), pr=205, issue=None, reason='unresolved_adoption')
# Consolidating the same adopted requirement onto an OPEN tracker records LINK.
tracked = dict(unresolved, tracker=7)
fresh = pending(tracked, pr=205, issue=None)
consolidation = dict(answer(fresh, 'reversal', 'consolidate'),
                     observations='the existing tracker owns the same requirement')
verdicts, _ = decided([dict(tracked, reconciliation=consolidation)], cands=CANDS[:1],
                      pr=205, issue=None, kind='followup')
check(verdicts['F-01']['exit'] == 'LINK' and verdicts['F-01']['verdict'] == 'record', verdicts)
persisted = json.loads((state / '.rite/state/adoption-history-205-followup.json').read_text())
check(persisted['entries'][0]['decision']['tracker'] == 7 and
      persisted['entries'][0]['reconciliation'] == consolidation, persisted)
# A merged PR cannot take the fix, so after arbitration a PR-origin LINK of a followup is still
# settled as a record under the OPEN tracker, without a hold.
tracked = dict(tracked, origin='pr', origin_cause=removed)
fresh = pending(tracked, pr=206, issue=None)
consolidation = dict(answer(fresh, 'reversal', 'consolidate'),
                     observations='the same tracker owns the PR-origin defect')
verdicts, _ = decided([dict(tracked, reconciliation=consolidation)], cands=CANDS[:1],
                      pr=206, issue=None, kind='followup')
check(verdicts['F-01']['exit'] == 'LINK' and verdicts['F-01']['verdict'] == 'record', verdicts)
check(not (state / '.rite/state/adoption-hold-206-followup.json').exists(), 'a recorded PR-origin LINK leaves no hold')
persisted = json.loads((state / '.rite/state/adoption-history-206-followup.json').read_text())
check(persisted['entries'][0]['decision']['exit'] == 'LINK' and
      persisted['entries'][0]['decision']['pr_blocking'] is True, persisted)
# Moving the same cited text to another line still matches the completed contract.
(repo / 'tool.sh').write_text('#!/bin/bash\n# relocated\necho "ok: $1"\n')
git(repo, 'add', '-A')
git(repo, 'commit', '-qm', 'move contract line')
moved_head = git(repo, 'rev-parse', 'HEAD').strip()
saved, _ = held([rec(contract=dict(contract, ref='tool.sh:3'))], 'undecided', cands=CANDS[:1],
                 pr=204, kind='followup', at=moved_head)
check('contract_match' in saved['reconciliation'][0]['signals'], saved)

# Identical Issue-body quotes belong to their source Issue, not every Issue with those words.
state = work / 'issue-contract-state'
adoption = state / '.rite/state/adoption-5-sweep.json'
body_record = rec(contract={'ref': 'issue', 'text': 'tool rejects an empty NAME'})
decided([dict(body_record, **resolved)], cands=CANDS[:1], pr=301, issue=777, kind='followup')
verdicts, _ = decided([body_record], cands=CANDS[:1], pr=302, issue=778, kind='followup')
check(verdicts['F-01']['exit'] == 'ADOPT', 'a quote from a different Issue is a different contract')
same = pending(body_record, pr=303, issue=777)
check([h['source']['pr'] for h in same['history']] == [301], same)


# History-only arbitration must stay bound to its inputs after a contract stops matching.
state = work / 'stale-contract-state'
adoption = state / '.rite/state/adoption-5-sweep.json'
original_issue = issue_body.read_text()
decided([rec(**resolved)], cands=CANDS[:1], pr=401, issue=100, kind='followup')
fresh = pending(rec(), pr=402)
check('prior_conflict' not in fresh['signals'], fresh)
for resolution in ('fix_implementation', 'change_contract'):
    old_answer = rec(reconciliation=answer(fresh, resolution=resolution))
    issue_body.write_text(original_issue.replace('empty NAME', 'empty or missing NAME'))
    stale = pending(old_answer, pr=402, reason='stale')
    check(stale['signals'] == [] and stale['fingerprint'] != fresh['fingerprint'], stale)
    new_answer = rec(reconciliation=answer(stale, resolution=resolution))
    if resolution == 'change_contract':
        pending(new_answer, pr=402, reason='contract_change')
    else:
        verdicts, _ = decided([new_answer], cands=CANDS[:1], pr=402, issue=100, kind='followup')
        check(verdicts['F-01']['exit'] == 'ADOPT', verdicts)
        persisted = json.loads((state / '.rite/state/adoption-history-402-followup.json').read_text())
        check(persisted['entries'][-1]['reconciliation'] == new_answer['reconciliation'], persisted)
    issue_body.write_text(original_issue)

# An unreadable history directory is an input error, never an empty history set.
state = work / 'unreadable-history-state'
adoption = state / '.rite/state/adoption-5-sweep.json'
decided([rec(**resolved)], cands=CANDS[:1], pr=501, issue=100, kind='followup')
decided([rec(['F-02'], **REJECT)], cands=CANDS[1:], pr=502, issue=100, kind='followup')
history_files = {p: p.read_bytes() for p in adoption.parent.glob('adoption-history-*.json')}
adoption.parent.chmod(0o300)
try:
    try:
        list(adoption.parent.iterdir())
    except PermissionError:
        result = run([rec(**REJECT)], cands=CANDS[:1], pr=502, issue=100, kind='followup')
        check(result.returncode != 0 and 'input_invalid' in result.stderr, result)
        check(all(p.read_bytes() == content for p, content in history_files.items()),
              'history listing failure must preserve every prior disposition')
    else:
        print('unreadable history permission case skipped: process can bypass directory permissions')
finally:
    adoption.parent.chmod(0o700)


# LINK replaces the same candidate's ADOPT history, but the requirement remains accepted.
for linked_axis in (True, False):
    state = work / f'linked-requirement-{linked_axis}'
    adoption = state / '.rite/state/adoption-301-followup.json'
    decided([rec()], cands=CANDS[:1], pr=301, issue=700, kind='followup')
    verdicts, _ = decided([rec(V=linked_axis, tracker=7, reason='existing tracker owns the requirement')],
                          cands=CANDS[:1], pr=301, issue=700, kind='followup')
    linked_path = state / '.rite/state/adoption-history-301-followup.json'
    linked_history = json.loads(linked_path.read_text())
    check(len(linked_history['entries']) == 1 and verdicts['F-01']['exit'] == 'LINK', linked_history)
    check(linked_history['entries'][0]['record']['present'] is True, linked_history)
    repeated = rec(V=False, reason='the same accepted requirement is still unresolved')
    fresh = pending(repeated, pr=302, issue=700)
    consolidation = dict(answer(fresh, 'reversal', 'consolidate'),
                         observations='the repeated requirement remains unsatisfied')
    pending(dict(repeated, reconciliation=consolidation), pr=302, issue=700, reason='unresolved_adoption')
    check(json.loads(linked_path.read_text()) == linked_history, 'a held repetition preserves the LINK history')
    # Reuse the existing tracker or verified resolution; neither is a rejection.
    for fields, expected in (({'tracker': 7}, 'LINK'),
                              ({'present': False, 'evidence': 'the requirement is now satisfied'}, 'RESOLVED')):
        current = dict(repeated, **fields)
        fresh = pending(current, pr=302, issue=700)
        consolidation = dict(answer(fresh, 'reversal', 'consolidate'),
                             observations='the repeated requirement has a verified disposition')
        verdicts, _ = decided([dict(current, reconciliation=consolidation)], cands=CANDS[:1],
                              pr=302, issue=700, kind='followup')
        check(verdicts['F-01']['exit'] == expected, verdicts)
    fresh = pending(repeated, pr=302, issue=700)
    verdicts, _ = decided([dict(repeated, reconciliation=answer(fresh, 'none', 'normal'))],
                          cands=CANDS[:1], pr=302, issue=700, kind='followup')
    check(verdicts['F-01']['exit'] == 'REJECT', 'an unrelated guarantee returns to normal adoption rules')

# Retaining a body quotation does not keep an answer valid after its source changes.
ledger.write_text('### 却下台帳\n\n| finding_id | file:line | 判定 | 判定文 | 出典 |\n'
                  '|------------|-----------|------|--------|------|\n'
                  '| code-quality-reviewer | tool.sh:3 | REJECT | guard was present | old-review.json |\n')
for source, body_path in (('issue', issue_body), ('pr', pr_body)):
    state = work / f'body-quotation-{source}'
    adoption = state / '.rite/state/adoption-601-followup.json'
    original = body_path.read_text()
    quote = 'tool rejects an empty NAME'
    body_path.write_text('## Contract\n\n' + quote + '.\n')
    record = rec(contract={'ref': source, 'text': quote}, prior=prior)
    initial = pending(record, pr=601)
    recorded = dict(record, reconciliation=answer(initial, 'conflict'))
    verdicts, _ = decided([recorded], cands=CANDS[:1], pr=601, issue=100, kind='followup')
    check(verdicts['F-01']['exit'] == 'ADOPT', verdicts)
    repeated, _ = decided([recorded], cands=CANDS[:1], pr=601, issue=100, kind='followup')
    check(repeated == verdicts, 'unchanged body reuses the answer')
    history_path = state / '.rite/state/adoption-history-601-followup.json'
    for changed_body in (quote + ' only in strict mode.\n',
                         quote + '.\nThis guarantee applies only in strict mode.\n'):
        before_history = history_path.read_bytes()
        body_path.write_text('## Contract\n\n' + changed_body)
        stale = pending(recorded, pr=601, reason='stale')
        check(stale['fingerprint'] != initial['fingerprint'], stale)
        check(history_path.read_bytes() == before_history, 'stale answer must not change history')
        fresh_answer = answer(stale, 'conflict')
        verdicts, _ = decided([dict(record, reconciliation=fresh_answer)], cands=CANDS[:1],
                              pr=601, issue=100, kind='followup')
        check(verdicts['F-01']['exit'] == 'ADOPT', verdicts)
        persisted = json.loads(history_path.read_text())
        check(persisted['entries'][0]['reconciliation'] == fresh_answer, persisted)
    body_path.write_text(original)
ledger.write_text('')


# The real gate keeps completed contracts across checkbox-only Issue updates.
original_issue = issue_body.read_text()
for saved_mark in (' ', 'x', 'X'):
    state = work / f'completion-state-{ord(saved_mark)}'
    adoption = state / '.rite/state/adoption-701-followup.json'
    body = original_issue.replace('- [ ] AC-1:', f'- [{saved_mark}] AC-1:', 1)
    issue_body.write_text(body)
    verdicts, _ = decided([rec(present=False)], cands=CANDS[:1], pr=701, issue=100, kind='followup')
    check(verdicts['F-01']['exit'] == 'RESOLVED', verdicts)
    history_path = state / '.rite/state/adoption-history-701-followup.json'
    before_history = history_path.read_bytes()
    for current_mark in (' ', 'x', 'X'):
        current = body.replace(f'- [{saved_mark}] AC-1:', f'- [{current_mark}] AC-1:', 1)
        issue_body.write_text(current)
        request = pending(rec(), pr=702)
        check('completed_contract' in request['signals'], request)
        recorded = rec(reconciliation=answer(request))
        verdicts, _ = decided([recorded], cands=CANDS[:1], pr=702, issue=100, kind='followup')
        check(verdicts['F-01']['exit'] == 'ADOPT', verdicts)
        issue_body.write_text(current.replace(f'- [{current_mark}] AC-1:',
                                             f'- [{"x" if current_mark == " " else " "}] AC-1:', 1))
        stale = pending(recorded, pr=702, reason='stale')
        check('completed_contract' in stale['signals'], stale)
        verdicts, _ = decided([rec(reconciliation=answer(stale))], cands=CANDS[:1],
                              pr=702, issue=100, kind='followup')
        check(verdicts['F-01']['exit'] == 'ADOPT', verdicts)
        current_history = json.loads((state / '.rite/state/adoption-history-702-followup.json').read_text())
        check(len(current_history['entries']) == 1, 'checkbox updates replace the same contract and candidate')
    check(history_path.read_bytes() == before_history, 'the original completed history stays unchanged')
issue_body.write_text(original_issue)

print(f'review-adoption-gate: {checks} checks passed')
PYTEST
