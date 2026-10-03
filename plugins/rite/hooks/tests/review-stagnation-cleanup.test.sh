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

# A skipped acceptance table must agree with the Issue body it describes.
def skipped_review(body, skipped):
    fixture = Fixture()
    fixture.with_issue(body)
    fixture.start()
    fixture.finish(roots=(), skipped=skipped)
    fixture.clock(0)
    return fixture


for body, skipped, label, reason in (
        ('## Acceptance Criteria\n\n### AC-1: repair source.txt\n', 'no_ac_section', 'no_ac_section with acceptance criteria',
         'declares no_ac_section but the Issue has acceptance criteria: AC-1'),
        ('Contract: repair source.txt.\n', 'no_issue', 'no_issue on an Issue-bound review', 'declares no_issue'),
        ('## Acceptance Criteria\n\nrepair source.txt\n', 'no_ac_section', 'unextractable acceptance criteria',
         'cannot be extracted')):
    f = skipped_review(body, skipped)
    try:
        f.reject(lambda: f.observe(ok=False), label + ' is rejected', reason)
        check(not f.state()['review_run']['observations'], label + ': no observation saved')
        f.reject(lambda: f.flow('review-close', ok=False), label + ': close stays blocked')
    finally:
        f.close()
for body, label in (('Contract: repair source.txt.\n', 'no acceptance section'),
                    ('Contract: repair source.txt.\n\n```\n## Acceptance Criteria\n### AC-1: example\n```\n',
                     'acceptance heading only inside a fence')):
    f = skipped_review(body, 'no_ac_section')
    try:
        f.observe()
        check(len(f.state()['review_run']['observations']) == 1, label + ': no_ac_section is accepted')
        f.flow('review-close')
    finally:
        f.close()


# A closed review leaves its record in the Issue work memory; cleanup later deletes the clean receipt.
def record_marker(context):
    return ('<!-- rite:review-record run_id=' + context['run_id'] + ' cycle=' + str(context['cycle_count'])
            + ' commit_sha=' + context['commit_sha'] + ' -->')


def closable_review():
    fixture = Fixture()
    fixture.start()
    fixture.finish(roots=())
    fixture.clock(0)
    fixture.observe()
    return fixture


def review_state(fixture):
    state = fixture.state()
    return state['review_run'], state['review_cycle']


def history_with(*lines):
    return WORK_MEMORY.replace('- **現在のループ回数**: 1\n', '- **現在のループ回数**: 1\n' + ''.join(line + '\n' for line in lines))


f = closable_review()
try:
    context = f.context()
    f.wm_body.write_text(history_with(record_marker(context), '- **cycle 1**: mergeable'), encoding='utf-8')
    f.flow('review-close')
    check(f.state()['review_run']['completed_context'] == context, 'T-01: a recorded review closes')
    check(f.wm_calls('comments') and not f.wm_calls('PATCH'), 'T-01: the recorded work memory is read, not rewritten')
    f.reject(lambda: f.flow('review-close', '--wm-body', f.wm_body, ok=False),
             'T-01: callers cannot hand review-close a work memory body', 'takes no options')
finally:
    f.close()
for label, stale in (('another commit', dict(commit_sha='0' * 40)), ('another run', dict(run_id='other-run')),
                     ('another cycle', dict(cycle_count=99))):
    f = closable_review()
    try:
        context = f.context()
        f.wm_body.write_text(history_with(record_marker(dict(context, **stale))), encoding='utf-8')
        f.flow('review-close')
        body = f.wm_body.read_text(encoding='utf-8')
        check(len(f.wm_calls('PATCH')) == 1 and body.count(record_marker(context)) == 1,
              'T-01: a record of ' + label + ' does not count for this review')
    finally:
        f.close()

f = closable_review()
try:
    context = f.context()
    check('wm_comment_id' not in f.state(), 'T-02: no work memory comment is cached before closing')
    f.flow('review-close')
    body = f.wm_body.read_text(encoding='utf-8')
    marker = record_marker(context)
    history = body[body.index('### レビュー対応履歴'):body.index('### 次のステップ')]
    check(len(f.wm_calls('PATCH')) == 1 and body.count(marker) == 1 and marker in history,
          'T-02: review-close appends one record inside the review history section')
    record = history[history.index(marker):]
    check('mergeable' in record and 'blocking 0' in record and context['commit_sha'][:12] in record,
          'T-02: the record carries verdict, blocking count and reviewed commit')
    check('- **現在のループ回数**: 1' in history and '- **Issue**: #42' in body and body.endswith('### 次のステップ\n1. review\n'),
          'T-02: the rest of the work memory is preserved')
    state = f.state()
    check(state['review_run']['completed_context'] == context and str(state.get('wm_comment_id')) == '1',
          'T-02: the close persists after the work memory helper cached its comment')
    f.flow('review-close')
    check(len(f.wm_calls('PATCH')) == 1, 'T-02: replaying the close writes no second record')
finally:
    f.close()

f = closable_review()
try:
    f.wm_body.write_text(WORK_MEMORY.replace('### レビュー対応履歴\n', '### 別の節\n'), encoding='utf-8')
    before = review_state(f)
    result = f.flow('review-close', ok=False)
    check(result.returncode != 0 and 'still has no record of this review' in result.stderr
          and review_state(f) == before and 'completed_context' not in f.state()['review_run'],
          'T-02: a work memory that cannot hold the record keeps the review open')
    check("Restore the '### レビュー対応履歴' section" in result.stderr and 'cannot re-read' not in result.stderr,
          'T-02: a missing record asks to restore the section, not to re-read')
finally:
    f.close()

