#!/bin/bash
# Exercise persisted classification, error atomicity and archived review cycles.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
python3 - "$SCRIPT_DIR" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

scripts = Path(sys.argv[1])
target = scripts.parent / 'review-findings-maps.sh'
checks = 0
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    source = root / 'review.json'
    def run(document=None, reason=None, path=None, env=None):
        global checks
        if document is not None:
            source.write_text(json.dumps(document))
        before = source.read_bytes() if source.exists() else None
        result = subprocess.run(['bash', str(target), '--review-source', 'local_file',
                                 '--review-source-path', str(path or source), '--repo-root', str(root)],
                                text=True, capture_output=True, timeout=10, env=env)
        if reason:
            assert result.returncode != 0, result
            assert f'[fix:error] reason={reason}; findings=' in result.stdout, result
            assert source.read_bytes() == before, 'failure mutated source'
        else:
            assert result.returncode == 0, result
            assert 'FIX_FATAL_TRIAGE=applied' in result.stderr, result
        checks += 1
        return result
    def finding(id, severity='HIGH', scope='current-pr', measured=True):
        return dict(id=id, file='src/shared.ts', line=None, severity=severity, scope=scope,
                    verification=dict(measured=measured, evidence=['retained']), suggestion='retained')

    # Exercise the severity, scope and measured boundaries separately.
    matrix_fatal = [finding(f'F-{i}', s, scope) for i, (s, scope) in enumerate([
        ('CRITICAL','current-pr'), ('HIGH','current-pr'), ('HIGH','follow-up'),
        ('CRITICAL','follow-up'), ('HIGH','current-pr'), ('CRITICAL','current-pr')])]
    matrix_nonfatal = [finding(f'N-{i}', s, scope, measured) for i, (s, scope, measured) in enumerate([
        ('HIGH','current-pr',False), ('CRITICAL','follow-up',False),
        ('MEDIUM','current-pr',True), ('MEDIUM','follow-up',True),
        ('LOW-MEDIUM','current-pr',True), ('LOW','current-pr',True),
        ('LOW','follow-up',True), ('MEDIUM','current-pr',False),
        ('LOW-MEDIUM','follow-up',False), ('LOW','current-pr',False),
        ('HIGH','follow-up',False), ('CRITICAL','current-pr',False),
        ('MEDIUM','follow-up',False), ('LOW-MEDIUM','current-pr',False),
        ('LOW','follow-up',False)])]
    matrix = matrix_fatal + matrix_nonfatal
    matrix_result = json.loads(run(dict(findings=matrix)).stdout)
    assert matrix_result['fatal_map'] == {**{f['id']:True for f in matrix_fatal}, **{f['id']:False for f in matrix_nonfatal}}

    # The measured mixed review keeps six HIGH and moves eleven MEDIUM plus four LOW.
    fatal = [finding(f'H-{i}') for i in range(6)]
    nonfatal = [finding(f'M-{i}', 'MEDIUM') for i in range(11)] + [finding(f'L-{i}', 'LOW') for i in range(4)]
    prior = dict(id='old', arbitrary={'keep':[1,2]})
    doc = dict(metadata={'keep':'yes'}, findings=fatal+nonfatal, non_blocking_findings=[prior])
    result = run(doc)
    assert 'fatal=6; moved=15' in result.stderr
    maps = json.loads(result.stdout)
    assert maps['fatal_map'] == {**{f['id']:True for f in fatal}, **{f['id']:False for f in nonfatal}}
    saved = json.loads(source.read_text())
    assert saved['findings'] == fatal
    assert saved['non_blocking_findings'] == [prior]+[dict(f,demotion_reason='non_fatal') for f in nonfatal]
    assert saved['metadata'] == doc['metadata']
    result = run()  # A fresh process reloads the persisted source.
    assert 'fatal=6; moved=0' in result.stderr
    assert json.loads(source.read_text()) == saved
    assert json.loads(result.stdout)['fatal_map'] == {f['id']:True for f in fatal}

    nit = finding('nit', 'HIGH', 'nit-noted')
    del nit['verification']
    nit['pre_existing'] = False
    run(dict(findings=[nit]))
    assert json.loads(source.read_text()) == dict(findings=[nit])
    for group, counts in [(fatal,'fatal=6; moved=0'), (nonfatal,'fatal=0; moved=15'), ([], 'fatal=0; moved=0')]:
        assert counts in run(dict(findings=group)).stderr

    for measured in [None, 'true', 1, [], {}]:
        bad = finding('bad', measured=measured)
        result = run(dict(findings=[fatal[0],bad,nonfatal[0]]), 'measured_undetermined')
        assert 'findings=bad' in result.stdout
    bad = finding('missing'); del bad['verification']
    run(dict(findings=[bad]), 'measured_undetermined')
    for verification in [None, [], 'true', 1]:
        bad = finding('bad-verification'); bad['verification'] = verification
        run(dict(findings=[bad]), 'measured_undetermined')
    for key, value, reason in [('severity','high','severity_enum_violation'),
                               ('severity',None,'severity_enum_violation'),
                               ('scope','unknown','scope_enum_violation'),
                               ('scope',None,'scope_enum_violation')]:
        bad = finding('invalid'); bad[key] = value
        run(dict(findings=[bad]),reason)
    run(dict(findings=[finding('dup'),finding('dup')]),'finding_id_duplicate')
    source.write_text('{broken')
    run(reason='invalid_review_json')
    run(dict(findings=[]), 'invalid_review_json', path=root/'absent.json')

    # Inject actual write/rename failures without relying on current-user permissions.
    bin_dir = root/'bin'; bin_dir.mkdir()
    for command in ['mktemp','mv']:
        stub=bin_dir/command; stub.write_text('#!/bin/sh\nexit 1\n'); stub.chmod(0o755)
        run(doc, 'io_error', env=dict(os.environ, PATH=str(bin_dir)+os.pathsep+os.environ['PATH']))
        stub.unlink()
        assert not list(root.glob('review.json.triage.*')), 'tempfile leaked'

    archive=json.loads((scripts/'fixtures/fatal-triage-archive.json').read_text())
    observed=[]
    for cycle in archive['cycles']:
        output=json.loads(run(cycle).stdout)
        observed.append(sum(output['fatal_map'].values()))
        persisted=json.loads(source.read_text())
        run()
        assert json.loads(source.read_text()) == persisted
    assert observed == archive['expected_fatal'] == [0,0,1,0]
    assert sum(bool(c['findings']) for c in archive['cycles']) == 4
    assert sum(bool(n) for n in observed) == 1
    print('Archived cycle eligibility: 4 before, 1 after (classification replay, not a live cycle prediction).')
print(f'{checks} helper invocations passed')
PY
