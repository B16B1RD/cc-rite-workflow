#!/bin/bash
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
FIX="$ROOT/plugins/rite/skills/fix/SKILL.md"
REVIEW="$ROOT/plugins/rite/skills/pr-review/SKILL.md"
pass=0
fail=0

check() {
  label=$1 pattern=$2 file=$3
  if grep -qF "$pattern" "$file"; then
    echo "  ✅ $label"; pass=$((pass + 1))
  else
    echo "  ❌ $label"; fail=$((fail + 1))
  fi
}

check "fix は file JSON の receipt を検査" '.measured_gate.commit_sha == .commit_sha' "$FIX"
check "fix は未適用 JSON で停止" '[fix:error] reason=gate_not_applied' "$FIX"
check "pr-review は incremental も連続レール" 'full / incremental を問わない単一の連続レール' "$REVIEW"
check "pr-review は gate helper を実行" 'bash {plugin_root}/scripts/review-measured-gate.sh' "$REVIEW"
check "pr-review は検証済み終了操作を実行" 'bash {plugin_root}/hooks/flow-state.sh review-finish' "$REVIEW"
check "終了操作は既存 saver を再利用" 'str(hooks / "review-result-save.sh")' "$ROOT/plugins/rite/hooks/scripts/lib/review-cycle.py"
if bash "$ROOT/plugins/rite/hooks/tests/review-cycle-caller.test.sh"; then
  echo '  ✅ documented review-finish saves through the real saver'; pass=$((pass + 1))
else
  echo '  ❌ documented review-finish persistence'; fail=$((fail + 1))
fi