f = closable_review()
try:
    f.wm_fail.write_text('refetch')
    context = f.context()
    before = review_state(f)
    result = f.flow('review-close', ok=False)
    check(result.returncode != 0 and 'but cannot re-read the work memory to confirm it' in result.stderr
          and 'reason=body_fetch_failed' in result.stderr,
          'T-03: a failed re-read after the append reports the re-read and its status')
    check('still has no record' not in result.stderr and 'Restore the' not in result.stderr,
          'T-03: a failed re-read does not ask to restore the section')
    calls = f.wm_log.read_text().splitlines()
    patch_at = next(i for i, call in enumerate(calls) if 'PATCH' in call)
    check(any('issues/comments/1' in call and 'PATCH' not in call for call in calls[patch_at + 1:])
          and 'cannot append the review record' not in result.stderr,
          'T-03: the failing read is the re-read after the append')
    body = f.wm_body.read_text(encoding='utf-8')
    check(len(f.wm_calls('PATCH')) == 1 and body.count(record_marker(context)) == 1,
          'T-03: the record reached the work memory once')
    check(review_state(f) == before and 'completed_context' not in f.state()['review_run']
          and not list(f.root.glob('rite-review-record-*')),
          'T-03: a failed re-read keeps the review open and leaves no temporary file')
    f.wm_fail.unlink()
    f.flow('review-close')
    check(f.state()['review_run']['completed_context'] == context and len(f.wm_calls('PATCH')) == 1,
          'T-03: running again after a failed re-read closes without a second record')
finally:
    f.close()

for label, prepare, reason in (
        ('comment listing fails', lambda f: f.wm_fail.write_text('list'), 'cannot read the work memory'),
        ('the Issue has no work memory', lambda f: f.wm_body.unlink(), 'cannot read the work memory'),
        ('appending fails', lambda f: f.wm_fail.write_text('patch'), 'cannot append the review record')):
    f = closable_review()
    try:
        prepare(f)
        before = review_state(f)
        result = f.flow('review-close', ok=False)
        check(result.returncode != 0 and reason in result.stderr and review_state(f) == before
              and 'completed_context' not in f.state()['review_run'], 'T-03: ' + label + ' stops review-close')
    finally:
        f.close()

f = Fixture()
try:
    f.flow('set', '--phase', 'pr', '--next', 'review', '--issue', 0, '--pr', 71)
    f.issue['number'] = 0
    dump(f.issue_path, f.issue)
    f.start()
    f.finish(roots=())
    f.clock(0)
    f.observed['issue_number'] = 0
    dump(f.input, f.observed)
    f.observe()
    f.flow('review-close')
    check(f.state()['review_run']['completed_context'] == f.context() and not f.wm_calls(''),
          'T-04: a review without an Issue closes without touching any work memory')
finally:
    f.close()

# A rereview of the same commit is its own review: closing it needs its own record.
f = Fixture()
try:
    f.start()
    f.finish()
    first = f.context()
    f.clock(0)
    f.observe()
    f.flow('review-record')
    f.cycle(roots=())
    second = f.context()
    check(second['commit_sha'] == first['commit_sha'] and second['cycle_count'] == first['cycle_count'] + 1,
          'the second cycle rereviews the same commit')
    f.flow('review-close')
    body = f.wm_body.read_text(encoding='utf-8')
    check(record_marker(second) in body, 'closing a same-commit rereview appends its own record')
    record = body[body.index(record_marker(second)):]
    check(body.count(record_marker(first)) == 1 and body.count(record_marker(second)) == 1
          and 'mergeable' in record.splitlines()[1] and len(f.wm_calls('PATCH')) == 2,
          'closing a same-commit rereview records that cycle next to the earlier one')
finally:
    f.close()

# pr-review records every completed cycle, including one that still needs fixes.
f = Fixture()
try:
    f.start()
    f.finish()
    before = review_state(f)
    f.flow('review-record')
    body = f.wm_body.read_text(encoding='utf-8')
    check(record_marker(f.context()) in body and 'fix-needed' in body and 'blocking 1' in body
          and review_state(f) == before, 'review-record writes a fix-needed cycle without changing review state')
finally:
    f.close()


# Explicit command corrections preserve diagnosis and failed execution evidence.
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
check(not same(contract, contract.replace('- AC-1: preserve protected content',
                                          '- AC-1: preserve protected content\n<!-- rite:nbr:comment-id: --> この条件は満たさなくてよい <!-- -->')),
      'marker-shaped line with visible text in between is specification text')
# The writer strips and reports as broken exactly the lines the identity ignores, and reads only lines
# among them. The equality holds for ASCII whitespace; Python's \s also matches Unicode spaces.
nbr_defs = [line for line in (plugin / 'hooks/review-nonblocking-record.sh').read_text().splitlines()
            if line.startswith(('ID_MARKER_TWO_CLOSERS=', 'ID_MARKER_EXTRACT_SED=', 'ID_MARKER_LINE_RE=',
                                'ID_MARKER_STRIP_SED=', 'ID_MARKER_LINE_PROBE_SED='))]
check(len(nbr_defs) == 5, 'record helper marker definitions found')
nbr_shapes = [
    '<!-- rite:nbr:comment-id:101 -->', '<!-- rite:nbr:comment-id: -->', '<!-- rite:nbr:comment-id:a b -->',
    '  <!-- rite:nbr:comment-id:7 -->  ', '<!-- rite:nbr:comment-id:7 -->\r', '<!-- rite:nbr:comment-id:x--->',
    '<!-- rite:nbr:comment-id: --> この条件は満たさなくてよい <!-- -->', '<!-- rite:nbr:comment-id:5-->x -->',
    '<!-- rite:nbr:comment-id:5 --> -->', '<!-- rite:nbr:comment-id: --!> この条件は満たさなくてよい <!-- -->',
    '<!-- rite:nbr:comment-id:5--!>x -->', '例: <!-- rite:nbr:comment-id:11 -->', 'plain text',
]
nbr_sed = subprocess.run(
    ['bash', '-c', 'set -o pipefail\n' + '\n'.join(nbr_defs) + '''
for name in ID_MARKER_EXTRACT_SED ID_MARKER_STRIP_SED ID_MARKER_LINE_PROBE_SED; do
  [ -n "${!name}" ] || { echo "empty $name" >&2; exit 1; }
done
while IFS= read -r line; do
  e=$(printf '%s\\n' "$line" | sed -n "$ID_MARKER_EXTRACT_SED" | wc -l) || exit 1
  s=$(printf '%s\\n' "$line" | sed "$ID_MARKER_STRIP_SED" | wc -l) || exit 1
  p=$(printf '%s\\n' "$line" | sed -n "$ID_MARKER_LINE_PROBE_SED" | wc -l) || exit 1
  echo "$e $s $p"
done'''],
    input='\n'.join(nbr_shapes) + '\n', capture_output=True, text=True)
