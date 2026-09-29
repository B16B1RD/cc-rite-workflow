#!/usr/bin/env bash
# Adoption records against a real base...head diff, cited contracts, the ledger and a gh stub.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 - "$SCRIPT_DIR/../.." <<'PYTEST'
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

plugin = Path(sys.argv[1]).resolve()
helper = plugin / 'hooks/scripts/review-adoption-check.sh'
ledger_helper = plugin / 'hooks/scripts/nb-sweep-ledger.sh'
gate = plugin / 'scripts/review-class-demotion-gate.sh'
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
BASE_FILES = {
    'src/tool.sh': '#!/bin/bash\nguard_input() {\n  [ -n "$1" ] || exit 1\n  echo "ok: $1"\n}\n',
    'src/caller.sh': '#!/bin/bash\n. ./tool.sh\nguard_input "$NAME"\n',
    'docs/usage.md': '# tool\nUsage: tool NAME\nExit: 1 when NAME is empty\n',
    'docs/notes.md': ('# notes\n- 2026-01-01 D-01: keep the guard / Reason: r / Impact: i'
                      ' <!-- rite:deferred-defect pr=12 -->\n'
                      '- 2026-01-02 D-02: Usage stays stable / Reason: r / Impact: i\n'),
    'db/q.sql': 'select 1;\n-- keep the index\na\nb\nc\nd\ne\nf\ndrop table t;\nend;\n',
    'lib/inc.txt': ''.join(f'x{n}\n' for n in range(1, 11)),
}
for name, content in BASE_FILES.items():
    (repo / name).parent.mkdir(parents=True, exist_ok=True)
    (repo / name).write_text(content)
git(repo, 'add', '-A')
git(repo, 'commit', '-qm', 'base')
base = git(repo, 'rev-parse', 'HEAD').strip()
# The head removes the guard line, edits the caller line and changes the documented exit code.
(repo / 'src/tool.sh').write_text('#!/bin/bash\nguard_input() {\n  echo "ok: $1"\n}\n')
(repo / 'src/caller.sh').write_text('#!/bin/bash\n. ./tool.sh\nguard_input "${NAME:-}"\n')
(repo / 'docs/usage.md').write_text('# tool\nUsage: tool NAME\nExit: 2 when NAME is empty\n')
# With -U0 the removed "-- keep the index" and the added "++ counter" lines start with "--- " / "+++ ".
(repo / 'db/q.sql').write_text('select 1;\na\nb\nc\nd\ne\nf\nend;\n')
(repo / 'lib/inc.txt').write_text('x1\nx2\n++ counter\nx3\nx4\nx5\nx6\nx7\nx8\nx9 changed\nx10\n')
git(repo, 'commit', '-qam', 'head')
head = git(repo, 'rev-parse', 'HEAD').strip()

issue_body = work / 'issue.md'
issue_body.write_text(
    '## 受入条件\n\n- [ ] AC-1: tool rejects an empty NAME\n- [ ] AC-2: caller passes NAME\n\n'
    '## 9. Decision Log\n\n'
    '- 2026-01-01 D-01: defer the retry / Reason: r / Impact: i <!-- rite:deferred-defect pr=12 -->\n'
    '- 2026-01-02 D-02: the exit code is part of the interface / Reason: r / Impact: i\n')
pr_body = work / 'pr.md'
pr_body.write_text('## Summary\n\n- [x] caller keeps an unset NAME from aborting\n')

# The ledger is written by the production helper (five columns) and keeps a legacy four-column row.
entries = work / 'entries.md'
entries.write_text(
    '| F-11 | src/tool.sh:3 | recorded | severity=LOW; measured=false | 12-20260101120000.json |\n'
    '| F-12 | docs/usage.md:3 | REJECT | the exit code is documented | 12-20260101120000.json |\n'
    '| F-13 | src/caller.sh:3 | ADOPT | caller must accept an unset NAME | 12-20260101120000.json |\n'
    '| F-14 | src/caller.sh:3 | issued | severity=MEDIUM; measured=true | 12-20260101120000.json |\n')
ledger = work / 'ledger.md'
subprocess.run(['bash', str(ledger_helper), 'append', '--ledger-file', str(ledger), '--entries-file', str(entries)],
               check=True, capture_output=True, text=True)
ledger.write_text(ledger.read_text() + '| F-15 | src/tool.sh:2 | rejected | legacy row |\n')
check('| finding_id | file:line | 判定 | 判定文 | 出典 |' in ledger.read_text(), 'ledger header comes from the writer')

