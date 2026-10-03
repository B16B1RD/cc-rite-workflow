#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../lib/tempfile.sh"
rite_tempfile_init
rite_tempdir_new FIXTURE repository-context-tests
CHECKER="$SCRIPT_DIR/../repository-context-check.sh"
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../../.." && pwd)

# Run the source tree too: a regression must fail the automatically discovered
# checker suite, not merely demonstrate that crafted input can be rejected.
bash "$CHECKER" --all --repo-root "$REPO_ROOT"

python3 - "$CHECKER" "$FIXTURE" <<'PY'
from pathlib import Path
import subprocess
import sys

checker, directory = sys.argv[1:]
root = Path(directory)
target = root / "skill with spaces.md"
call = 'bash "{plugin_root}/scripts/issue-complexity-lane.sh" --issue {issue_number} --repo {owner_repo} || exit $?'
cd = 'cd "{execution_cwd}" || exit 1'

def check(name, body, expected):
    target.write_text("```bash\n" + body + "\n```\n")
    result = subprocess.run(["bash", checker, "--repo-root", directory, "--target", target.name], capture_output=True, text=True)
    assert result.returncode == expected, (name, result.returncode, result.stdout, result.stderr)
    if expected == 1:
        assert f"{target.name}:" in result.stdout, (name, result.stdout)
    print("PASS:", name)

check("explicit boundary", cd + "\n" + call, 0)
check("multiline quoted helper", cd + "\n" + call.replace(" --issue", " \\\n  --issue"), 0)
check("missing repository", cd + "\n" + call.replace(" --repo {owner_repo}", ""), 1)
check("another repository", cd + "\n" + call.replace("{owner_repo}", "another/project"), 1)
check("missing cwd", call, 1)
check("unchecked cwd failure", cd.replace(" || exit 1", "") + "\n" + call, 1)
check("fallback absorbs helper failure", cd + "\n" + call.replace("exit $?", "echo full"), 1)
check("helper failure ignored", cd + "\n" + call.replace(" || exit $?", ""), 1)
check("intervening cwd", cd + '\ncd /tmp\n' + call, 1)
check("cwd outside scope", '(' + cd + ')\n' + call, 1)
check("conditional cwd", 'if true; then ' + cd + '; fi\n' + call, 1)
check("multiline conditional cwd", 'if true; then\n' + cd + '\nfi\n' + call, 1)
check("multiline subshell cwd", '(\n' + cd + '\n)\n' + call, 1)
check("function-local cwd", 'pin() {\n' + cd + '\n}\n' + call, 1)
check("cwd in another block", cd + '\n```\n```bash\n' + call, 1)
check("empty invocation set", "echo harmless", 2)
check("comment is not invocation", '# ' + call, 2)
check("heredoc is not invocation", "cat <<'EXAMPLE'\n" + cd + '\n' + call + '\nEXAMPLE', 2)
check("wrong invocation wrapper", cd + '\nresult=$(' + call + ')', 1)

base = root / "plugins/rite/skills"
for name in ("open", "issue-implement", "pr-review"):
    skill = base / name / "SKILL.md"
    skill.parent.mkdir(parents=True, exist_ok=True)
    skill.write_text("```bash\n" + cd + "\n" + call + "\n```\n")
result = subprocess.run(["bash", checker, "--all", "--repo-root", directory], capture_output=True, text=True)
assert result.returncode == 0, result.stderr
(base / "open/SKILL.md").write_text("```bash\necho removed\n```\n")
result = subprocess.run(["bash", checker, "--all", "--repo-root", directory], capture_output=True, text=True)
assert result.returncode == 2 and "open" in result.stderr, result.stderr
print("PASS: expected callers cannot disappear silently")
PY