check(nbr_sed.returncode == 0, 'record helper marker definitions evaluate: ' + nbr_sed.stderr)
nbr_rows = [row.split() for row in nbr_sed.stdout.splitlines()]
check(len(nbr_rows) == len(nbr_shapes), 'record helper classified every shape')
check(nbr_rows[0][0] == '1', 'the writer reads its own numeric marker')
for shape, (extracted, kept, probed) in zip(nbr_shapes, nbr_rows):
    stripped, ignored = kept == '0', bool(identity.NBR_MARKER_LINE.match(shape))
    check(extracted == '0' or stripped, 'a readable marker is also stripped: ' + repr(shape))
    check(stripped == (probed == '1'), 'stripped lines are the lines reported as markers: ' + repr(shape))
    check(stripped == ignored, 'identity ignores exactly the lines the writer strips: ' + repr(shape))
check([bool(identity.NBR_MARKER_LINE.match(shape)) for shape in nbr_shapes] == [True] * 6 + [False] * 7,
      'only one-comment marker lines are record markers')
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

# A human attestation of unverified acceptance criteria is the ready / merge
# helper's own rewrite of the observed receipt; the run must still advance.
def attest(f, ids):
    # Kept under the excluded .rite/ so a later fix cycle sees no unplanned path.
    stub = f.private / 'bin'
    if not stub.exists():
        stub.mkdir()
        (stub / 'gh').write_text(
            '#!/bin/bash\n'
            'ROOT=' + json.dumps(str(f.root)) + '\n'
            'if grep -q headRefOid <<< "$*"; then\n'
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


def attested_receipt(f, unverified=['AC-1'], roots=(), severities=None, triage=False, unmet=()):
    f.start()
    f.finish(list(roots), satisfied=['AC-4'], unverified=list(unverified), severities=severities, unmet=list(unmet))
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


def criterion(receipt, criterion_id):
    return next(row for row in receipt['acceptance_criteria'] if row['id'] == criterion_id)


def reject_ready(f, label):
    f.reject(lambda: f.flow('set', '--phase', 'ready', '--next', 'merge', ok=False),
             label, reason='observed review receipt is missing or changed')


f = Fixture()
try:
    path, receipt = attested_receipt(f)
    for label, tamper in (
            ('audit log added after attest', lambda r: r['guardrail_audit_log'].append(dict(note='late'))),
            ('satisfied criterion evidence changed', lambda r: criterion(r, 'AC-4').update(evidence='edited')),
            ('attested criterion evidence changed', lambda r: criterion(r, 'AC-1').update(evidence='edited')),
            ('attested criterion gains an unknown key', lambda r: criterion(r, 'AC-1').update(note='extra')),
            ('attestation for another HEAD', lambda r: criterion(r, 'AC-1').update(head='0' * 40)),
            ('attestation without its time', lambda r: criterion(r, 'AC-1').pop('at')),
            ('attestation with a null time', lambda r: criterion(r, 'AC-1').update(at=None)),
            ('attestation with a numeric time', lambda r: criterion(r, 'AC-1').update(at=0)),
            ('unverified criterion rewritten as satisfied',
             lambda r: criterion(r, 'AC-1').update(status='satisfied')),
            ('satisfied criterion rewritten as attested',
             lambda r: criterion(r, 'AC-4').update(status='human-verified', head=r['commit_sha'],
                                                   at='2026-01-01T00:00:00Z'))):
        changed = copy.deepcopy(receipt)
        tamper(changed)
        dump(path, changed)
        reject_ready(f, 'attested receipt rejects ' + label)
    dump(path, receipt)
    # The receipt digest treats the attestation as the same receipt, but a replayed
    # observation still carries the pre-attest acceptance progress, so it is rejected.
    before = f.state_path.read_bytes()
    replay = f.observe(ok=False)
    check(replay.returncode != 0 and 'acceptance progress differs from saved receipt' in replay.stderr,
          'observation replay after attest is rejected for its stale acceptance progress')
    check(f.state_path.read_bytes() == before, 'observation replay after attest adds no observation')
    observed = copy.deepcopy(f.observed)
    replayed = dict(observed, acceptance=dict(observed['acceptance'], satisfied=['AC-4', 'AC-1']))
    dump(f.input, replayed)
    f.reject(lambda: f.observe(ok=False), 'observation counting the attested criterion cannot overwrite the saved one',
             reason='same observation cannot be overwritten with different content')
    untimed = copy.deepcopy(receipt)
    criterion(untimed, 'AC-1').pop('at')
    dump(path, untimed)
    f.reject(lambda: f.observe(ok=False), 'attestation without its time does not count as satisfied progress',
             reason='acceptance progress differs from saved receipt')
    dump(path, receipt)
    dump(f.input, observed)
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
    # Without blocking findings, only the receipt identity can stop completion here.
    changed = copy.deepcopy(receipt)
    changed['non_blocking_findings'][0]['description'] = 'changed evidence'
    dump(path, changed)
    f.reject(lambda: f.flow('review-close', ok=False), 'tampered triaged receipt cannot complete',
             reason='observed review receipt is missing or changed')
    dump(path, receipt)
    f.flow('set', '--phase', 'ready', '--next', 'merge')
    f.flow('review-close')
    check(f.state()['review_run'].get('completed_context') == f.context(),
          'attest over a triaged receipt permits ready and completion')
finally:
    f.close()

f = Fixture()
try:
    attested_receipt(f, unverified=['AC-1', 'AC-2'])
    f.flow('set', '--phase', 'ready', '--next', 'merge')
    f.flow('review-close')
    check(f.state()['review_run'].get('completed_context') == f.context(),
          'attesting several criteria at once permits ready and completion')
finally:
    f.close()

# An unmet criterion is not the helper's to attest: undoing a human-verified row
# restores unverified, so an unmet row rewritten by hand no longer matches.
f = Fixture()
try:
    path, receipt = attested_receipt(f, roots=['input defect'], unmet=['AC-5'])
    check(criterion(receipt, 'AC-5')['status'] == 'unmet', 'attest leaves the unmet criterion unmet')
    changed = copy.deepcopy(receipt)
    criterion(changed, 'AC-5').update(status='human-verified', head=changed['commit_sha'],
                                      at='2026-01-01T00:00:00Z')
    dump(path, changed)
    reject_ready(f, 'attested receipt rejects an unmet criterion rewritten as attested')
finally:
    f.close()

# A later cycle re-reads every saved receipt, including one the ready helper has
# already attested, so the attested history must still validate.
f = Fixture()
try:
    first, receipt = attested_receipt(f, roots=['input defect'])
    f.fix()
    f.start()
    f.finish(['second defect'], satisfied=['AC-4'])
    f.clock()
    on_disk = criterion(json.loads(first.read_text()), 'AC-1')
    check(on_disk['status'] == 'human-verified' and on_disk.get('head') == receipt['commit_sha']
          and isinstance(on_disk.get('at'), str),
          'the first cycle receipt is still attested when the next cycle is observed')
    changed = copy.deepcopy(receipt)
    criterion(changed, 'AC-1').update(evidence='edited')
    dump(first, changed)
    f.reject(lambda: f.observe(ok=False), 'next cycle rejects a tampered attested history',
             reason='saved historical receipt is missing or changed')
    dump(first, receipt)
    f.observe()
    check(len(f.state()['review_run']['observations']) == 2,
          'next cycle observation validates the attested history')
finally:
    f.close()

# T-23 / T-24 / T-25: cleanup deletes the saved receipt after the review has
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


for ending in ('review-close', 'review-defer'):
    f = Fixture()
    try:
        f.cycle(roots=[])
        f.flow(ending)
        ended_run = f.state()['review_run']
        drop_receipt(f)
        leave(f)
        state = f.state()
        check(state['issue_number'] == 43 and 'review_run' not in state and state.get('cycle_count', 0) == 0
              and archived_run(state) == ended_run,
              'T-23 (AC-1): a run ended by ' + ending + ' releases the session after cleanup deleted its receipt')
    finally:
        f.close()

f = Fixture()
try:
    f.cycle()
    missing = drop_receipt(f)
    result = leave(f, ok=False)
    check(result.returncode != 0 and str(missing) in result.stderr
          and 'requires completed or deferred review' not in result.stderr,
          'T-24 (AC-2): an unended run still re-reads its receipt when leaving the PR\n' + result.stderr)
    check(f.state()['issue_number'] == 42, 'T-24 (AC-2): the refused switch keeps the current Issue')
    for step in ('at the reviewed commit, run `flow-state.sh review-close` if no blocking finding remains',
                 'review-defer` to keep the draft unresolved',
                 'restore that file unchanged', 'if it cannot be restored, stop the run with `'):
        check(step in result.stderr and 'review-cycle failed' not in result.stderr,
              'T-24: the refusal names the next operation: ' + step + '\n' + result.stderr)
    # Run the stop command exactly as the refusal prints it, so the wording cannot drift from what works.
    named = shlex.split(result.stderr.split('stop the run with `', 1)[1].split('`', 1)[0])
    check(named[0] == 'flow-state.sh' and named[1] == 'set'
          and '--stop-reason' in named and 'circuit-breaker:receipt-missing' in named,
          'T-24: the refusal names the stop command\n' + result.stderr)
    f.flow(*named[1:])
    leave(f)
    archived = archived_run(f.state())
    check(f.state()['issue_number'] == 43 and archived['status'] == 'stopped'
          and archived['stop_reason'] == 'circuit-breaker:receipt-missing',
          'T-24: stopping the run as the refusal says releases the session')
finally:
    f.close()

f = Fixture()
try:
    f.cycle(roots=[])
    receipt = Path(f.state()['review_run']['observations'][-1]['result_path'])
    kept = receipt.read_bytes()
    drop_receipt(f)
    leave(f, ok=False)
    # Restoring the unchanged receipt at the reviewed commit lets the review end as the refusal says.
    receipt.write_bytes(kept)
    f.flow('review-close')
    leave(f)
    check(f.state()['issue_number'] == 43,
          'T-24: restoring the receipt and closing as the refusal says releases the session')
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
          'T-25 (AC-3): a stopped run releases the session without its receipt and keeps its stop')