bin_dir = work / 'bin'
bin_dir.mkdir()
gh_log = work / 'gh.log'
(bin_dir / 'gh').write_text(
    '#!/bin/bash\nprintf \'%s\\n\' "$*" >> "$GH_LOG"\n'
    'case ",$GH_STATES," in *",$3=OPEN,"*) echo OPEN ;; *",$3=CLOSED,"*) echo CLOSED ;;'
    ' *) echo "could not resolve issue" >&2; exit 1 ;; esac\n')
(bin_dir / 'gh').chmod(0o755)
env = dict(os.environ, PATH=f'{bin_dir}:{os.environ["PATH"]}', GH_LOG=str(gh_log), GH_STATES='7=OPEN,8=CLOSED')

classification = work / 'class.json'
candidates_file = work / 'candidates.json'
review = work / 'review.json'
INPUTS = [classification, candidates_file, review, issue_body, pr_body, ledger]


def candidate(cid, severity='LOW', cls='B'):
    return {'id': cid, 'severity': severity, 'consequence_class': cls}


def rec(ids=['F-01'], **fields):
    record = {'ids': list(ids), 'V': True, 'C': False, 'T': False, 'contract': {'ref': 'AC-1'},
              'evidence': 'tool "" prints ok: and exits 0', 'origin': 'pre_existing', 'present': True,
              'tracker': None, 'prior': None, 'reason': '', 'proposition': None}
    record.update(fields)
    return record


def write_inputs(records, cands=None, head_value=None, cls='B', severity='LOW', review_head=None):
    cands = cands if cands is not None else sorted({cid for r in records for cid in r['ids']})
    classification.write_text(json.dumps({
        'classifications': [{'id': cid, 'class': cls, 'scenario': 's'} for cid in cands],
        'adoption': {'head': head_value or head, 'records': records}}))
    candidates_file.write_text(json.dumps({'candidates': [candidate(cid, severity, cls) for cid in cands]}))
    review.write_text(json.dumps({'commit_sha': review_head or head, 'findings': [], 'non_blocking_findings': [
        dict(candidate(cid, severity, cls), scope='current-pr') for cid in cands]}))


def invoke(args=None, repo_root=None, extra=()):
    gh_log.write_text('')
    before = {path: path.read_bytes() for path in INPUTS}
    state = (git(repo, 'status', '--porcelain'), git(repo, 'rev-parse', 'HEAD'))
    argv = args if args is not None else [
        '--classification', str(classification), '--candidates', str(candidates_file),
        '--review-result', str(review), '--base', base, '--ac-ids', 'AC-1,AC-2',
        '--issue-body', str(issue_body), '--pr-body', str(pr_body), '--ledger', str(ledger),
        '--repo-root', str(repo_root or repo)]
    result = subprocess.run(['bash', str(helper), *argv, *extra], capture_output=True, text=True, env=env, timeout=30)
    check(all(path.read_bytes() == data for path, data in before.items()), 'an input file changed')
    check((git(repo, 'status', '--porcelain'), git(repo, 'rev-parse', 'HEAD')) == state, 'the repository changed')
    return result


def decided(records, **kwargs):
    write_inputs(records, **kwargs)
    result = invoke()
    check(result.returncode == 0, f'expected success: {result.stdout}{result.stderr}')
    decisions = json.loads(result.stdout)['decisions']
    marker = (f'[CONTEXT] REVIEW_ADOPTION=ok; decisions={len(decisions)}; '
              f'file={sum(d["file"] for d in decisions)}; pr_blocking={sum(d["pr_blocking"] for d in decisions)}')
    check(result.stderr.splitlines()[-1] == marker, result.stderr)
    return decisions


def single(record, **kwargs):
    return decided([record], **kwargs)[0]


def refused(records, reason, ids, **kwargs):
    write_inputs(records, **kwargs)
    result = invoke()
    check(result.returncode == 1, f'expected ERROR {reason}: {result.stdout}{result.stderr}')
    check(result.stderr.splitlines()[-1] == f'[CONTEXT] REVIEW_ADOPTION=error; reason={reason}; ids={ids}',
          result.stderr)
    check(json.loads(result.stdout)['errors'][0]['reason'] == reason, result.stdout)
    return result


def gh_calls():
    return [line for line in gh_log.read_text().splitlines() if line]


