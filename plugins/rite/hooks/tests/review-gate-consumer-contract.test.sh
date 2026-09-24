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
triage = re.search(r'```bash\n(.*?)\n```', common, re.S).group(1)
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
    # gh stub: answers only the calls the record makes, so a real gh is never reached.
    # The comments call applies the record's own --jq to a JSON array, so the selection is tested too.
    stub_dir = temp / 'bin'
    stub_dir.mkdir()
    gh_log = temp / 'gh-calls'
    pr_json = temp / 'pr.json'
    comments = temp / 'comments.json'
    (stub_dir / 'gh').write_text(f"""#!/bin/bash
printf '%s\\n' "$*" >> '{gh_log}'
if [ "$*" = "pr view 42 -R owner/repo --json body,headRefName" ]; then cat '{pr_json}'; exit 0; fi
if [ "$1 $2 $3 $4" = "api repos/owner/repo/issues/7/comments --paginate --jq" ] && [ "$#" -eq 5 ]; then
  [ -f '{temp}/comments-fail' ] && exit 1
  exec jq -r "$5" '{comments}'
fi
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
    existing_with_ledger = json.dumps([{'body': other_comment}, {'body': record_with_ledger}])
    existing_without_ledger = json.dumps([{'body': other_comment}, {'body': record_without_ledger}])
    def set_pr(body, head):
        pr_json.write_text(json.dumps({'body': body, 'headRefName': head}))
    set_pr('Closes #7', 'fix/issue-8-other')
    comments.write_text(existing_with_ledger)
    def run(block):
        for key, value in values.items():
            block = block.replace('{' + key + '}', value)
        return subprocess.run(['bash', '-c', block], text=True, capture_output=True, timeout=10, env=env)
    findings = [{'id':'F-01', 'severity':'MEDIUM', 'scope':'current-pr', 'file':'a.sh', 'line':1,
                 'reviewer':'test-reviewer', 'description':'private-detail', 'verification':{'measured':True}}]
    source.write_text(json.dumps({'findings': findings}))
    result = run(triage)
    assert result.returncode == 0, result
    assert json.loads(source.read_text())['findings'] == []
    assert json.loads(result.stdout)['fatal_map'] == {'F-01':False}
    assert 'FIX_TRIAGE_REVIEW_PATH=' in result.stderr
    saved = source.read_bytes()
    stub = plugin / 'hooks/review-nonblocking-record.sh'
    record_body = temp / 'record-body'
    count_arg = temp / 'count-arg'
    def set_outcome(outcome):
        stub.write_text("""#!/bin/bash
while [ \"$#\" -gt 0 ]; do
  case \"$1\" in
    --count) printf '%s' \"$2\" > COUNT_ARG ;;
    --content-file) cp \"$2\" BODY_COPY ;;
  esac
  shift
done
printf '[CONTEXT] NONBLOCKING_RECORD_DONE=1; pr=42; outcome=%s; count=1; iteration_id=42-test; comment_id=1; degraded=0\n' OUTCOME >&2
exit 0
""".replace('OUTCOME', outcome).replace('BODY_COPY', str(record_body)).replace('COUNT_ARG', str(count_arg)))
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
    assert not [l for l in lines if 'F-77' in l]
    count_at = next(i for i, l in enumerate(lines) if l.startswith('📎 non_blocking_count:'))
    assert lines.index('### 却下台帳') < count_at
    assert [l for l in lines[:count_at] if l.strip()][-1] == ledger_row
    assert lines[count_at] == '📎 non_blocking_count: 1' and count_arg.read_text() == '1'
    assert [l for l in lines if l.strip()][-1] == '<!-- rite:nbr:v1 -->'
    without_ledger = lines[:lines.index('### 却下台帳')] + lines[count_at:]
    # The closing keyword wins over the branch name, as in the helper.
    assert 'api repos/owner/repo/issues/7/comments --paginate' in gh_log.read_text()
    assert 'issues/8/' not in gh_log.read_text()
    # No ledger to carry: the body is the generated one, without a heading.
    for existing in (existing_without_ledger, json.dumps([{'body': other_comment}]), '[]'):
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
    assert 'api repos/owner/repo/issues/7/comments --paginate' in gh_log.read_text()
    # Failures stop before the helper, so nothing replaces the record.
    for setup, reason in [
            (lambda: set_pr('no keyword', 'topic-branch'), 'nonblocking_record_issue_unresolved'),
            (lambda: (temp / 'comments-fail').write_text(''), 'nonblocking_record_ledger_fetch_failed')]:
        set_pr('Closes #7', 'fix/issue-7-branch')
        setup()
        record_body.unlink(missing_ok=True)
        result = run(record)
        assert result.returncode != 0, result
        assert f'[fix:error] reason={reason}' in result.stdout, result
        assert not record_body.exists()
    (temp / 'comments-fail').unlink()
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