finally:
    f.close()

# A mergeable review has no finding to fix. A hand commit after it cannot start the
# next review; a recommendation registered in the receipt goes through a verified fix.
f = Fixture()
try:
    f.start()
    f.finish(roots=[], recommendations=[dict(id='R-01', reviewer='code-quality-reviewer', file='source.txt',
                                             line=1, description='comment contradicts the code')])
    f.clock(1)
    f.observe()
    check(f.state()['review_cycle']['verdict'] == 'mergeable', 'recommendation receipt stays mergeable')
    (f.root / 'source.txt').write_text('hand edit\n')
    f.commit()
    f.reject(lambda: f.start(ok=False), 'hand commit after mergeable cannot start the next review',
             'changed HEAD requires completed full fix verification')
    f.run(['git', 'reset', '-q', '--hard', 'HEAD~1'])
    plan = f.plan()
    plan['groups'][0]['finding_ids'] = ['R-02']
    dump(f.plan_path, plan)
    f.reject(lambda: f.scope(ok=False), 'unregistered recommendation ID is refused', 'unknown or duplicate finding IDs')
    second = copy.deepcopy(plan['groups'][0])
    second['root_cause'] = 'another cause'
    plan['groups'] = [dict(plan['groups'][0], finding_ids=['R-01']), dict(second, finding_ids=['R-01'])]
    dump(f.plan_path, plan)
    f.reject(lambda: f.scope(ok=False), 'recommendation in two groups is refused', 'unknown or duplicate finding IDs')
    plan = f.plan()
    plan['groups'][0]['finding_ids'] = ['R-01']
    dump(f.plan_path, plan)
    f.scope()
    (f.root / 'source.txt').write_text('recommendation applied\n')
    f.scope('verify')
    f.commit()
    f.start()
    check(len(f.state()['review_run']['fixes']) == 1, 'recommendation fix is a verified fix for the next review')
