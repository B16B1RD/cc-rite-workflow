#!/usr/bin/env bash
# /rite:issue-audit skill contract and its call from /rite:batch-run: where the audit runs,
# where the report is referenced, what the skill must not do, and the fixed report layout.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 - "$SCRIPT_DIR/../.." <<'PYTEST'
from pathlib import Path
import re
import sys

plugin = Path(sys.argv[1]).resolve()
skill = (plugin / 'skills/issue-audit/SKILL.md').read_text()
batch = (plugin / 'skills/batch-run/SKILL.md').read_text().splitlines()
contract = (plugin / 'references/sentinel-contract.md').read_text()
checks = 0


def check(condition, message):
    global checks
    assert condition, message
    checks += 1


def line_of(pattern, start=0):
    for i in range(start, len(batch)):
        if re.search(pattern, batch[i]):
            return i
    raise AssertionError(f'batch-run: {pattern} not found after line {start}')


# batch-run: the audit runs once in step 7, after the queue is closed and before either template.
step7 = line_of(r'^## ステップ 7:')
run_done = line_of(r'RUN_DONE; processed=', step7)
invoke = line_of(r'^skill: rite:issue-audit$', step7)
first_template = line_of(r'^## /rite:batch-run 完了', step7)
check(run_done < invoke < first_template, (run_done, invoke, first_template))
check(sum(1 for l in batch if l == 'skill: rite:issue-audit') == 1, 'audit invoked exactly once')

# Both completion templates reference the report before their final marker.
draft = line_of(r'^## /rite:batch-run 完了（draft 止まり）$', step7)
merge = line_of(r'^## /rite:batch-run 完了$', draft + 1)
for head in (draft, merge):
    end = line_of(r'^<!-- \[run:all-completed\] -->$', head)
    ref = line_of(r'^監査レポート: \{audit_report\}$', head)
    check(ref < end, (head, ref, end))
check(line_of(r'\[issue-audit:failed\]', invoke) < first_template, 'failure routed to action items')
check(any('`{audit_report}`' in l for l in batch[:step7]), 'placeholder legend defines audit_report')

# The skill never reviews: no agent spawn, no pr-review invocation.
check('subagent_type' not in skill, 'no agent spawn')
check(not re.search(r'^skill: rite:pr-review', skill, re.M), 'no pr-review invocation')
check('新しいレビュー指摘の生成をしない' in skill, 'MUST NOT: no new review findings')

# Disposal goes only through the helper, which takes no Issue numbers.
disposals = re.findall(r'^bash \{plugin_root\}/hooks/scripts/issue-audit\.sh dispose (.*)$', skill, re.M)
check(disposals == ['--repo {owner_repo} --base {base_branch}'], disposals)
check(not re.search(r'gh issue (close|edit)|gh issue create', skill), 'no direct Issue writes')

# Only the merge and redirection input cells are pinned verbatim.
# Narrowing added in bullets outside the table is not detected here.
rows = [l.split(' | ') for l in skill.splitlines() if l.startswith(('| 統合 |', '| 方向修正 |'))]
check([r[0] for r in rows] == ['| 統合', '| 方向修正'], rows)
check({r[0][2:]: r[1] for r in rows} == {
    '統合': '`open_issues` の全件。本文・コメントが同じ実装や契約を名指しする組（パスの表記ゆれ・ファイル名だけの名指しも含む。'
          '`concentration` のグループは手がかり）を同じ根因の候補として判定する',
    '方向修正': '`open_issues` の全件。本文が名指しするリポジトリ内の実装（ファイル名だけの名指しも含む。'
            '`files` は抽出できたパスの手がかり）の現状と本文の受入条件を照合する。'
            '`stale: true` のものは、ずれが無くても停滞として出す',
}, rows)

# Report layout: fixed sections in a fixed order.
report = skill[skill.index('# Issue 監査レポート'):]
heads = re.findall(r'^## (\S+)$', report, re.M)
check(heads[:5] == ['処分結果', '統合提案', '系譜', '方向修正', '除外'], heads)

# batch-run keeps going after the nested audit returns.
check(line_of(r'^<!-- run orchestration: after issue-audit returns, do NOT stop', invoke) < first_template,
      'batch-run continues after the audit returns')

# Sentinels emitted by the skill are declared in the SoT.
for sentinel in ('[issue-audit:returned-to-caller]', '[issue-audit:failed]'):
    check(sentinel in skill and f'| `{sentinel}` | issue-audit | batch-run |' in contract, sentinel)

print(f'issue-audit-contract: {checks} checks passed')
PYTEST
