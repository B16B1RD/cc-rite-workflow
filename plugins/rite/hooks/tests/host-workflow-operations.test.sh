#!/usr/bin/env bash
# T01/T07/T08/T09: execute batch-run's real shell blocks against distributed
# state helpers. Skill/tool routing and approval remain prose contracts, not
# claims that a fixture ran a native host or obtained a real user decision.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
source "$SCRIPT_DIR/../scripts/lib/tempfile.sh"
rite_tempfile_init || exit 1
rite_tempdir_new TEST_DIR host-workflow-test || exit 1
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"

if python3 - "$PLUGIN_ROOT" "$TEST_DIR" <<'PY'
import json
import os
import pathlib
import re
import shlex
import shutil
import subprocess
import sys
import unittest

plugin = pathlib.Path(sys.argv[1]).resolve()
root = plugin.parent.parent
sandbox = pathlib.Path(sys.argv[2]).resolve()
batch = (plugin / "skills/batch-run/SKILL.md").read_text(encoding="utf-8")
headings = list(re.finditer(r"(?m)^## ステップ ([0-9]+(?:\.[0-9]+)?):[^\n]*", batch))
sections = {
    heading.group(1): batch[heading.end():headings[index + 1].start() if index + 1 < len(headings) else len(batch)]
    for index, heading in enumerate(headings)
}

# The runtime copy has no launcher, dev profile, repository design documents,
# or tests. All runtime dependencies must come from the distributed hooks.
distribution = sandbox / "distribution"
shutil.copytree(plugin / "hooks", distribution / "hooks", ignore=shutil.ignore_patterns("tests", "__pycache__"))
for required in ["flow-state.sh", "state-path-resolve.sh", "session-identity.sh"]:
    if not (distribution / "hooks" / required).is_file():
        raise AssertionError("missing distributed runtime helper: " + required)