finally:
    f.close()

f = Fixture()
try:
    f.start()
    f.finish(recommendations=[dict(id='R-01', reviewer='code-quality-reviewer', file='source.txt',
                                   line=1, description='comment contradicts the code')])
    f.clock(1)
    f.observe()
    f.plan()
    f.reject(lambda: f.scope(ok=False), 'a registered recommendation needs a disposition like a blocking finding',
             'all blocking findings need one disposition')
    plan = f.plan()
    plan['groups'][0]['finding_ids'] = ['F-01', 'R-01']
    dump(f.plan_path, plan)
    f.scope()
finally:
    f.close()

# A user-requested pause closes the open clock segment at the pause and resume opens a new one,
# so the paused time is not counted as work time.
f = Fixture()
try:
    f.start()
    state_dir = f.root / '.rite/state'
    state_dir.mkdir(parents=True, exist_ok=True)
    clock_file = state_dir / ('review-clock-' + f.session + '.json')
    pause_file = state_dir / ('pause-' + f.session + '.json')
    opened = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=600)).strftime('%Y-%m-%dT%H:%M:%SZ')
    dump(clock_file, dict(review_context=f.context(), segment_id='paused-segment', kind='work', started_at=opened))
    f.flow('pause')
    frozen = json.loads(clock_file.read_text())
    check(pause_file.exists() and frozen.get('ended_at') and frozen['segment_id'] == 'paused-segment',
          'pause records the pause and closes the open clock segment')
    f.flow('resume')
    reopened = json.loads(clock_file.read_text())
    saved = [entry for entry in f.state()['review_run']['clock'] if entry['segment_id'] == 'paused-segment']
    check(not pause_file.exists() and len(saved) == 1 and saved[0]['ended_at'] == frozen['ended_at']
          and saved[0]['started_at'] == opened,
          'resume removes the pause record and saves the paused segment with its pause-time end')
    check('ended_at' not in reopened and reopened['segment_id'] != 'paused-segment' and reopened['kind'] == 'work'
          and reopened['review_context'] == f.context() and reopened['started_at'] >= frozen['ended_at'],
          'resume opens a new segment for the same context, starting after the pause')
finally:
    f.close()

# A new segment that cannot be opened on resume still records the paused one, warns, and clears the pause.
f = Fixture()
try:
    f.start()
    state_dir = f.root / '.rite/state'
    state_dir.mkdir(parents=True, exist_ok=True)
    clock_file = state_dir / ('review-clock-' + f.session + '.json')
    pause_file = state_dir / ('pause-' + f.session + '.json')
    opened = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=600)).strftime('%Y-%m-%dT%H:%M:%SZ')
    dump(clock_file, dict(review_context=f.context(), segment_id='failing-segment', kind='work', started_at=opened))
    f.flow('pause')
    stub = f.private / 'mktemp-bin'
    stub.mkdir()
    real_mktemp = shutil.which('mktemp')
    (stub / 'mktemp').write_text('#!/bin/bash\ncase "$*" in *review-clock-*) echo "mktemp: forced failure" >&2; exit 1 ;; esac\nexec ' + real_mktemp + ' "$@"\n')
    (stub / 'mktemp').chmod(0o755)
    saved_path = f.env['PATH']
    f.env['PATH'] = str(stub) + os.pathsep + saved_path
    try:
        result = f.flow('resume')
    finally:
        f.env['PATH'] = saved_path
    saved = [entry for entry in f.state()['review_run']['clock'] if entry['segment_id'] == 'failing-segment']
    check(len(saved) == 1 and not pause_file.exists() and not clock_file.exists()
          and 'could not open a new one' in result.stderr,
          'resume that cannot open a new segment still records the paused one, warns and clears the pause')
finally:
    f.close()

# Python bytecode rewritten by a test run after verification does not stop the
# commit or the next review; an ignored non-bytecode file in the same input
# directory still does.
def bytecode_fixture(command, tracked_runtime=False):
    f = Fixture()
    f.env.pop('PYTHONDONTWRITEBYTECODE', None)
    with open(f.root / '.git/info/exclude', 'a') as exclude:
        exclude.write('__pycache__/\nbuild.log\n')
    (f.root / 'pkg').mkdir()
    (f.root / 'pkg/m.py').write_text('x = 1\n')
    f.run(['git', 'add', 'pkg/m.py'])
    if tracked_runtime:
        (f.root / '.rite/plugin-root').write_text('plugin before verification\n')
        f.run(['git', 'add', '-f', '.rite/plugin-root'])
    f.commit()
    f.cycle()
    plan = f.plan()
    plan['groups'][0]['verification_ids'] = ['full', 'related']
    plan['verifications'][0].update(command=command, inputs=['source.txt', 'pkg'])
    plan['verifications'].append(dict(id='related', kind='related', command='test -s pkg/m.py',
                                      inputs=['pkg'], environment=[]))
    dump(f.plan_path, plan)
    f.scope()
    (f.root / 'source.txt').write_text('repaired\n')
    return f