# Positive control shared by the refusals below: a verified pre-existing defect is filed.
adopt = single(rec())
check(adopt == {'ids': ['F-01'], 'exit': 'ADOPT', 'origin': 'pre_existing', 'action': 'file_issue',
                'file': True, 'pr_blocking': False, 'tracker': None}, adopt)
check(gh_calls() == [], 'no tracker must not reach gh')

# A true axis needs both a contract and evidence, on every axis.
for axis in 'VCT':
    fields = {'V': False, 'C': False, 'T': False, axis: True}
    check(single(rec(**fields))['exit'] == 'ADOPT', f'{axis} true is adopted')
    refused([rec(contract=None, **fields)], 'contract_missing', 'F-01')
    refused([rec(evidence='', **fields)], 'evidence_missing', 'F-01')

# Every candidate is covered; the dropped ones are listed.
refused([rec(['F-01', 'F-02'])], 'candidates_uncovered', 'F-03', cands=['F-01', 'F-02', 'F-03'])
result = refused([rec(['F-01'])], 'candidates_uncovered', 'F-02,F-03', cands=['F-01', 'F-02', 'F-03'])
check(json.loads(result.stdout)['errors'][0]['ids'] == ['F-02', 'F-03'], result.stdout)
refused([rec(['F-01', 'F-09'])], 'unknown_candidate', 'F-09', cands=['F-01'])
check(single(rec(['F-01', 'F-02', 'F-03']), cands=['F-01', 'F-02', 'F-03'])['ids'] == ['F-01', 'F-02', 'F-03'],
      'one root cause may cover several candidates')
refused([rec()], 'input_invalid', 'F-01', cands=['F-01', 'F-01'])

# Citations must exist at the reviewed commit and must not be deferred-token lines.
for contract, reason in [
        ({'ref': 'AC-9'}, 'contract_not_found'),
        ({'ref': 'src/missing.sh:1', 'text': 'x'}, 'contract_not_found'),
        ({'ref': 'src/tool.sh:40', 'text': 'echo'}, 'contract_not_found'),
        ({'ref': 'src/tool.sh:2', 'text': 'echo'}, 'contract_not_found'),
        ({'ref': 'src/tool.sh:3', 'text': 'exit 1'}, 'contract_not_found'),
        ({'ref': 'docs/usage.md:3', 'text': 'Exit: 1 when NAME is empty'}, 'contract_not_found'),
        ({'ref': 'docs/usage.md:3'}, 'contract_not_found'),
        ({'ref': 'docs/notes.md:2', 'text': 'D-01: keep the guard'}, 'contract_deferred'),
        ({'ref': 'issue', 'text': 'D-01: defer the retry'}, 'contract_deferred'),
        ({'ref': 'issue', 'text': 'no such requirement'}, 'contract_not_found'),
        ({'ref': 'pr', 'text': '<!-- rite:deferred-defect pr=12 -->'}, 'contract_deferred')]:
    refused([rec(contract=contract)], reason, 'F-01')
for contract in [{'ref': 'AC-2'}, {'ref': 'docs/usage.md:3', 'text': 'Exit: 2 when NAME is empty'},
                 {'ref': 'docs/notes.md:3', 'text': 'Usage stays stable'},
                 {'ref': 'issue', 'text': 'the exit code is part of the interface'},
                 {'ref': 'pr', 'text': 'caller keeps an unset NAME from aborting'}]:
    check(single(rec(contract=contract))['exit'] == 'ADOPT', f'{contract} is citable')

# Each exit alone.
both = decided([rec(['F-01']), rec(['F-01'], V=False, reason='duplicate view')])
check([d['exit'] for d in both] == ['RECONCILE', 'RECONCILE'], both)
check(all(d['action'] == 'arbitrate' and d['pr_blocking'] and not d['file'] for d in both), both)
check(single(rec(present=False, evidence='the guard came back'))['exit'] == 'RESOLVED', 'resolved')
link = single(rec(tracker=7))
check((link['exit'], link['action'], link['file'], link['pr_blocking'], link['tracker'])
      == ('LINK', 'link', False, False, 7), link)
check(gh_calls() == ['issue view 7 --json state --jq .state'], gh_calls())
diagnose = single(rec(V='unknown', reason='not reproduced yet'))
check((diagnose['exit'], diagnose['action'], diagnose['file']) == ('DIAGNOSE', 'hold', False), diagnose)
reject = single(rec(V=False, contract=None, reason='style only; reconsider if the output changes'))
check((reject['exit'], reject['action'], reject['file'], reject['pr_blocking'])
      == ('REJECT', 'record_rejected', False, False), reject)