class WorkflowContracts(unittest.TestCase):
    def setUp(self):
        self.fixture = sandbox / self._testMethodName
        self.fixture.mkdir()
        self.env = os.environ.copy()
        for name in ["RITE_HOST", "RITE_STATE_ROOT", "CLAUDE_CODE_SESSION_ID", "CLAUDE_SESSION_ID",
                     "CODEX_THREAD_ID", "GROK_SESSION_ID", "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR"]:
            self.env.pop(name, None)
        self.env["GIT_CONFIG_NOSYSTEM"] = "1"
        self.run_command(["git", "init", "-q", str(self.fixture)])
        (self.fixture / "rite-config.yml").write_text("wiki:\n  enabled: false\n", encoding="utf-8")
        self.bin = self.fixture / "bin"
        self.bin.mkdir()
        gh = self.bin / "gh"
        gh.write_text('#!/bin/bash\nset -eu\n'
                      'if [ "$#" -ne 9 ] || [ "$1 $2" != "issue view" ] || '
                      '[ "$4 $5 $6 $7 $8 $9" != "-R fixture/repo --json state --jq .state" ]; then\n'
                      '  printf "unexpected gh call: %s\\n" "$*" >&2; exit 97\nfi\n'
                      'printf "%s\\n" "$3" >> "$BATCH_GH_LOG"\n'
                      'printf "%s\\n" "${BATCH_ISSUE_STATE:-OPEN}"\n', encoding="utf-8")
        gh.chmod(0o755)
        self.env["PATH"] = str(self.bin) + os.pathsep + self.env["PATH"]
        self.env["BATCH_GH_LOG"] = str(self.fixture / "gh.log")
        self.foreign_id = "ffffffff-ffff-ffff-ffff-ffffffffffff"
        self.current_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        state = self.fixture / ".rite/state"
        state.mkdir(parents=True)
        (self.fixture / ".rite/session-id").write_text(self.foreign_id + "\n", encoding="utf-8")
        self.foreign = state / ("run-queue-" + self.foreign_id + ".json")
        self.foreign.write_text('{"issues":[9999],"cursor":0,"mode":"default","active":true}\n', encoding="utf-8")
        self.foreign_bytes = self.foreign.read_bytes()
        self.queue = state / ("run-queue-" + self.current_id + ".json")
        self.flow_file = self.fixture / ".rite/sessions" / (self.current_id + ".flow-state")
        self.select_host("codex")

    def select_host(self, host):
        for key in ["CLAUDE_CODE_SESSION_ID", "CLAUDE_SESSION_ID", "CODEX_THREAD_ID", "GROK_SESSION_ID"]:
            self.env.pop(key, None)
        self.env["RITE_HOST"] = host
        self.env[{"claude": "CLAUDE_CODE_SESSION_ID", "codex": "CODEX_THREAD_ID", "grok": "GROK_SESSION_ID"}[host]] = self.current_id

    def run_command(self, args, expected=0):
        result = subprocess.run(args, cwd=self.fixture, env=self.env, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, expected, "command failed: " + repr(args) + "\n" + result.stdout + result.stderr)
        return result.stdout + result.stderr

    def block(self, step, marker):
        candidates = [body for body in re.findall(r"(?ms)^```bash\n(.*?)^```", sections[step]) if marker in body]
        self.assertEqual(len(candidates), 1, "expected one real batch block for " + marker)
        return candidates[0]

    def execute(self, step, marker, arguments="", breaker=False, issue=2624):
        code = self.block(step, marker)
        code = code.replace("{plugin_root}", shlex.quote(str(distribution)))
        code = code.replace('arg_str="{issue_numbers}"', "arg_str=" + shlex.quote(arguments))
        code = code.replace("{owner_repo}", "fixture/repo")
        code = code.replace("{breaker_failed}", "true" if breaker else "false")
        code = code.replace("{current_issue}", str(issue)).replace("{outstanding_n}", "1")
        # Do not prepend set -e: test the block's own failure propagation.
        return self.run_command(["bash", "-c", code])

    def state(self):
        return json.loads(self.queue.read_text(encoding="utf-8"))

    def handoff(self, issue):
        self.run_command(["bash", str(distribution / "hooks/flow-state.sh"), "set", "--phase", "review",
                          "--issue", str(issue), "--pr", "3000", "--branch", "issue-" + str(issue),
                          "--next", "review complete", "--handoff", "FINALIZE:review:mergeable:3000"])
        self.assertEqual(json.loads(self.flow_file.read_text())["session_id"], self.current_id)
        self.assertIn("handoff", json.loads(self.flow_file.read_text()))

    def assert_foreign_unchanged(self):
        self.assertEqual(self.foreign.read_bytes(), self.foreign_bytes)
        self.assertEqual((self.fixture / ".rite/session-id").read_text(), self.foreign_id + "\n")
        self.assertFalse((self.fixture / ".rite/state/run-queue.json").exists())

    def test_merge_stop_resume_and_completion_across_runtime_ids(self):
        for host in ["claude", "codex", "grok"]:
            with self.subTest(host=host):
                self.select_host(host)
                self.assertIn("RUN_QUEUE=initialized", self.execute("0", "RUN_QUEUE=", "--merge 2624 2625"))
                initial = self.state()
                self.assertEqual((initial["issues"], initial["cursor"], initial["mode"], initial["active"]), ([2624, 2625], 0, "merge", True))
                self.assertIn("RUN_NEXT=process; issue=2624", self.execute("1", "RUN_NEXT="))
                self.assertEqual((self.fixture / "gh.log").read_text().splitlines()[-1], "2624")
                self.handoff(2624)
                self.assertIn("remaining=[2624,2625]; mode=merge", self.execute("8", "RUN_STOP;"))
                stopped = self.state()
                self.assertEqual((stopped["cursor"], stopped["mode"], stopped["active"], stopped["failed"]), (0, "merge", False, []))
                self.assertNotIn("handoff", json.loads(self.flow_file.read_text()))
                self.assertIn("RUN_QUEUE=resume_no_args", self.execute("0", "RUN_QUEUE="))
                resumed = self.state()
                self.assertEqual((resumed["cursor"], resumed["mode"], resumed["active"]), (0, "merge", True))
                self.assertIn("RUN_ADVANCE; cursor=1; total=2", self.execute("6", "RUN_ADVANCE;"))
                self.assertIn("RUN_NEXT=process; issue=2625", self.execute("1", "RUN_NEXT="))
                self.handoff(2625)
                self.execute("6", "RUN_OUTSTANDING_RECORDED;", issue=2625)
                self.execute("6", "RUN_ADVANCE;")
                self.assertIn("RUN_NEXT=all-done; mode=merge", self.execute("1", "RUN_NEXT="))
                self.assertIn("processed=[2624,2625]; failed=[]; outstanding=[2625]; mode=merge", self.execute("7", "RUN_DONE;"))
                self.assertFalse(self.queue.exists())
                self.assertNotIn("handoff", json.loads(self.flow_file.read_text()))
                self.assert_foreign_unchanged()

    def test_breaker_retains_cursor_and_resume_removes_only_current_failure(self):
        self.execute("0", "RUN_QUEUE=", "--merge 2624 2625")
        self.handoff(2624)
        self.execute("8", "RUN_STOP;", breaker=True)
        stopped = self.state()
        self.assertEqual((stopped["failed"], stopped["cursor"], stopped["active"]), ([2624], 0, False))
        self.execute("0", "RUN_QUEUE=")
        self.execute("6", "RUN_ADVANCE;")
        resumed = self.state()
        self.assertEqual((resumed["failed"], resumed["cursor"], resumed["mode"]), ([], 1, "merge"))
        self.assert_foreign_unchanged()

    def test_default_and_explicit_mode_override_preserve_progress(self):
        self.execute("0", "RUN_QUEUE=", "2624 2625")
        self.assertEqual(self.state()["mode"], "default")
        self.execute("6", "RUN_ADVANCE;")
        self.assertIn("RUN_QUEUE=resume_match; cursor=1", self.execute("0", "RUN_QUEUE=", "2624 --merge 2625"))
        self.assertEqual((self.state()["cursor"], self.state()["mode"]), (1, "merge"))
        self.execute("8", "RUN_STOP;")
        self.execute("0", "RUN_QUEUE=", "2624 2625")
        self.assertEqual((self.state()["cursor"], self.state()["mode"]), (1, "default"))
        self.env["BATCH_ISSUE_STATE"] = "CLOSED"
        self.assertIn("RUN_NEXT=skip-closed; issue=2625", self.execute("1", "RUN_NEXT="))
        self.assertEqual(self.state()["cursor"], 2)
        self.assert_foreign_unchanged()

    def test_sentinel_routes_are_scoped_to_the_actual_caller_steps(self):
        # Markdown routes are the executable orchestrator's instructions. Pin
        # each row in its own step, rather than accepting a phrase elsewhere.
        expectations = [
            ("2", "[pr:created:N]", "ステップ 3"),
            ("2", "sentinel 不在", "ステップ 8"),
            ("3", "`[review:mergeable]` + `merge`", "ステップ 4"),
            ("3", "`[review:mergeable]` + `default`", "ステップ 6"),
            ("3", "`[fix:replied-only]` + `merge`", "ステップ 8"),
            ("3", "[iterate:max-cycles-reached]", "ステップ 8"),
            ("3", "sentinel 不在", "ステップ 8"),
            ("4", "[ready:returned-to-caller]", "ステップ 5"),
            ("4", "sentinel 不在", "ステップ 8"),
            ("5", "[merge:returned-to-caller]", "ステップ 6"),
            ("5", "sentinel 不在", "ステップ 8"),
            ("6", "[cleanup:returned-to-caller]", "ステップ 1"),
        ]
        for step, sentinel, destination in expectations:
            with self.subTest(step=step, sentinel=sentinel):
                rows = [line for line in sections[step].splitlines() if line.startswith("|") and sentinel in line]
                self.assertEqual(len(rows), 1, (step, sentinel, rows))
                self.assertIn(destination, rows[0])
        invoked = re.findall(r"(?m)^skill: rite:([a-z-]+)$", batch)
        self.assertEqual(invoked, ["open", "iterate", "ready", "merge", "cleanup"])
        self.assertNotRegex(self.block("8", "RUN_STOP;"), r"\.cursor\s*\+=" )

    def test_native_and_body_execution_share_e2e_and_permission_contracts(self):
        operations = (plugin / "references/host-workflow-operations.md").read_text(encoding="utf-8")
        runtime = (plugin / "references/host-runtime-contract.md").read_text(encoding="utf-8")
        skill_part = operations.split("## Skill と caller\n", 1)[1].split("\n## ", 1)[0]
        for clause in ["native/本文実行とも caller からの呼出しは E2E", "caller / callee / args / expected_sentinels",
                       "sentinel 不在・失敗は caller の再試行回数と停止手順", "本文の読込だけ", "cursor を失敗 Issue に保持"]:
            self.assertIn(clause, skill_part)
        approval = operations.split("## 質問と承認\n", 1)[1]
        for clause in ["実際の回答が届くまで依存工程を停止", "未回答・timeout は承認ではない",
                       "正式機構だけ", "審査結果を待つ", "通常の質問・`--merge`・別ツールは権限拒否の解除にならない",
                       "拒否時は対象を変更せず state と cursor を保持"]:
            self.assertIn(clause, approval)
        self.assertIn("代替なし。拒否・承認不可なら診断を返す", runtime)
        self.assertIn("ホストの fail-open を rite の成功に変換しない", runtime)
        # Body handoff to an independent child is absolute-path only. Full inline of
        # the reviewer base is too large to launch and must not be read back in.
        reviewer_part = operations.split("## 独立 reviewer\n", 1)[1].split("\n## ", 1)[0]
        for clause in ["絶対パス", "着手前", "読取完了:", "1 回再試行", "全文 inline せず",
                       "渡したパス集合と一致"]:
            self.assertIn(clause, reviewer_part)
        self.assertNotIn("本文・制約・差分・仕様・絶対 workdir を native 子の prompt へ明示", reviewer_part)
        self.assertIn("読取完了申告が渡した全パスと一致", reviewer_part.split("### 回収ゲート\n", 1)[1])
        # The recovery claim is limited to what the design record attests; the
        # generic "同じ本文を渡す" wording must not resurface next to the path contract.
        for stale in ["同じ本文を渡す", "複数ホストで選定全員の回収を完走",
                      "計画/実装子の起動と完了回収を完走",
                      "他ホストでの選定 reviewer 全員の回収は未検証"]:
            self.assertNotIn(stale, reviewer_part)
        for clause in ["同じ絶対パス集合と読取義務を渡す", "計画/実装子の起動と完了回収を観測",
                       "絶対パス方式による選定 reviewer 全員の回収は未検証",
                       "Codex を含むどのホストでも設計記録は裏付けていない"]:
            self.assertIn(clause, reviewer_part)
        # The shared reviewer principles travel as an absolute path with a read
        # obligation on both the named and the independent-child path; neither
        # path inlines them, and the independent child only adds its profile path.
        handoff_part = reviewer_part.split("### 本文の引き渡し\n", 1)[1].split("\n### ", 1)[0]
        self.assertNotIn("読取完了申告が渡した全パスと一致", handoff_part)
        for clause in ["4.5 の placeholder 表が定義する `{shared_reviewer_principles}`",
                       "4.5 テンプレートと 4.5.1 検証テンプレートの双方の出現箇所",
                       "named 経路と同じく `_reviewer-base.md` の絶対パス行（読取義務付き）で渡す",
                       "その他の placeholder（差分・仕様・CI 状態・Wiki 等）は 4.5 のまま渡す",
                       "その 1 パスの申告を同じ規則で確認する"]:
            self.assertIn(clause, handoff_part)
        self.assertIn("`_reviewer-base.md` はどの経路でも prompt へ全文 inline せず", handoff_part)
        self.assertIn("起動上限にも近づく", handoff_part)
        for stale in ["named agent が公開されないホストでは、reviewer 本文を", "上限を超えて reviewer を回収できない"]:
            self.assertNotIn(stale, reviewer_part)
        named_row = next(line for line in reviewer_part.splitlines() if line.startswith("| native named Agent/Task |"))
        for clause in ["`_reviewer-base.md`", "読取完了"]:
            self.assertIn(clause, named_row)
        self.assertNotIn("申告の対象外", reviewer_part)
        self.assertIn("どの経路でも、helper を実行する前に各 raw 出力の先頭行の読取完了申告",
                      reviewer_part.split("### 回収ゲート\n", 1)[1])
        pr_review = (plugin / "skills/pr-review/SKILL.md").read_text(encoding="utf-8")
        entry_part = pr_review.split("### 4.3.1 Task Tool Sub-Agent Invocation\n", 1)[1].split("\n### 4.4 ", 1)[0]
        for clause in ["`{shared_reviewer_principles}` も named 経路と同じ絶対パス行",
                       "`agents/{reviewer_type}-reviewer.md` の絶対パスを同じ読取義務・読取完了申告の対象として渡す"]:
            self.assertIn(clause, entry_part)
        # 4.3 resolves the path and stops instead of launching with empty principles.
        load_part = pr_review.split("**Loading sub-agent definition files:**\n", 1)[1].split("\n**並列（MUST）**", 1)[0]
        self.assertNotIn("空なら空文字列", load_part)
        self.assertNotIn("Extract `{shared_reviewer_principles}`", load_part)
        self.assertIn("全文 inline せず", load_part)
        # Run the real 4.3 block: each guard must stop on its own failure instead of
        # handing an unreadable or relative path to the reviewers.
        blocks = re.findall(r"(?ms)^ ```bash\n(.*?)^ ```", load_part)
        self.assertEqual(len(blocks), 1, "expected one 4.3 bash block")
        load_code = "\n".join(line[1:] if line.startswith(" ") else line for line in blocks[0].splitlines())

        def run_load(plugin_root, cwd):
            result = subprocess.run(["bash", "-c", load_code.replace("{plugin_root}", plugin_root)], cwd=cwd,
                                    capture_output=True, text=True, timeout=20)
            return result.returncode, result.stdout, result.stderr

        rc, out, err = run_load(str(plugin), str(self.fixture))
        self.assertEqual(rc, 0, err)
        self.assertEqual(out.strip(), "[CONTEXT] SHARED_REVIEWER_PRINCIPLES=" + str(plugin / "agents/_reviewer-base.md"))
        missing = self.fixture / "no-base"
        (missing / "agents").mkdir(parents=True)
        headless = self.fixture / "headless-base"
        (headless / "agents").mkdir(parents=True)
        (headless / "agents/_reviewer-base.md").write_text("# base without the output format section\n", encoding="utf-8")
        for label, plugin_root, cwd, guard in [
                ("missing base", str(missing), str(self.fixture), "読めません"),
                ("base without Output Format", str(headless), str(self.fixture), "読めません"),
                ("relative plugin root", "plugins/rite", str(root), "絶対パスではありません")]:
            rc, out, err = run_load(plugin_root, cwd)
            self.assertNotEqual(rc, 0, label)
            self.assertIn("[review:error]", out, label)
            self.assertNotIn("[CONTEXT] SHARED_REVIEWER_PRINCIPLES=", out, label)
            self.assertIn(guard, err, label)
        row = next(line for line in pr_review.splitlines() if line.startswith("| `{shared_reviewer_principles}` |"))
        for clause in ["全文 inline しない", "SHARED_REVIEWER_PRINCIPLES=", "着手前に Read tool で先頭から末尾まで全文読む",
                       "offset / limit で分割して末尾まで", "読取完了: {絶対パス}", "named / 独立子の両経路で同じ"]:
            self.assertIn(clause, row)
        retry_part = pr_review.split("### 4.4 Retry Logic\n", 1)[1].split("\n### ", 1)[0]
        self.assertEqual(2, retry_part.count("| Missing read declaration |"))
        note = next(line for line in retry_part.splitlines() if line.startswith("**Note**:"))
        self.assertIn("missing read declaration は質問せず", note)
        # The read-declaration check is part of the collection gate, so every path
        # that reruns the 5.1 gate rechecks the declaration of the replaced output.
        collection = pr_review.split("### 5.1 Result Collection\n", 1)[1].split("\n### ", 1)[0]
        self.assertNotIn("**読取完了申告の照合（全経路）**", collection)
        gate = collection.split("**回収完了ゲート（全ホスト必須）**", 1)[1].split("# reviewer-completion-gate", 1)[0]
        for clause in ["読取完了:", "Missing read declaration"]:
            self.assertIn(clause, gate)
        likelihood_retry = next(line for line in pr_review.splitlines()
                                if line.startswith("| rc=1 + `reason ∈ {anchor_missing,"))
        self.assertIn("読取完了申告の照合", likelihood_retry)
        for marker in ["| rc=1 + `reason ∈ {table_missing,", "retry の回収結果で manifest を更新し",
                       "| rc=1 + `reason=unmet_finding_not_blocking`"]:
            line = next(line for line in pr_review.splitlines() if line.startswith(marker))
            self.assertIn("5.1 の回収完了ゲート", line, marker)
        # Both review templates tell the reviewer where READ-ONLY Enforcement lives
        # with the same sentence; the base is read from its path, not injected.
        rules = []
        for name in ["reviewer-prompt-generator.md", "reviewer-prompt-verification.md"]:
            text = (plugin / "skills/pr-review/references" / name).read_text(encoding="utf-8")
            self.assertNotIn("注入済み", text, name)
            rule = [line for line in text.splitlines() if line.startswith("[READ-ONLY RULE]")]
            self.assertEqual(len(rule), 1, name)
            self.assertIn("で読取義務を課した `_reviewer-base.md`（絶対パス）の `## READ-ONLY Enforcement`", rule[0], name)
            rules.append(rule[0])
        self.assertEqual(rules[0], rules[1])
        # Distributed agent bodies must not point at a development-repository path,
        # and each Output Format section must send the reviewer to the caller's path.
        agents = sorted((plugin / "agents").glob("*-reviewer.md"))
        with_format = set()
        for agent in agents:
            text = agent.read_text(encoding="utf-8")
            self.assertNotIn("plugins/rite/agents/_reviewer-base.md", text, agent.name)
            if "\n## Output Format\n" in text:
                section = text.split("\n## Output Format\n", 1)[1].split("\n## ", 1)[0]
                self.assertIn("The caller passes its absolute path", section, agent.name)
                with_format.add(agent.name)
        self.assertEqual(with_format, {agent.name for agent in agents} - {"acceptance-reviewer.md"})
        # workdir is not a 4.5 placeholder; the handoff names it as a separately supplied item.
        self.assertNotIn("制約 / workdir）は 4.5 のまま", handoff_part)
        self.assertIn("制約・絶対 workdir は上記の項目として別途明示する", handoff_part)
        self.assertIn("reviewer 本文の絶対パスと読取義務を子の指示へ明示", runtime)
        for skill_name in ["rite-workflow", "batch-run", "open", "issue-implement", "pr-create", "iterate",
                           "pr-review", "fix", "ready", "recover", "issue-create"]:
            body = (plugin / "skills" / skill_name / "SKILL.md").read_text(encoding="utf-8")
            self.assertIn("host-workflow-operations.md", body, skill_name)
            self.assertIn("host-runtime-contract.md", body, skill_name)
        # A global reference cannot repair a local "Skill tool only, otherwise
        # standalone" rule. Actual classification/dispatch sites admit body calls.
        for skill_name, heading in [
            ("pr-create", "## Caller Context and End-to-End Flow"),
            ("pr-review", "## Invocation Context and End-to-End Flow"),
            ("ready", "### 5.0 Determine the Caller"),
            ("fix", "## ステップ 5: E2E フロー継続 (出力パターン)"),
            ("recover", "### 5.4 invoke"),
        ]:
            body = (plugin / "skills" / skill_name / "SKILL.md").read_text(encoding="utf-8")
            classifier = body.split(heading + "\n", 1)[1]
            classifier = re.split(r"(?m)^#{1,3} ", classifier, maxsplit=1)[0]
            self.assertRegex(classifier, r"equivalent body execution|本文実行|host-workflow-operations\.md#skill-と-caller", skill_name)

    def test_distribution_documentation_and_ci_inputs_stay_connected(self):
        for filename in ["README.md", "README.ja.md"]:
            body = (root / filename).read_text(encoding="utf-8")
            self.assertIn("plugins/rite/references/host-runtime-contract.md#入口と工程境界", body)
            self.assertIn("docs/designs/multi-host-runtime.md", body)
            self.assertIn("Codex", body)
            self.assertIn("Grok", body)
        workflow = (root / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        for event in ["push", "pull_request"]:
            section = re.search(r"(?ms)^  " + event + r":\n(.*?)(?=^  [a-z_]+:|^\S|\Z)", workflow)
            self.assertIsNotNone(section, event)
            # Unfiltered events cover runtime inputs and documentation alike.
            self.assertNotRegex(section.group(1), r"(?m)^\s+paths(?:-ignore)?:")
        self.assertRegex(workflow, r"(?m)^      - main$")
        self.assertRegex(workflow, r"(?m)^      - develop$")
        self.assertIn("for tool in bash jq git python3; do", workflow)
        self.assertIn("run: bash plugins/rite/hooks/tests/run-tests.sh", workflow)


unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
then
  pass 'host workflow contracts and real batch state transitions'
else
  fail 'host workflow contracts and real batch state transitions'
fi
print_summary "$(basename "$0")"