# Sandbox anchors may appear or disappear between verification and the next review.
for action in ('same-head', 'add', 'delete'):
    f = Fixture() if action == 'same-head' else bytecode_fixture('test -s source.txt')
    try:
        if action == 'same-head':
            f.cycle()
            f.plan()
            f.scope()
        stubs = [f.root / '.sandbox-stub', f.root / 'sandbox dir' / 'quote"tab\tline\n']
        stubs[1].parent.mkdir()
        def add_stubs():
            for stub in stubs:
                stub.touch()
                stub.chmod(0o444)
        if action != 'add':
            add_stubs()
        f.scope('verify')
        if action == 'add':
            add_stubs()
        elif action == 'delete':
            for stub in stubs:
                stub.unlink()
        if action != 'same-head':
            f.commit()
        before = f.state()['review_run']
        result = f.start()
        after = f.state()['review_run']
        if action != 'delete':
            check('2 sandbox stub file(s)' in result.stderr
                  and all(json.dumps(str(p.relative_to(f.root)), ensure_ascii=False) in result.stderr for p in stubs),
                  'sandbox stubs are named and counted on stderr: ' + action)
        check(len(after['fixes']) == len(before['fixes']) + (action != 'same-head'),
              'only a changed verified HEAD counts as a fix: ' + action)
        check(('pending_fix' in after) == (action == 'same-head'),
              'stub changes preserve the verified tree and consume only a committed fix: ' + action)
    finally:
        f.close()


# Real untracked and tracked changes must still stop the next cycle, even beside a stub.
for kind in ('writable-empty', 'readonly-nonempty', 'stub-link', 'device-link', 'staged-stub', 'tracked-change'):
    f = bytecode_fixture('test -s source.txt')
    try:
        f.scope('verify')
        f.commit()
        stub = f.root / '.sandbox-stub'
        stub.touch()
        stub.chmod(0o444)
        other = f.root / 'sandbox dir' / 'real change'
        other.parent.mkdir()
        if kind == 'stub-link':
            other.symlink_to(stub)
        elif kind == 'device-link':
            other.symlink_to('/dev/null')
        elif kind == 'tracked-change':
            (f.root / 'source.txt').write_text('uncommitted change\n')
        else:
            other.write_text('content' if kind == 'readonly-nonempty' else '')
            if kind in ('readonly-nonempty', 'staged-stub'):
                other.chmod(0o444)
            if kind == 'staged-stub':
                f.run(['git', 'add', str(other.relative_to(f.root))])
        before = f.state()
        f.reject(lambda: f.start(ok=False), 'real change remains dirty: ' + kind,
                 'next review requires a committed clean verified tree')
        check(f.state() == before, 'a rejected dirty tree preserves the review state: ' + kind)
    finally:
        f.close()


f = Fixture()
try:
    probe = [sys.executable, '-c', '''
import importlib, os, stat, sys
from unittest.mock import patch
sys.path.insert(0, sys.argv[1])
stagnation = importlib.import_module("review-stagnation")
scope = importlib.import_module("review-fix-scope")
with patch.object(scope.os, "stat", side_effect=PermissionError):
    assert not stagnation.sandbox_untracked(), "stat failures must not be excluded"
real_stat = os.stat
def device_stat(path, *args, **kwargs):
    if str(path) == "device":
        return os.stat_result((stat.S_IFCHR | 0o666, 0, 0, 1, 0, 0, 0, 0, 0, 0))
    return real_stat(path, *args, **kwargs)
with patch.object(scope.os, "stat", side_effect=device_stat):
    assert stagnation.sandbox_untracked() == {"device"}, "only a real device is excluded"
''', str(plugin / 'hooks/scripts/lib')]
    (f.root / 'device').touch()
    (f.root / 'link').symlink_to('device')
    f.run(probe)
finally:
    f.close()


def import_pkg(f):
    f.run([sys.executable, '-c', 'import sys; sys.path.insert(0, "pkg"); import m'])


def rewrite_bytecode(f, label):
    caches = sorted((f.root / 'pkg/__pycache__').glob('*.pyc'))
    check(caches, label + ': the test run left bytecode in the input directory')
    before = [hashlib.sha256(p.read_bytes()).hexdigest() for p in caches]
    for p in caches:
        p.write_bytes(p.read_bytes() + b'rewritten')
    check(before != [hashlib.sha256(p.read_bytes()).hexdigest() for p in caches], label + ': bytecode rewritten')


GENERATE = 'python3 -c "import sys; sys.path.insert(0, \'pkg\'); import m" && test -s source.txt'
f = bytecode_fixture(GENERATE)
try:
    verified_run = f.scope('verify')
    check('FIX_VERIFICATION=executed; id=full' in verified_run.stdout,
          'a verification that writes bytecode into its input directory passes')
finally:
    f.close()

f = bytecode_fixture('test -s source.txt')
try:
    import_pkg(f)
    f.scope('verify')
    rewrite_bytecode(f, 'before commit')
    f.run(['bash', str(plugin / 'hooks/scripts/review-fix-scope-check.sh'), 'commit-check',
           '--command', 'git commit -m fixture', '--cwd', str(f.root)])
    reused = f.run(['bash', str(plugin / 'hooks/scripts/review-fix-scope-check.sh'), 'verify',
                    '--plan', str(f.plan_path), '--issue', str(f.issue_path), '--kind', 'related'])
    check('FIX_VERIFICATION=reused; id=related' in reused.stdout, 'rewritten bytecode keeps the related result reusable')
    f.commit()
    rewrite_bytecode(f, 'after commit')
    fixes = len(f.state()['review_run']['fixes'])
    f.start()
    run = f.state()['review_run']
    head = f.run(['git', 'rev-parse', 'HEAD']).stdout.strip()
    check(len(run['fixes']) == fixes + 1 and run['fixes'][-1]['commit_sha'] == head and 'pending_fix' not in run,
          'review-start counts the verified fix after the bytecode changed')
finally:
    f.close()

f = bytecode_fixture('test -s source.txt')
try:
    f.scope('verify')
    f.commit()
    (f.root / 'pkg/build.log').write_text('changed\n')
    fixes = len(f.state()['review_run']['fixes'])
    f.reject(lambda: f.start(ok=False), 'an ignored non-bytecode input file still stops review-start',
             'fix verification inputs or receipt changed')
    check(len(f.state()['review_run']['fixes']) == fixes, 'the rejected review-start counts no fix')