refused([rec(V=False, contract=None, reason='')], 'no_exit', 'F-01')

# When a record meets two conditions the upper exit wins.
pair = decided([rec(['F-01'], present=False, evidence='gone'), rec(['F-01'])])
check([d['exit'] for d in pair] == ['RECONCILE', 'RECONCILE'], pair)
check(single(rec(present=False, evidence='gone', tracker=7))['exit'] == 'RESOLVED', 'resolved beats link')
check(gh_calls() == [], 'a resolved record does not look up its tracker')
check(single(rec(tracker=7))['exit'] == 'LINK', 'link beats adopt')
check(single(rec(C='unknown', reason='contract scope unclear'))['exit'] == 'ADOPT', 'adopt beats diagnose')
check(single(rec(V=False, T='unknown', reason='fixture reach unclear'))['exit'] == 'DIAGNOSE', 'diagnose beats reject')
closed = single(rec(tracker=8))
check((closed['exit'], closed['action'], closed['file']) == ('ADOPT', 'file_issue', True), closed)
check(gh_calls() == ['issue view 8 --json state --jq .state'], gh_calls())
refused([rec(tracker=9)], 'tracker_unavailable', 'F-01')

# Terminal priors contradict the opposite judgment; the ledger writer's values are not terminal.
prior = lambda fid, where, disposition, premise='p': {'finding_id': fid, 'file_line': where,
                                                     'disposition': disposition, 'premise': premise}
check(single(rec(prior=prior('F-12', 'docs/usage.md:3', 'REJECT')))['exit'] == 'RECONCILE', 'REJECT vs true')
check(single(rec(V=False, contract=None, reason='r', prior=prior('F-13', 'src/caller.sh:3', 'ADOPT')))['exit']
      == 'RECONCILE', 'ADOPT vs all false')
check(single(rec(V=False, contract=None, reason='r', prior=prior('F-12', 'docs/usage.md:3', 'REJECT')))['exit']
      == 'REJECT', 'the same rejection is not a contradiction')
check(single(rec(prior=prior('F-11', 'src/tool.sh:3', 'recorded')))['exit'] == 'ADOPT', 'recorded is not terminal')
check(single(rec(prior=prior('F-14', 'src/caller.sh:3', 'issued')))['exit'] == 'ADOPT', 'issued is not terminal')
check(single(rec(V=False, contract=None, reason='r', prior=prior('F-15', 'src/tool.sh:2', 'rejected')))['exit']
      == 'REJECT', 'a legacy four-column rejected row is re-judged')
check(single(rec(present=False, evidence='gone', prior=prior('F-12', 'docs/usage.md:3', 'REJECT')))['exit']
      == 'RECONCILE', 'a contradicting prior beats resolved')
refused([rec(prior=prior('F-99', 'src/tool.sh:3', 'recorded'))], 'prior_not_found', 'F-01')
refused([rec(prior=prior('F-11', 'src/tool.sh:4', 'recorded'))], 'prior_not_found', 'F-01')
refused([rec(prior=prior('F-11', 'src/tool.sh:3', 'recorded', premise=''))], 'prior_not_found', 'F-01')
refused([rec(prior=prior('F-11', 'src/tool.sh:3', 'declined'))], 'record_invalid', 'F-01')

# A PR origin is accepted from a removed line, and from a changed caller reaching an unchanged line.
removed = {'diff': ['src/tool.sh:-3'], 'path': 'the removed guard lets an empty NAME through'}
caller = {'diff': ['src/caller.sh:+3'], 'path': 'the edited caller passes an empty NAME into guard_input at src/tool.sh:2'}
for cause in (removed, caller):
    fixed = single(rec(origin='pr', origin_cause=cause))
    check((fixed['exit'], fixed['action'], fixed['file'], fixed['pr_blocking'])
          == ('ADOPT', 'fix_in_pr', False, True), fixed)
    check(single(rec(origin='pr', origin_cause=cause, V=False, contract=None, reason='r'))['exit'] == 'REJECT',
          'V/C/T still decide a PR origin')
check(single(rec(origin='pr', origin_cause={'diff': ['src/caller.sh:-3'], 'path': 'p'}))['exit'] == 'ADOPT',
      'the old side of an edited line is a removed line')
