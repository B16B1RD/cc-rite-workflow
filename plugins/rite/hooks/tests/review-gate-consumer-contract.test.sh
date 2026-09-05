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
check "pr-review は save helper を実行" 'bash {plugin_root}/hooks/review-result-save.sh' "$REVIEW"

# Execute the documented callers so a zero exit from a failed record cannot pass.
if python3 - "$ROOT" <<'PY_CHECK'
import json
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
with tempfile.TemporaryDirectory() as temp:
    temp = Path(temp)
    plugin = temp / 'plugin'
    (plugin / 'scripts').mkdir(parents=True)
    (plugin / 'hooks').mkdir()
    (plugin / 'scripts/review-findings-maps.sh').symlink_to(root / 'plugins/rite/scripts/review-findings-maps.sh')
    source = temp / 'review.json'
    values = {'plugin_root': str(plugin), 'triage_review_path': str(source),
              'triage_helper_source': 'explicit_file', 'pr_number': '42',
              'owner_repo': 'owner/repo', 'review_cycle_id': '42-test', 'non_fatal_moved_count': '1'}
    def run(block):
        for key, value in values.items():
            block = block.replace('{' + key + '}', value)
        return subprocess.run(['bash', '-c', block], text=True, capture_output=True, timeout=10)
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
    for outcome, expected in [('updated',0), ('failed',1), ('skipped',1)]:
        stub.write_text("""#!/bin/bash
while [ \"$#\" -gt 0 ]; do
  case \"$1\" in --content-file) cp \"$2\" BODY_COPY; break ;; esac
  shift
done
printf '[CONTEXT] NONBLOCKING_RECORD_DONE=1; pr=42; outcome=%s; count=1; iteration_id=42-test; comment_id=1; degraded=0\n' OUTCOME >&2
exit 0
""".replace('OUTCOME', outcome).replace('BODY_COPY', str(temp / 'record-body')))
        result = run(record)
        assert result.returncode == expected, (outcome, result)
        assert source.read_bytes() == saved
        body = (temp / 'record-body').read_text()
        assert 'private-detail' not in body
        assert 'F-01' in body and str(source) in body
        if expected:
            assert '[fix:error] reason=nonblocking_record_failed' in result.stdout
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
