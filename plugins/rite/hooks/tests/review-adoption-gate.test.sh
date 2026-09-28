#!/usr/bin/env bash
# The adoption gate turns helper decisions into file / record / hold and saves every hold.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 - "$SCRIPT_DIR/../.." <<'PYTEST'
import json
import os
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


def run(records, cands=CANDS, kind='sweep', write=True):
    candidates.write_text(json.dumps({'candidates': cands}))
    adoption.parent.mkdir(parents=True, exist_ok=True)
    path = state / f'.rite/state/adoption-5-{kind}.json'
    if write:
        path.write_text(json.dumps({'adoption': {'head': head, 'records': records}}))
    elif path.exists():
        path.unlink()
    gh_log.write_text('')
    before = candidates.read_bytes(), review.read_bytes(), (path.read_bytes() if path.exists() else None)
    result = subprocess.run(
        ['bash', str(gate), '--pr', '5', '--kind', kind, '--state-root', str(state),
         '--candidates', str(candidates), '--review-result', str(review), '--base', base,
         '--issue-body', str(issue_body), '--pr-body', str(pr_body), '--ac-ids', 'AC-1',
         '--ledger', str(ledger), '--repo-root', str(repo)],
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
check('/rite:iterate 5' in saved['resume'] and 'adoption-5-sweep.json' in saved['resume'], saved['resume'])
for kind, command in (('triage', '/rite:iterate 5'), ('followup', '/rite:cleanup 5')):
    other, _ = held([], 'no_records', kind=kind, write=False)
    check(command in other['resume'] and other['kind'] == kind, other)

# A pre-existing verified defect with an acceptance criterion is the only verdict that may be filed.
verdicts, result = decided([rec(), rec(['F-02'], **REJECT)])
check(verdicts['F-01']['verdict'] == 'file' and verdicts['F-01']['record']['acceptance'], verdicts)
check(verdicts['F-02']['verdict'] == 'record' and verdicts['F-02']['exit'] == 'REJECT', verdicts)
check('[CONTEXT] ADOPTION_GATE=decided; kind=sweep; file=1; record=1; pr=5' in result.stderr, result.stderr)
check(not hold_file.exists(), 'a decided run must remove the stale hold file')

# Filing without an acceptance criterion is held, not filed.
saved, _ = held([rec(acceptance=''), rec(['F-02'], **REJECT)], 'undecided')
check(saved['held_ids'] == ['F-01'] and [c['id'] for c in saved['candidates']] == ['F-01'], saved)
check('acceptance' in saved['detail'], saved['detail'])

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
unknown = dict(V='unknown', contract=None, evidence='', reason='not reproduced yet')
proposition = {'claim': 'an empty NAME passes', 'reach': 'tool ""', 'reach_source': 'tool.sh:2', 'done': 'exit code observed'}
held([rec(**unknown), rec(['F-02'], **REJECT)], 'undecided')
held([rec(origin='pr', origin_cause=removed, proposition=proposition, investigate=True, **unknown),
      rec(['F-02'], **REJECT)], 'undecided')
verdicts, _ = decided([rec(proposition=proposition, investigate=True, **unknown), rec(['F-02'], **REJECT)])
check(verdicts['F-01']['verdict'] == 'file' and verdicts['F-01']['action'] == 'investigate', verdicts)

# A helper ERROR holds every candidate and names the helper's reason.
saved, _ = held([rec()], 'adoption_error')
check(saved['held_ids'] == ['F-01', 'F-02'] and 'candidates_uncovered' in saved['detail'], saved)

# Rerunning after the records are fixed continues from the saved hold and removes it.
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

print(f'review-adoption-gate: {checks} checks passed')
PYTEST