check(single(rec(origin='pr', origin_cause={'contract': {'ref': 'AC-2'}}))['exit'] == 'ADOPT', 'accepted AC')
check(single(rec(origin='pr', origin_cause={'contract': {'ref': 'pr', 'text': 'caller keeps an unset NAME'}}))
      ['action'] == 'fix_in_pr', 'a PR promise is an accepted requirement')
# A content line that looks like a file header must not hide the later hunks of the same file.
for position in ('db/q.sql:-9', 'db/q.sql:-2', 'lib/inc.txt:+10', 'lib/inc.txt:-9', 'lib/inc.txt:+3'):
    check(single(rec(origin='pr', origin_cause={'diff': [position], 'path': 'p'}))['exit'] == 'ADOPT', position)
for position in ('db/q.sql:-10', 'lib/inc.txt:+11'):
    refused([rec(origin='pr', origin_cause={'diff': [position], 'path': 'p'})], 'origin_cause_not_found', 'F-01')
# The user's diff settings drop the header prefixes, merge nearby hunks with the unchanged lines between
# them, or rewrite the text through a textconv driver that doubles every line; positions stay exact.
(repo / '.git/info/attributes').write_text('* diff=double\n')
for setting, value in (('diff.noprefix', 'true'), ('diff.interHunkContext', '6'), ('diff.double.textconv', 'sed p')):
    git(repo, 'config', setting, value)
    for position in ('src/tool.sh:-3', 'lib/inc.txt:+10'):
        check(single(rec(origin='pr', origin_cause={'diff': [position], 'path': 'p'}))['exit'] == 'ADOPT',
              (setting, position))
    for position in ('lib/inc.txt:+5', 'db/q.sql:-5'):
        refused([rec(origin='pr', origin_cause={'diff': [position], 'path': 'p'})], 'origin_cause_not_found', 'F-01')
    git(repo, 'config', '--unset', setting)
(repo / '.git/info/attributes').unlink()
for cause, reason in [
        ({'diff': ['src/tool.sh:+3'], 'path': 'p'}, 'origin_cause_not_found'),
        ({'diff': ['src/tool.sh:-2'], 'path': 'p'}, 'origin_cause_not_found'),
        ({'diff': ['docs/notes.md:+2'], 'path': 'p'}, 'origin_cause_not_found'),
        (None, 'origin_cause_missing'),
        ({'diff': [], 'path': 'p'}, 'origin_cause_missing'),
        ({'diff': ['src/tool.sh:-3']}, 'origin_cause_missing'),
        ({'diff': ['src/tool.sh:3'], 'path': 'p'}, 'origin_cause_missing'),
        ({'contract': {'ref': 'src/tool.sh:2', 'text': 'guard_input'}}, 'origin_cause_missing'),
        ({'contract': {'ref': 'AC-9'}}, 'contract_not_found')]:
    refused([rec(origin='pr', origin_cause=cause)], reason, 'F-01')

# An unknown origin is a suspected PR origin, never pre-existing.
suspect = single(rec(origin='unknown'))
check((suspect['origin'], suspect['action'], suspect['file'], suspect['pr_blocking'])
      == ('unknown', 'hold_pr', False, True), suspect)
check(single(rec(origin='unknown', tracker=7))['pr_blocking'] is True, 'a link keeps a suspected PR origin blocking')
pr_link = single(rec(origin='pr', origin_cause=removed, tracker=7))
check((pr_link['exit'], pr_link['pr_blocking']) == ('LINK', True), 'a link keeps a PR origin blocking')

# An investigation is filed only with all four proposition items and the classifier's acceptance.
full = {'claim': 'the stop interval closes as work', 'reach': 'usage limit during a batch run',
        'reach_source': 'observed in a batch run log', 'done': 'the interval is recorded as an interruption'}
investigation = single(rec(V='unknown', reason='r', proposition=full, investigate=True))
check((investigation['exit'], investigation['action'], investigation['file']) == ('DIAGNOSE', 'investigate', True),
      investigation)
for item in full:
    held = single(rec(V='unknown', reason='r', proposition=dict(full, **{item: ''}), investigate=True))
    check((held['exit'], held['action'], held['file']) == ('DIAGNOSE', 'hold', False), (item, held))
