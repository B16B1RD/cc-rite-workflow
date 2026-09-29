#!/usr/bin/env bash
# issue-audit.sh against a gh stub: snapshot fields, disposition rules and their exclusions,
# the exact write sequence of dispose, idempotence and the refusal of Issue number arguments.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_hermetic-env.sh"
python3 - "$SCRIPT_DIR/../.." <<'PYTEST'
import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

plugin = Path(sys.argv[1]).resolve()
checks = 0


def check(condition, message):
    global checks
    assert condition, message
    checks += 1


work = Path(tempfile.mkdtemp())
# A copy of the helper under a fake plugin root, so claim / config / Projects calls hit stubs.
fake = work / 'plugin'
(fake / 'hooks/scripts/lib').mkdir(parents=True)
(fake / 'scripts').mkdir()
shutil.copy(plugin / 'hooks/scripts/issue-audit.sh', fake / 'hooks/scripts/issue-audit.sh')
shutil.copy(plugin / 'hooks/scripts/lib/issue-audit.py', fake / 'hooks/scripts/lib/issue-audit.py')
(fake / 'hooks/issue-claim.sh').write_text(
    '[ "$1" = check ] || exit 9\ncase " $CLAIMED " in *" $3 "*) echo other ;; *) echo free ;; esac\n')
(fake / 'hooks/scripts/lib/rite-config-path.sh').write_text(
    '[ -n "${CONFIG_PATH:-}" ] || { echo "no config" >&2; exit 1; }\necho "$CONFIG_PATH"\n')
(fake / 'scripts/projects-status-update.sh').write_text(
    'printf "status %s\\n" "$(printf "%s" "$1" | jq -c "{issue_number,status_role,auto_add}")" >> "$GH_LOG"\n'
    'n=$(printf "%s" "$1" | jq -r .issue_number)\n'
    'case " $CONFLICT " in *" $n "*) echo \'{"result":"skipped_terminal_conflict"}\' ;;'
    ' *) echo \'{"result":"updated"}\' ;; esac\n')
helper = fake / 'hooks/scripts/issue-audit.sh'

# gh stub: serves fixtures, logs every call and fails on anything it does not know.
bin_dir = work / 'bin'
bin_dir.mkdir()
(bin_dir / 'gh').write_text('''#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
fx = os.environ["GH_FIXTURE"]
data = json.load(open(fx))
with open(os.environ["GH_LOG"], "a") as log:
    log.write(" ".join(a[:3]) + ("" if a[:2] != ["issue", "close"] else " " + " ".join(
        x for x in a[3:] if not x.startswith("\\U0001f9f9"))) + "\\n")
def val(flag):
    return a[a.index(flag) + 1]
if a[:2] == ["issue", "list"]:
    print(json.dumps([i for i in data["issues"].values() if i["state"] == "OPEN"]))
elif a[:2] == ["pr", "list"]:
    print(json.dumps(list(data["prs"].values())))
elif a[:2] == ["issue", "view"]:
    print(json.dumps(data["issues"][a[2]]))
elif a[:2] == ["pr", "view"]:
    print(json.dumps(data["prs"][a[2]]))
elif a[:2] == ["issue", "close"]:
    data["issues"][a[2]]["state"] = "CLOSED"
    data.setdefault("comments", {})[a[2]] = val("--comment")
    json.dump(data, open(fx, "w"))
else:
    sys.stderr.write("unexpected gh call: %s\\n" % a)
    sys.exit(1)
''')
(bin_dir / 'gh').chmod(0o755)

now = datetime.datetime.now(datetime.timezone.utc)


def ago(days):
    return (now - datetime.timedelta(days=days)).strftime('%Y-%m-%dT%H:%M:%SZ')


def issue(n, body='', state='OPEN', days=0, reason=''):
    return {'number': n, 'title': f't{n}', 'body': body, 'state': state, 'updatedAt': ago(days),
            'stateReason': reason}


DUP = '<!-- [rite-follow-up-from-pr:32:F-01,F-02] -->'
ISSUES = [
    issue(21, state='CLOSED'), issue(22, '- 元 Issue: #21\nsee plugins/x/a.sh', state='CLOSED'),
    issue(23, '<!-- [rite-follow-up-from-pr:31:F-09] -->\nsee plugins/x/a.sh'),
    issue(41, state='CLOSED'), issue(42, '- 元 Issue: #41\nplugins/x/a.sh:3 again'),
    issue(49, state='CLOSED'), issue(50, DUP), issue(51, DUP),
    issue(60), issue(61), issue(62, reason='REOPENED'), issue(63),
    issue(70), issue(71), issue(72), issue(73), issue(74),
    issue(80, days=31), issue(81, days=29),
]
PRS = [
    {'number': 31, 'body': 'Closes #22', 'baseRefName': 'develop'},
    {'number': 32, 'body': 'Closes #49', 'baseRefName': 'develop'},
    {'number': 33, 'body': 'Fixes #60\nFixes #62\nFixes #63\nCloses #74', 'baseRefName': 'develop'},
    {'number': 34, 'body': 'Closes #61', 'baseRefName': 'main'},
]
RECORDS = [
    {'ids': ['F-1'], 'V': False, 'C': False, 'T': False, 'reason': 'not a defect', 'present': True, 'tracker': 70},
    {'ids': ['F-2'], 'V': False, 'C': False, 'T': False, 'reason': '', 'present': True, 'tracker': 71},
    {'ids': ['F-3'], 'V': False, 'C': False, 'T': False, 'present': False, 'evidence': 'gone', 'tracker': 72},
    {'ids': ['F-4'], 'V': False, 'C': False, 'T': False, 'reason': 'x', 'present': True, 'tracker': 73},
    {'ids': ['F-5'], 'V': True, 'C': False, 'T': False, 'present': True, 'tracker': 73},
    {'ids': ['F-6'], 'V': False, 'C': False, 'T': False, 'reason': 'y', 'present': True, 'tracker': 74},
]
state = work / 'state'
(state / '.rite/state').mkdir(parents=True)
(state / '.rite/state/adoption-35-followup.json').write_text(
    json.dumps({'adoption': {'head': 'abc', 'records': RECORDS}}))