finally:
    f.close()

# In the recorded session worktree the verified-tree check still runs: content committed after
# the verification is refused by its own diagnosis, not by the location check.
f = bytecode_fixture('test -s source.txt')
try:
    f.scope('verify')
    (f.root / 'source.txt').write_text('changed after verification\n')
    f.commit()
    recorded = f.state()
    recorded['worktree'] = str(f.root.resolve())
    dump(f.state_path, recorded)
    after_change = f.start(ok=False)
    check(after_change.returncode != 0 and 'HEAD content differs from verified fix tree' in after_change.stderr
          and 'wrong working directory' not in after_change.stderr,
          'review-start in the recorded worktree still refuses content that differs from the verified fix tree')
finally:
    f.close()

# Runtime state must not change the verified tree when its ignore rules change.
for action in ('ignore', 'add', 'change', 'delete', 'tracked'):
    f = bytecode_fixture('test -s source.txt', tracked_runtime=action == 'tracked')
    try:
        runtime = f.root / '.rite'
        runtime.mkdir(exist_ok=True)
        marker = runtime / 'plugin-root'
        if action != 'add':
            marker.write_text('plugin before verification\n')
        if action == 'ignore':
            exclude = f.root / '.git/info/exclude'
            exclude.write_text(exclude.read_text().replace('.rite/\n', ''))
        f.scope('verify')
        f.commit()
        if action == 'ignore':
            (runtime / '.gitignore').write_text('*\n')
        elif action == 'delete':
            marker.unlink()
        else:
            marker.write_text('plugin after verification\n')
        if action == 'tracked':
            f.run(['git', 'add', '-f', '.rite/plugin-root'])
            f.commit()
        fixes = len(f.state()['review_run']['fixes'])
        f.start()
        run = f.state()['review_run']
        check(len(run['fixes']) == fixes + 1 and 'pending_fix' not in run,
              'review-start accepts verified code after runtime state action: ' + action)
    finally:
        f.close()

# Unignored runtime state is excluded even before the ignore file exists.
f = Fixture()
try:
    (f.root / '.git/info/exclude').write_text('')
    fingerprint = [sys.executable, '-c',
                   'import importlib, sys; sys.path.insert(0, sys.argv[1]); '
                   'print(importlib.import_module("review-stagnation").tree_fingerprint())',
                   str(plugin / 'hooks/scripts/lib')]
    before = f.run(fingerprint).stdout
    marker = f.root / '.rite/plugin-root'
    for content in ('plugin one\n', 'plugin two\n', None):
        if content is None:
            marker.unlink()
        else:
            marker.write_text(content)
        check(f.run(fingerprint).stdout == before, 'unignored runtime marker does not affect the tree fingerprint')
    (f.root / '.rite/.gitignore').write_text('*\n')
    check(f.run(fingerprint).stdout == before, 'creating runtime ignore rules does not affect the tree fingerprint')
finally:
    f.close()

# T-27: a purpose deviation on a line the PR added reopens a mergeable review of the
# same run for an ordinary fix and re-review; anything else is refused unchanged.
def deviation_review(cap=None, roots=()):
    f = Fixture()
    exclude = f.root / '.git/info/exclude'
    exclude.write_text(exclude.read_text() + 'rite-config.yml\n')
    config = 'branch:\n  base: develop\n'
    if cap:
        config += 'safety:\n  max_review_cycles: ' + str(cap) + '\n'
    (f.root / 'rite-config.yml').write_text(config)
    # Base: line 2 is removed and lines 3-4 are added, so only new lines 3-4 are the PR's.
    (f.root / 'source.txt').write_text('initial\nremove me\nkeep\n')
    f.commit()
    f.run(['git', 'update-ref', 'refs/remotes/origin/develop', 'HEAD'])
    (f.root / 'source.txt').write_text('initial\nkeep\nadded one\nadded two\n')
    f.commit()
    f.start()
    f.finish(roots=list(roots))
    f.clock(0)
    f.observe()
    return f


def deviate(f, ok=True, relative=False, **fields):
    record = dict(requirement='MUST NOT: rewrite protected content', file='source.txt', line=3,
                  description='the PR rewrote protected content')
    record.update(fields)
    record = {key: value for key, value in record.items() if value is not None}
    path = f.private / 'deviation.json'
    dump(path, record)
    return f.flow('review-deviate', '--input', path.relative_to(f.root) if relative else path, ok=ok)


def external_plan(f, *ids):
    plan = f.plan()
    plan['groups'][0]['finding_ids'] = list(ids) or ['E-01']
    plan['external_findings'] = [dict(id='E-01', thread_id='thread-1', description='human review thread')]
    dump(f.plan_path, plan)