held = single(rec(V='unknown', reason='r', proposition=full, investigate=False))
check((held['action'], held['file']) == ('hold', False), held)
for origin in ('pr', 'unknown'):
    cause = removed if origin == 'pr' else None
    held = single(rec(V='unknown', reason='r', proposition=full, investigate=True, origin=origin, origin_cause=cause))
    check((held['exit'], held['action'], held['file'], held['pr_blocking']) == ('DIAGNOSE', 'hold_pr', False, True),
          held)

# Severity and consequence class never change an exit.
mixed = [rec(['F-01']), rec(['F-02'], V='unknown', reason='r'), rec(['F-03'], V=False, contract=None, reason='r')]
write_inputs(mixed, cands=['F-01', 'F-02', 'F-03'])
plain = invoke()
write_inputs(mixed, cands=['F-01', 'F-02', 'F-03'], cls='A', severity='CRITICAL')
varied = invoke()
check(plain.returncode == varied.returncode == 0 and plain.stdout == varied.stdout, (plain.stdout, varied.stdout))
check([d['exit'] for d in json.loads(plain.stdout)['decisions']] == ['ADOPT', 'DIAGNOSE', 'REJECT'], plain.stdout)

# The same input gives the same output.
again = invoke()
check((again.returncode, again.stdout, again.stderr) == (varied.returncode, varied.stdout, varied.stderr), 'rerun')

# Malformed records and inputs stop.
refused([rec()], 'head_mismatch', '', head_value=base)
# A git failure is git_failed, not a missing citation; a directory path is not a citable file.
missing_head = '0' * 40
cited = rec(contract={'ref': 'docs/usage.md:3', 'text': 'Exit: 2 when NAME is empty'})
refused([cited], 'git_failed', 'F-01', head_value=missing_head, review_head=missing_head)
write_inputs([cited])
outside = invoke(repo_root=work)
check(outside.returncode == 1 and outside.stderr.splitlines()[-1]
      == '[CONTEXT] REVIEW_ADOPTION=error; reason=git_failed; ids=F-01', outside.stderr)
for ref in ('src:3', 'src/:3'):
    refused([rec(contract={'ref': ref, 'text': 'caller.sh'})], 'contract_not_found', 'F-01')
refused([rec(C='unknown', reason='')], 'reason_missing', 'F-01')
refused([rec(present=False, evidence='')], 'evidence_missing', 'F-01')
for fields in ({'V': 1}, {'V': 'yes'}, {'V': None}):
    refused([rec(**fields)], 'vct_invalid', 'F-01')
for fields in ({'origin': 'pre-existing'}, {'present': 'no'}, {'tracker': 0}, {'tracker': True}):
    refused([rec(**fields)], 'record_invalid', 'F-01')
refused([rec(['F-01']), rec([])], 'record_invalid', '', cands=['F-01'])
for broken in ('{', json.dumps({'classifications': [], 'adoption': {'records': [rec()]}})):
    write_inputs([rec()])
    classification.write_text(broken)
    result = invoke()
    check(result.returncode == 1 and result.stderr.splitlines()[-1]
          == '[CONTEXT] REVIEW_ADOPTION=error; reason=input_invalid; ids=', (broken, result.stderr))
write_inputs([rec()])
check(invoke(['--classification', str(classification)]).returncode == 2, 'missing arguments are a usage error')

# The adoption key does not change the demotion gate's result on the same classification map.
gate_review = {'schema_version': '1.1.0', 'commit_sha': head, 'overall_assessment': 'fix-needed',
               'findings': [{'id': 'F-01', 'reviewer': 'code-quality', 'category': 'naming', 'severity': 'MEDIUM',
                             'scope': 'current-pr', 'verification': {'measured': True}, 'file': 'src/tool.sh',
                             'line': 2, 'description': 'd', 'suggestion': 's', 'status': 'open'}],
               'non_blocking_findings': []}
outcomes = []
for extra in ({}, {'adoption': {'head': head, 'records': [rec()]}}):
    target, gate_map = work / 'gate.json', work / 'gate-map.json'
    target.write_text(json.dumps(gate_review))
    gate_map.write_text(json.dumps(dict({'classifications': [{'id': 'F-01', 'class': 'B', 'scenario': 's'}]}, **extra)))
    ran = subprocess.run(['bash', str(gate), '--input', str(target), '--classification', str(gate_map)],
                         capture_output=True, text=True, timeout=30)
    outcomes.append((ran.returncode, ran.stderr, target.read_text()))