config = work / 'rite-config.yml'
config.write_text('github:\n  projects:\n    enabled: true\n    project_number: 7\n    owner: "o"\n')


def reset():
    (work / 'gh.json').write_text(json.dumps({'issues': {str(i['number']): i for i in ISSUES},
                                              'prs': {str(p['number']): p for p in PRS}}))
    (work / 'gh.log').write_text('')


def run(*args, **env):
    full = dict(os.environ, PATH=f'{bin_dir}:{os.environ["PATH"]}', GH_FIXTURE=str(work / 'gh.json'),
                GH_LOG=str(work / 'gh.log'), RITE_STATE_ROOT=str(state), CLAIMED='63',
                CONFIG_PATH=str(config), CONFLICT='')
    full.update(env)
    return subprocess.run(['bash', str(helper), *args, '--repo', 'o/r', '--base', 'develop'],
                          capture_output=True, text=True, env=full, cwd=work, timeout=60)


def writes():
    return [l for l in (work / 'gh.log').read_text().splitlines() if l.startswith(('issue close', 'status'))]


check(shutil.which('gh', path=str(bin_dir)) == str(bin_dir / 'gh'), 'gh stub must shadow the real gh')

# --- collect: snapshot fields (AC-1 / AC-2 / AC-3 inputs) and no writes ---
reset()
ran = run('collect')
check(ran.returncode == 0, ran.stderr)
snap = json.loads(ran.stdout)
check('[CONTEXT] ISSUE_AUDIT=ok;' in ran.stderr, ran.stderr)
check(snap['lineage']['chains'] == [[21, 22, 23]], snap['lineage'])            # 3 generations listed
check(not any(41 in c for c in snap['lineage']['chains']), snap['lineage'])   # 2 generations not listed
check({'child': 23, 'parent': 22, 'via': 'pr:31'} in snap['lineage']['edges'], snap['lineage'])
check({'kind': 'file', 'key': 'plugins/x/a.sh', 'issues': [23, 42]} in snap['concentration'], snap['concentration'])
check({'kind': 'origin_pr', 'key': '32', 'issues': [50, 51]} in snap['concentration'], snap['concentration'])
stale = {i['number']: i['stale'] for i in snap['open_issues']}
check(stale[80] is True and stale[81] is False, stale)                         # threshold boundary
disp = {d['issue']: d for d in snap['dispositions']}
check(sorted(disp) == [51, 60, 70, 72], disp)
check(disp[51]['reason'] == 'duplicate' and disp[51]['duplicate_of'] == 50, disp[51])
check(disp[60]['rule'] == 'merged_closing_pr' and disp[72]['rule'] == 'record_resolved', disp)
check(disp[70]['reason'] == 'not_planned' and 'reason: not a defect' in disp[70]['evidence'][0], disp[70])
check(61 not in disp and 71 not in disp, 'other-base PR and reason-less record are not disposed')
excl = {e['issue']: e['why'] for e in snap['excluded']}
check(excl == {62: 'reopened', 63: 'claimed_by_other_session', 73: 'conflicting_records',
               74: 'conflicting_rules'}, excl)
check(writes() == [], 'collect never writes')

# --- dispose: exact write sequence and evidence left on the Issue (AC-4) ---
ran = run('dispose')
check(ran.returncode == 0, ran.stderr)
check('[CONTEXT] ISSUE_AUDIT_DISPOSE=ok; closed=4; failed=0' in ran.stderr, ran.stderr)
S = 'status {{"issue_number":{},"status_role":"{}","auto_add":false}}'
check(writes() == [
    'issue close 51 -R o/r --comment --duplicate-of 50', S.format(51, 'cancelled'),
    'issue close 60 -R o/r --comment --reason completed', S.format(60, 'done'),
    'issue close 70 -R o/r --comment --reason not planned', S.format(70, 'cancelled'),
    'issue close 72 -R o/r --comment --reason completed', S.format(72, 'done'),
], writes())
comments = json.loads((work / 'gh.json').read_text())['comments']
check('adoption-35-followup.json ids=F-1 V=C=T=false reason: not a defect' in comments['70'], comments['70'])
check('PR #33 の本文: Fixes #60' in comments['60'] and DUP in comments['51'], comments)

# --- idempotence: a second run closes nothing ---
(work / 'gh.log').write_text('')
ran = run('dispose')
check(ran.returncode == 0 and writes() == [], (ran.stderr, writes()))

# --- a Status refused by the terminal-conflict guard fails loudly ---
reset()
ran = run('dispose', CONFLICT='70')
check(ran.returncode == 1 and 'ISSUE_AUDIT_DISPOSE=failed; closed=4; failed=1' in ran.stderr, ran.stderr)
check(json.loads(ran.stdout)['results'][2]['status'] == 'skipped_terminal_conflict', ran.stdout)

# --- Projects disabled: close only, no Status call ---
reset()
ran = run('dispose', CONFIG_PATH='')
check(ran.returncode == 0 and not any(l.startswith('status') for l in writes()), writes())

# --- Issue numbers are not accepted: nothing is read or written ---
reset()
ran = run('dispose', '70')
check(ran.returncode == 2 and (work / 'gh.log').read_text() == '', ran.stderr)

shutil.rmtree(work)
print(f'issue-audit: {checks} checks passed')
PYTEST