f = deviation_review()
try:
    f.flow('review-close')
    # pr-review leaves this completion handoff; a deviation must not be sent back to the completion notice.
    f.flow('set', '--phase', f.state()['phase'], '--next', 'finalize', '--handoff', 'FINALIZE:review:mergeable:71')
    context = f.context()
    run_id = f.state()['review_run']['run_id']
    check(f.state()['review_run']['completed_context'] == context and 'handoff' in f.state(),
          'T-27: the review closed as mergeable with its completion handoff')
    external_plan(f)
    f.scope()
    deviate(f, line=3)
    state = f.state()
    run = state['review_run']
    check(state['phase'] == 'fix' and state['active'] is True and 'handoff' not in state
          and 'stop_reason' not in state and state['next_action'] == '/rite:fix 71',
          'T-27: the deviation hands the same PR to fix')
    check('completed_context' not in run, 'T-27: the closed record is withdrawn until the deviation is fixed')
    check([(d['id'], d['file'], d['line'], d['end'], d['review_context']) for d in run['deviations']]
          == [('D-01', 'source.txt', 3, 3, context)]
          and run['deviations'][0]['requirement'].startswith('MUST NOT'), 'T-27: D-01 records where and what')
    deviate(f, line=3)
    check(len(f.state()['review_run']['deviations']) == 1, 'T-27: replaying the same deviation adds nothing')
    deviate(f, line=4)
    check([d['id'] for d in f.state()['review_run']['deviations']] == ['D-01', 'D-02'],
          'T-27: the last added line is the PR\'s and numbers the next deviation')
    result = f.scope(ok=False)
    check(result.returncode != 0 and 'all blocking findings need one disposition' in result.stderr,
          'T-27: a plan that leaves the deviations undisposed is refused:\n' + result.stderr)
    f.reject(lambda: f.flow('set', '--phase', 'init', '--next', 'x', '--issue', 43, '--pr', 0, ok=False),
             'T-27: the session cannot switch away with the deviation unfixed', 'requires completed or deferred review')
    external_plan(f, 'D-01', 'D-02')
    dump(f.plan_path, dict(json.loads(f.plan_path.read_text()), external_findings=[]))
    f.scope()
    # A fix that returns without a commit leaves the same HEAD; it is not handed over again.
    f.reject(lambda: deviate(f, ok=False, line=4, description='found again'),
             'T-27: a review whose deviations a fix plan disposed is not reopened', 'not handed over again')
    check([d['id'] for d in f.state()['review_run']['deviations']] == ['D-01', 'D-02'],
          'T-27: the refused deviation records nothing')
    (f.root / 'source.txt').write_text('initial\nkeep\nrestored\n')
    f.scope('verify')
    f.commit()
    f.start()
    state = f.state()
    check(state['cycle_count'] == 2 and state['review_run']['run_id'] == run_id
          and len(state['review_run']['fixes']) == 1, 'T-27: the fix commit is re-reviewed in the same run')
    f.finish(roots=())
    f.clock(0)
    f.observe()
    # The last plan record still disposes the first review's deviations; a new review is not refused by it.
    deviate(f, line=3)
    check([d['id'] for d in f.state()['review_run']['deviations'] if d['review_context'] == f.context()] == ['D-01'],
          'T-27: a deviation of the next review is recorded and numbered from D-01')
    # Deviations bind to the review they were recorded against, not to later plans.
    external_plan(f, 'D-01')
    dump(f.plan_path, dict(json.loads(f.plan_path.read_text()), external_findings=[]))
    f.scope()
finally:
    f.close()

f = deviation_review()
try:
    for label, fields, reason in (
            ('an unchanged line', dict(line=2), 'not point at a line this PR added'),
            ('the line after the added hunk', dict(line=5), 'not point at a line this PR added'),
            ('a file outside the diff', dict(file='other.txt', line=1), 'not point at a line this PR added'),
            ('a missing requirement', dict(requirement=None), 'deviation requirement required'),
            ('an inverted range', dict(line=4, end=3), 'positive line or range')):
        f.reject(lambda: deviate(f, ok=False, **fields), 'T-27: ' + label + ' is refused', reason)
    f.reject(lambda: deviate(f, ok=False, relative=True), 'T-27: a relative input is refused',
             'input must be an absolute file path')
    (f.root / 'source.txt').write_text('initial\nkeep\nadded one\nadded two\nlater\n')
    f.commit()
    f.reject(lambda: deviate(f, ok=False), 'T-27: a commit after the review is refused', 'HEAD differs')
finally:
    f.close()

for label, fixture, reason in (
        ('blocking findings', lambda: deviation_review(roots=['input defect']), 'still has blocking findings'),
        ('the max-cycles review', lambda: deviation_review(cap=1), 'max_review_cycles')):
    f = fixture()
    try:
        f.reject(lambda: deviate(f, ok=False), 'T-27: a review with ' + label + ' is refused', reason)
    finally:
        f.close()

# A linked worktree has no copy of the untracked config; the cap comes from the main checkout's.
f = deviation_review(cap=1)
try:
    linked = f.root / '.rite/linked'
    f.run(['git', 'worktree', 'add', '-q', '--detach', str(linked), 'HEAD'])
    record = f.private / 'deviation.json'
    dump(record, dict(requirement='MUST NOT: rewrite protected content', file='source.txt', line=3,
                      description='the PR rewrote protected content'))
    result = subprocess.run(['bash', str(plugin / 'hooks/flow-state.sh'), 'review-deviate', '--input', str(record)],
                            cwd=linked, env=f.env, text=True, capture_output=True)
    check(result.returncode != 0 and 'max_review_cycles' in result.stderr,
          'T-27: a linked worktree reads the cap from the main checkout config:\n' + result.stdout + result.stderr)
    check('deviations' not in f.state()['review_run'], 'T-27: the refused deviation in a linked worktree records nothing')
finally:
    f.close()

check_section = iterate.split('### 5.S 後の完了前確認（目的整合）', 1)[1].split('\n---\n', 1)[0]
check(check_section.index('review-deviate') < check_section.index('/rite:fix {pr_number}')
      < check_section.index('ステップ 1 で再レビュー'),
      'T-27: a deviation on a PR-added line is recorded, fixed, then re-reviewed')
check('iterate-step.sh purpose-unaligned' in check_section and '`D-NN` だけが例外' in check_section,
      'T-27: any other deviation still stops, and only recorded D-NN reach the fix plan')
check('"file": リポジトリルートからの相対パス（git diff の表記）' in check_section,
      'T-27: the deviation file is written the way the helper matches it against the diff')

f = deviation_review()
try:
    f.flow('set', '--phase', 'review', '--next', 'stop', '--active', 'false',
           '--stop-reason', 'circuit-breaker:max-cycles')
    f.reject(lambda: deviate(f, ok=False), 'T-27: a stopped run is refused', 'review run stopped')
finally:
    f.close()

print('PASS: review stagnation cleanup: ' + str(stagnation_fixture.checks) + ' assertions; real clocks, receipts, repairs and retained stops')
PYTEST