check(outcomes[0] == outcomes[1] and outcomes[0][0] == 0, outcomes)
check('CLASS_DEMOTION_GATE=applied' in outcomes[0][1], outcomes[0][1])

# Reconciliation is a parent-authored answer to an exact request, never a new finding.
history_dir = work / 'history'
history_dir.mkdir()
history_args = ['--history-dir', str(history_dir), '--pr', '20', '--kind', 'sweep', '--issue', '100']


def reconcile(record, **kwargs):
    write_inputs([record], **kwargs)
    result = invoke(extra=history_args)
    check(result.returncode == 0, f'reconciliation failed: {result.stdout}{result.stderr}')
    return json.loads(result.stdout)


def request_of(output, reason='pending'):
    check(len(output['reconciliation']) == 1, output)
    request = output['reconciliation'][0]
    check(request['ids'] == ['F-01'] and request['reason'] == reason, request)
    decision = output['decisions'][0]
    check((decision['exit'], decision['action'], decision['file'], decision['pr_blocking'])
          == ('RECONCILE', 'arbitrate', False, True), decision)
    return request


def answer(request, trigger='conflict', resolution='fix_implementation', **fields):
    return dict({'fingerprint': request['fingerprint'], 'trigger': trigger, 'resolution': resolution,
                 'premise': 'the interface still rejects an empty NAME',
                 'reason': 'the prior rejection assumed a guard that is now absent',
                 'evidence': 'tool "" exits 0 at the reviewed commit', 'observations': ''}, **fields)


conflict = rec(prior=prior('F-12', 'docs/usage.md:3', 'REJECT'))
request = request_of(reconcile(conflict))
check('prior_conflict' in request['signals'], request)
check(request['record'] == conflict and request['history'] == [], request)
accepted = dict(conflict, reconciliation=answer(request))
adjudicated = reconcile(accepted)
check(adjudicated['decisions'][0]['exit'] == 'ADOPT' and adjudicated['reconciliation'] == [], adjudicated)
check(reconcile(accepted) == adjudicated, 'identical conditions reuse the same parent answer')
# Each single changed input invalidates the answer; the helper never mutates source inputs.
for fields in ({'evidence': 'a second direct run exits 0'}, {'reason': 'updated adjudication context'},
               {'contract': {'ref': 'AC-2'}}):
    stale = request_of(reconcile(dict(accepted, **fields)), 'stale')
    check(stale['fingerprint'] != request['fingerprint'], (fields, stale))
write_inputs([accepted])
data = json.loads(candidates_file.read_text())
data['candidates'][0]['description'] = 'new complete candidate text'
candidates_file.write_text(json.dumps(data))
changed = invoke(extra=history_args)
check(changed.returncode == 0, changed.stderr)
request_of(json.loads(changed.stdout), 'stale')
original_issue = issue_body.read_text()
issue_body.write_text(original_issue.replace('tool rejects an empty NAME', 'tool rejects an empty or missing NAME'))
request_of(reconcile(accepted), 'stale')
issue_body.write_text(original_issue)
# Supported AC items include multiline headings and checkbox continuations.
# A different AC or an example outside the section is not this contract.
for heading in ('### AC-1: reject empty input', '- [ ] AC-1: reject empty input'):
    multiline = ('## 4. Acceptance Criteria\n\n' + heading + '\n'
                 'Given: an empty NAME\nWhen: tool runs\nThen: exit 1\n'
                 '\n### AC-2: independent caller\nThen: preserve NAME\n'
                 '\n## Notes\nAC-1 is used by the caller\n')
    issue_body.write_text(multiline)
    ac_extract = subprocess.run(['bash', str(plugin / 'scripts/acceptance-criteria-check.sh'),
                                 'extract', '--body-file', str(issue_body)], capture_output=True, text=True)
    check(ac_extract.returncode == 0 and ac_extract.stdout.strip() == 'AC-1,AC-2', ac_extract)
    pending = request_of(reconcile(conflict))
    multiline_answer = dict(conflict, reconciliation=answer(pending))
    check(reconcile(multiline_answer)['reconciliation'] == [], 'unchanged multiline AC reuses answer')
    for before, after in (('an empty NAME', 'a missing NAME'), ('tool runs', 'caller runs'),
                          ('exit 1', 'exit 2')):
        issue_body.write_text(multiline.replace(before, after))
        request_of(reconcile(multiline_answer), 'stale')
    issue_body.write_text(multiline.replace('preserve NAME', 'normalize NAME')
                         .replace('AC-1 is used by the caller', 'AC-1 has a separate note'))
    check(reconcile(multiline_answer)['reconciliation'] == [], 'other AC and notes are independent')