# Execute the documented callers so a zero exit from a failed record cannot pass.
if python3 - "$ROOT" <<'PY_CHECK'
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
fix = (root / 'plugins/rite/skills/fix/SKILL.md').read_text()
common = fix.split('### 1.2.2 Common Fatal Triage and Recording', 1)[1].split('### 1.3 Classify Comments', 1)[0]
blocks = re.findall(r'```bash\n(.*?)\n```', common, re.S)
triage = next(b for b in blocks if 'review-findings-maps.sh' in b)
materialize = next(b for b in blocks if '# fix-conversation-review-json' in b)
record = re.search(r'```bash\n(.*?)\n```', (root / 'plugins/rite/skills/fix/references/non-fatal-record.md').read_text(), re.S).group(1)
# The ledger splice must stop on failure, not fall through to an unspliced PATCH.
assert 'reason=nonblocking_record_ledger_extract_failed' in record
assert 'reason=nonblocking_record_ledger_merge_failed' in record
assert not [l for l in record.splitlines() if 'nb-sweep-ledger.sh' in l and '|| true' in l]
with tempfile.TemporaryDirectory() as temp:
    temp = Path(temp)
    plugin = temp / 'plugin'
    (plugin / 'scripts').mkdir(parents=True)
    (plugin / 'hooks/scripts').mkdir(parents=True)
    (plugin / 'scripts/review-findings-maps.sh').symlink_to(root / 'plugins/rite/scripts/review-findings-maps.sh')
    (plugin / 'hooks/scripts/nb-sweep-ledger.sh').symlink_to(root / 'plugins/rite/hooks/scripts/nb-sweep-ledger.sh')
    source = temp / 'review.json'
    values = {'plugin_root': str(plugin), 'triage_review_path': str(source),
              'triage_helper_source': 'explicit_file', 'pr_number': '42',
              'owner_repo': 'owner/repo', 'review_cycle_id': '42-test', 'non_fatal_moved_count': '1'}
    # gh stub: answers only the calls the real record helper's read-only mode makes, so a real gh is
    # never reached. The helper selects the record comment itself, so the selection is tested too.
    stub_dir = temp / 'bin'
    stub_dir.mkdir()
    gh_log = temp / 'gh-calls'
    pr_json = temp / 'pr.json'
    comments = temp / 'comments.json'
    (stub_dir / 'gh').write_text(f"""#!/bin/bash
printf '%s\\n' "$*" >> '{gh_log}'
case "$1 $2" in
  'pr view')
    case " $* " in *' headRefName '*) jq -r '.headRefName' '{pr_json}' ;; *) jq -r '.body' '{pr_json}' ;; esac
    exit 0 ;;
  'api user') printf 'rite-bot\\n'; exit 0 ;;
  'issue view') exit 0 ;;
esac
if [ "$*" = "api --paginate --slurp repos/owner/repo/issues/7/comments" ]; then
  [ -f '{temp}/comments-fail' ] && exit 1
  exec jq '[.]' '{comments}'
fi
case "$1 $2" in
  'api repos/owner/repo/issues/comments/'*) exec jq --argjson id "${{2##*/}}" '.[] | select(.id == $id)' '{comments}' ;;
esac
exit 97
""")
    (stub_dir / 'gh').chmod(0o755)
    env = {**os.environ, 'PATH': f"{stub_dir}:{os.environ['PATH']}"}
    ledger_row = '| F-09 | b.sh:3 | recorded | severity=LOW; measured=false |'
    # A non-record comment carrying a ledger comes first: taking it instead of the record must fail.
    other_comment = '\n'.join([
        'progress note', '', '### 却下台帳', '', '| finding_id | file:line | 判定 | 判定文 |',
        '|------------|-----------|------|--------|', '| F-77 | z.sh:1 | recorded | severity=LOW; measured=false |', ''])
    record_with_ledger = '\n'.join([
        '## 📜 rite 非実測指摘の記録 (non-blocking)', '', 'old', '',
        '### 却下台帳', '', '| finding_id | file:line | 判定 | 判定文 |',
        '|------------|-----------|------|--------|', ledger_row, '',
        '📎 non_blocking_count: 0', '', '<!-- rite:nbr:v1 -->', ''])
    record_without_ledger = '\n'.join([
        '## 📜 rite 非実測指摘の記録 (non-blocking)', '', 'old', '',
        '📎 non_blocking_count: 0', '', '<!-- rite:nbr:v1 -->', ''])
    # An older duplicate record (ledger F-55) and a same-marker comment by another author (ledger F-66)
    # surround the record the helper PATCHes: only its ledger may be carried.
    def ledger_record(row):
        return record_with_ledger.replace(ledger_row, row)
    def comment(cid, body, login='rite-bot'):
        return {'id': cid, 'user': {'login': login}, 'body': body}
    stale_row = '| F-55 | old.sh:1 | recorded | severity=LOW; measured=false |'
    foreign_row = '| F-66 | x.sh:1 | recorded | severity=LOW; measured=false |'
    existing_with_ledger = json.dumps([
        comment(1, ledger_record(stale_row)), comment(2, other_comment), comment(3, record_with_ledger),
        comment(4, ledger_record(foreign_row), 'someone-else')])
    existing_without_ledger = json.dumps([comment(2, other_comment), comment(3, record_without_ledger)])
    def set_pr(body, head):
        pr_json.write_text(json.dumps({'body': body, 'headRefName': head}))
    set_pr('Closes #7', 'fix/issue-8-other')
    comments.write_text(existing_with_ledger)
    def run(block, extra_env=None):
        for key, value in values.items():
            block = block.replace('{' + key + '}', value)
        return subprocess.run(['bash', '-c', block], text=True, capture_output=True, timeout=10,
                              env={**env, **(extra_env or {})})
    findings = [{'id':'F-01', 'severity':'MEDIUM', 'scope':'current-pr', 'file':'a.sh', 'line':1,
                 'reviewer':'test-reviewer', 'description':'private-detail', 'verification':{'measured':True},
                 'consequence_class':'B'}]
    source.write_text(json.dumps({'findings': findings}))
    result = run(triage)
    assert result.returncode == 0, result
    assert json.loads(source.read_text())['findings'] == []
    assert json.loads(result.stdout)['fatal_map'] == {'F-01':False}
    assert 'FIX_TRIAGE_REVIEW_PATH=' in result.stderr

    # The conversation route copies the saved review JSON of HEAD, so the gate-written
    # class reaches triage instead of being lost by the report table.
    state = temp / 'state'
    results = state / '.rite/review-results'
    results.mkdir(parents=True)
    copier = temp / 'copier'
    (copier / 'hooks/scripts').mkdir(parents=True)
    for name in ('review-save-json-verify.sh', 'lib'):
        (copier / 'hooks/scripts' / name).symlink_to(root / 'plugins/rite/hooks/scripts' / name)
    (copier / 'hooks/state-path-resolve.sh').write_text(f"#!/bin/bash\nprintf '%s\\n' '{state}'\n")
    repo = temp / 'repo'
    repo.mkdir()
    git = ['git', '-C', str(repo), '-c', 'user.name=t', '-c', 'user.email=t@example.invalid', '-c', 'commit.gpgsign=false']
    subprocess.run(['git', 'init', '-q', str(repo)], check=True)
    subprocess.run(git + ['commit', '-q', '--allow-empty', '-m', 'reviewed'], check=True)
    sha = subprocess.run(git + ['rev-parse', 'HEAD'], text=True, capture_output=True, check=True).stdout.strip()
    saved_review = {'commit_sha': sha, 'findings': [
        {'id': 'F-01', 'severity': 'MEDIUM', 'scope': 'current-pr', 'file': 'a.sh', 'line': 1,
         'verification': {'measured': True}, 'consequence_class': 'A'}],
        'non_blocking_findings': [], 'acceptance_criteria': {'skipped': 'no_ac_section'},
        'measured_gate': {'commit_sha': sha, 'applied_at': '2026-01-01T00:00:00Z',
                          'blocking': 1, 'demoted': 0, 'anchor_undetermined': 0}}
    def copy_block(plugin_dir):
        block = materialize
        for key, value in {'plugin_root': str(plugin_dir), 'pr_number': '42', 'review_source': 'conversation'}.items():
            block = block.replace('{' + key + '}', value)
        assert not re.search(r'\{[a-z_]+\}', block), block
        return subprocess.run(['bash', '-c', block], text=True, capture_output=True, timeout=30, cwd=repo)
    def copy_run():
        result = copy_block(copier)
        assert result.returncode == 0, result
        # Only the fix marker is emitted: helper markers of pr-review 8.0.4 are not re-emitted.
        lines = result.stderr.splitlines()
        assert len(lines) == 1 and lines[0].startswith('[CONTEXT] FIX_MATERIALIZED_JSON='), result
        return lines[0].split('=', 1)[1]
    def copy_fail(plugin_dir, reason):
        before = sorted(results.iterdir())
        result = copy_block(plugin_dir)
        assert result.returncode == 1 and f'[fix:error] reason={reason}' in result.stdout, result
        assert 'FIX_MATERIALIZED_JSON=' not in result.stderr, result
        assert sorted(results.iterdir()) == before, result
        return result
    assert copy_run() == ''  # nothing saved yet: the caller falls back to the table
    # A saved JSON of another commit is never borrowed.
    (results / '42-20260101000000.json').write_text(json.dumps(
        dict(saved_review, commit_sha='b' * 40, measured_gate=dict(saved_review['measured_gate'], commit_sha='b' * 40))))
    assert copy_run() == ''
    # A missing helper is a failure, not "no saved JSON": the block stops with the helper output.
    broken = temp / 'broken'
    (broken / 'hooks/scripts').mkdir(parents=True)
    failed = copy_fail(broken, 'conversation_json_verify_failed')
    assert 'review-save-json-verify.sh' in failed.stderr, failed
    (results / '42-20260101000001.json').write_text(json.dumps(saved_review))
    # A copy that cannot be written stops instead of falling back to the table.
    results.chmod(0o555)
    try:
        copy_fail(copier, 'conversation_json_copy_failed')
    finally:
        results.chmod(0o755)
    copied = Path(copy_run())
    assert copied.parent == results and copied.name.startswith('42-') and copied.name != '42-20260101000001.json'
    assert json.loads(copied.read_text()) == dict(saved_review, producer='fix', review_source='conversation')
    triaged = subprocess.run(['bash', str(root / 'plugins/rite/scripts/review-findings-maps.sh'),
                              '--review-source', 'local_file', '--review-source-path', str(copied)],
                             text=True, capture_output=True, timeout=30)
    assert triaged.returncode == 0 and json.loads(triaged.stdout)['fatal_map'] == {'F-01': True}, triaged
    saved = source.read_bytes()
    stub = plugin / 'hooks/review-nonblocking-record.sh'
    record_body = temp / 'record-body'
    count_arg = temp / 'count-arg'
    real_helper = root / 'plugins/rite/hooks/review-nonblocking-record.sh'
    def set_outcome(outcome):
        stub.write_text("""#!/bin/bash
[ "$1" = --print-record-body ] && exec bash REAL_HELPER "$@"
while [ \"$#\" -gt 0 ]; do
  case \"$1\" in
    --count) printf '%s' \"$2\" > COUNT_ARG ;;
    --content-file) cp \"$2\" BODY_COPY ;;
  esac
  shift
done
printf '[CONTEXT] NONBLOCKING_RECORD_DONE=1; pr=42; outcome=%s; count=1; iteration_id=42-test; comment_id=1; degraded=0\n' OUTCOME >&2
exit 0
""".replace('OUTCOME', outcome).replace('REAL_HELPER', str(real_helper)).replace('BODY_COPY', str(record_body)).replace('COUNT_ARG', str(count_arg)))
    for outcome, expected in [('updated',0), ('failed',1), ('skipped',1)]:
        set_outcome(outcome)
        result = run(record)
        assert result.returncode == expected, (outcome, result)
        assert source.read_bytes() == saved
        body = record_body.read_text()
        assert 'private-detail' not in body
        assert 'F-01' in body and str(source) in body
        if expected:
            assert '[fix:error] reason=nonblocking_record_failed' in result.stdout
    # The ledger of the record being replaced survives, spliced right before the count line.
    set_outcome('updated')
    gh_log.write_text('')
    result = run(record)
    assert result.returncode == 0, result
    assert 'REJECTED_LEDGER_PRESERVE=ok' in result.stderr
    lines = record_body.read_text().splitlines()
    assert lines.count('### 却下台帳') == 1 and lines.count(ledger_row) == 1
    assert not [l for l in lines if 'F-77' in l or 'F-55' in l or 'F-66' in l]
    count_at = next(i for i, l in enumerate(lines) if l.startswith('📎 non_blocking_count:'))
    assert lines.index('### 却下台帳') < count_at
    assert [l for l in lines[:count_at] if l.strip()][-1] == ledger_row
    assert lines[count_at] == '📎 non_blocking_count: 1' and count_arg.read_text() == '1'
    assert [l for l in lines if l.strip()][-1] == '<!-- rite:nbr:v1 -->'
    without_ledger = lines[:lines.index('### 却下台帳')] + lines[count_at:]
    # The closing keyword wins over the branch name, as in the helper.
    assert 'api --paginate --slurp repos/owner/repo/issues/7/comments' in gh_log.read_text()
    # The read never writes.
    assert not [l for l in gh_log.read_text().splitlines() if ' -X PATCH' in l or l.startswith(('issue comment', 'issue edit'))]
    # No ledger to carry: the body is the generated one, without a heading.
    for existing in (existing_without_ledger, json.dumps([comment(2, other_comment)]), '[]'):
        comments.write_text(existing)
        result = run(record)
        assert result.returncode == 0, result
        lines = record_body.read_text().splitlines()
        assert lines == without_ledger, lines
    comments.write_text(existing_with_ledger)
    # Without a closing keyword the branch name decides.
    gh_log.write_text('')
    set_pr('no keyword', 'fix/issue-7-branch')
    result = run(record)
    assert result.returncode == 0, result
    assert 'api --paginate --slurp repos/owner/repo/issues/7/comments' in gh_log.read_text()
    # Failures stop before the helper, so nothing replaces the record.
    for setup, reason in [
            (lambda: set_pr('no keyword', 'topic-branch'), 'nonblocking_record_ledger_fetch_failed'),
            (lambda: (temp / 'comments-fail').write_text(''), 'nonblocking_record_ledger_fetch_failed')]:
        set_pr('Closes #7', 'fix/issue-7-branch')
        setup()
        record_body.unlink(missing_ok=True)
        result = run(record)
        assert result.returncode != 0, result
        assert f'[fix:error] reason={reason}' in result.stdout, result
        assert f'[CONTEXT] FIX_FALLBACK_FAILED=1; reason={reason}' in result.stderr, result
        assert 'NONBLOCKING_RECORD_BODY=failed' in result.stderr, result
        assert not record_body.exists()
    (temp / 'comments-fail').unlink()
    # The ledger tempfile, extract and merge-into failures after a readable record stop the same way.
    real_ledger = root / 'plugins/rite/hooks/scripts/nb-sweep-ledger.sh'
    ledger_link = plugin / 'hooks/scripts/nb-sweep-ledger.sh'
    failing_ledger = temp / 'failing-ledger.sh'
    failing_ledger.write_text(f"""#!/bin/bash
[ "$1" = "$LEDGER_FAIL_OP" ] && exit 1
exec bash '{real_ledger}' "$@"
""")
    failing_ledger.chmod(0o755)
    shim_dir = temp / 'mktemp-shim'
    shim_dir.mkdir()
    real_mktemp = subprocess.run(['bash', '-c', 'command -v mktemp'], text=True, capture_output=True).stdout.strip()
    (shim_dir / 'mktemp').write_text(f"""#!/bin/bash
case "$*" in *rite-fix-nbr-existing-*) exit 1 ;; esac
exec '{real_mktemp}' "$@"
""")
    (shim_dir / 'mktemp').chmod(0o755)
    set_pr('Closes #7', 'fix/issue-7-branch')
    comments.write_text(existing_with_ledger)
    ledger_link.unlink()
    ledger_link.symlink_to(failing_ledger)
    for extra, reason in [
            ({'PATH': f"{shim_dir}:{env['PATH']}"}, 'nonblocking_record_tempfile_failed'),
            ({'LEDGER_FAIL_OP': 'extract'}, 'nonblocking_record_ledger_extract_failed'),
            ({'LEDGER_FAIL_OP': 'merge-into'}, 'nonblocking_record_ledger_merge_failed')]:
        record_body.unlink(missing_ok=True)
        result = run(record, extra)
        assert result.returncode != 0, (reason, result)
        assert f'[fix:error] reason={reason}' in result.stdout, (reason, result)
        assert f'[CONTEXT] FIX_FALLBACK_FAILED=1; reason={reason}' in result.stderr, (reason, result)
        assert 'REJECTED_LEDGER_PRESERVE=ok' not in result.stderr, (reason, result)
        assert not record_body.exists(), reason
    ledger_link.unlink()
    ledger_link.symlink_to(real_ledger)
    source.write_text(json.dumps({'findings':[], 'non_blocking_findings':[]}))
    result = run(record)
    assert result.returncode == 0, result  # skipped with zero findings is valid
    del findings[0]['verification']
    source.write_text(json.dumps({'findings':findings}))
    before = source.read_bytes()
    result = run(triage)
    assert result.returncode != 0
    assert '[fix:error] reason=measured_undetermined; findings=F-01' in result.stdout
    assert 'FIX_TRIAGE_REVIEW_PATH=' not in result.stderr
    assert source.read_bytes() == before
PY_CHECK
then
  echo '  ✅ fatal triage persists and record failures stop the caller'; pass=$((pass + 1))
else
  echo '  ❌ fatal triage/record caller contract'; fail=$((fail + 1))
fi

echo "PASS: $pass"
echo "FAIL: $fail"
[ "$fail" -eq 0 ]