issue_body.write_text(original_issue)
git(repo, 'commit', '--allow-empty', '-qm', 'unrelated new head')
new_head = git(repo, 'rev-parse', 'HEAD').strip()
request_of(reconcile(accepted, head_value=new_head, review_head=new_head), 'stale')

# A contract change always holds instead of silently changing the requirement.
changed_contract = request_of(reconcile(dict(conflict, reconciliation=answer(request, resolution='change_contract'))),
                              'contract_change')
check(changed_contract['fingerprint'] == request['fingerprint'], changed_contract)
# An unresolved prior adoption cannot be silently rejected, even with a parent answer.
unresolved = rec(V=False, contract=None, reason='the defect is still present',
                 prior=prior('F-13', 'src/caller.sh:3', 'ADOPT'))
pending = request_of(reconcile(unresolved))
request_of(reconcile(dict(unresolved, reconciliation=answer(pending))), 'unresolved_adoption')
# Consolidation keeps an unresolved adoption on its OPEN tracker, including PR blocking.
for origin in ('pre_existing', 'pr'):
    tracked = dict(unresolved, tracker=7, origin=origin, origin_cause=removed)
    pending = request_of(reconcile(tracked))
    linked = reconcile(dict(tracked, reconciliation=answer(pending, resolution='consolidate')))
    decision = linked['decisions'][0]
    check(decision['exit'] == 'LINK' and decision['tracker'] == 7, linked)
    check(decision['pr_blocking'] == (origin == 'pr') and linked['reconciliation'] == [], linked)
closed = dict(unresolved, tracker=8)
pending = request_of(reconcile(closed))
request_of(reconcile(dict(closed, reconciliation=answer(pending, resolution='consolidate'))),
           'unresolved_adoption')
# A reversal needs a concrete observation and can consolidate onto an existing tracker.
reversal = dict(conflict, tracker=7)
pending = request_of(reconcile(reversal))
linked = reconcile(dict(reversal, reconciliation=answer(pending, 'reversal', 'consolidate',
                                                       observations='the new caller bypasses the old guard')))
check(linked['decisions'][0]['exit'] == 'LINK' and linked['decisions'][0]['tracker'] == 7, linked)
for fields in ({'observations': ''}, {'trigger': 'none'}, {'resolution': 'normal'},
               {'new_findings': [{'id': 'F-99'}]}, {'premise': ''}, {'evidence': ''}):
    bad = answer(pending, 'reversal', 'consolidate', observations='the changed caller reaches the path')
    bad.update(fields)
    write_inputs([dict(reversal, reconciliation=bad)])
    result = invoke(extra=history_args)
    check(result.returncode == 1 and json.loads(result.stdout)['errors'][0]['reason'] == 'record_invalid',
          (fields, result.stdout, result.stderr))

# An accepted requirement remains unresolved when its history becomes LINK.
for linked_axis in (True, False):
    history_args[history_args.index('--pr') + 1] = '21'
    adopted = reconcile(rec())
    path = history_dir / 'adoption-history-21-sweep.json'
    path.write_text(json.dumps(adopted['history']))
    linked = reconcile(rec(V=linked_axis, tracker=7, reason='existing tracker owns the accepted requirement'))
    path.write_text(json.dumps(linked['history']))
    check(len(linked['history']['entries']) == 1 and linked['decisions'][0]['exit'] == 'LINK', linked)
    history_args[history_args.index('--pr') + 1] = '20'
    repeated = rec(V=False, reason='the same accepted requirement is still unresolved')
    pending = request_of(reconcile(repeated))
    consolidation = answer(pending, 'reversal', 'consolidate', observations='the same requirement is still unmet')
    request_of(reconcile(dict(repeated, reconciliation=consolidation)), 'unresolved_adoption')
    path.unlink()

# Overlapping root-cause records require merging the records before adjudication.
write_inputs([conflict, dict(conflict, present=False, evidence='gone')])
result = invoke(extra=history_args)
check(result.returncode == 0, result.stderr)
overlap = json.loads(result.stdout)
check(len(overlap['reconciliation']) == 2 and
      all(r['reason'] == 'records_overlap' for r in overlap['reconciliation']), overlap)

print(f'review-adoption: {checks} checks passed')
PYTEST
