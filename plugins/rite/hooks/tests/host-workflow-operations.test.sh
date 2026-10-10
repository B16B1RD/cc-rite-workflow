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
            ("7", "[issue-audit:returned-to-caller]", "完了通知"),
            ("7", "[issue-audit:failed]", "完了通知"),
        ]
        for step, sentinel, destination in expectations:
            with self.subTest(step=step, sentinel=sentinel):
                rows = [line for line in sections[step].splitlines() if line.startswith("|") and sentinel in line]
                self.assertEqual(len(rows), 1, (step, sentinel, rows))
                self.assertIn(destination, rows[0])
        invoked = re.findall(r"(?m)^skill: rite:([a-z-]+)$", batch)
        self.assertEqual(invoked, ["open", "iterate", "ready", "merge", "cleanup", "issue-audit"])
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
        self.assertEqual(len(blocks), 2, "expected common and tech-writer-specific 4.3 guards")
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
        # The call line runs the helper under the given plugin root, so each fixture carries a copy.
        for fixture_root in (missing, headless):
            (fixture_root / "scripts").mkdir(parents=True)
            (fixture_root / "hooks").mkdir(parents=True)
            shutil.copy(plugin / "scripts/pr-review-step.sh", fixture_root / "scripts/pr-review-step.sh")
            shutil.copy(plugin / "hooks/control-char-neutralize.sh", fixture_root / "hooks/control-char-neutralize.sh")
        for label, plugin_root, cwd, guard in [
                ("missing base", str(missing), str(self.fixture), "読めません"),
                ("base without Output Format", str(headless), str(self.fixture), "読めません")]:
            rc, out, err = run_load(plugin_root, cwd)
            self.assertNotEqual(rc, 0, label)
            self.assertIn("[review:error]", out, label)
            self.assertNotIn("[CONTEXT] SHARED_REVIEWER_PRINCIPLES=", out, label)
            self.assertIn(guard, err, label)
        # A relative plugin root in the call line still hands the reviewers an absolute path:
        # the helper resolves the root from its own location.
        rc, out, err = run_load("plugins/rite", str(root))
        self.assertEqual(rc, 0, err)
        self.assertNotIn("[review:error]", out)
        self.assertEqual(out.strip(), "[CONTEXT] SHARED_REVIEWER_PRINCIPLES=" + str((root / "plugins/rite/agents/_reviewer-base.md").resolve()))
        self.assertNotIn("絶対パスではありません", err)
        prose_code = "\n".join(line[1:] if line.startswith(" ") else line for line in blocks[1].splitlines())

        def run_prose(plugin_root, reviewer_type):
            code = prose_code.replace("{plugin_root}", str(plugin_root)).replace("{reviewer_type}", reviewer_type)
            return subprocess.run(["bash", "-c", code], cwd=str(self.fixture), capture_output=True, text=True, timeout=20)

        result = run_prose(plugin, "tech-writer")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "[CONTEXT] PROSE_REVIEWER_PRINCIPLES=" + str(plugin / "references/prose-reasoning.md"))
        no_prose = self.fixture / "no-prose"
        no_prose.mkdir()
        (no_prose / "scripts").mkdir()
        (no_prose / "hooks").mkdir()
        shutil.copy2(plugin / "scripts/pr-review-step.sh", no_prose / "scripts/pr-review-step.sh")
        shutil.copy2(plugin / "hooks/control-char-neutralize.sh", no_prose / "hooks/control-char-neutralize.sh")
        result = run_prose(no_prose, "tech-writer")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("[review:error]", result.stderr)
        self.assertNotIn("PROSE_REVIEWER_PRINCIPLES=", result.stdout)
        # Non-tech-writer reviews do not depend on the additional reference.
        result = run_prose(no_prose, "application")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        unreadable = no_prose / "references/prose-reasoning.md"
        unreadable.parent.mkdir()
        unreadable.write_text("unreadable reference\n", encoding="utf-8")
        unreadable.chmod(0)
        try:
            result = run_prose(no_prose, "tech-writer")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("[review:error]", result.stderr)
        finally:
            unreadable.chmod(0o600)
        prose_row = next(line for line in pr_review.splitlines() if line.startswith("| `{prose_reviewer_principles}` |"))
        for clause in ["tech-writer だけ", "全文読む", "読めなければ", "; ", "セクションごと省略", "通常・light・incremental・verification", "全文 inline しない", "既存の mandate"]:
            self.assertIn(clause, prose_row)
        prompt = (plugin / "skills/pr-review/references/reviewer-prompt-generator.md").read_text(encoding="utf-8")
        self.assertEqual(prompt.count("{prose_reviewer_principles}"), 1)
        prose_section = re.search(r"(?ms)^## 文書の論証と読み手の負担.*?(?=^## )", prompt).group()
        self.assertIn("tech-writer 以外", prose_section)
        self.assertIn("セクション全体を省略", prose_section)
        # The ordinary template is retained in all existing review compositions.
        selection = pr_review.split("**Template selection logic:**", 1)[1].split("**Placeholder embedding method:**", 1)[0]
        self.assertIn("Both: this section's (4.5.1) verification template AND the normal template", selection)
        self.assertIn("Normal template from ステップ 4.5 のみ", selection)
        self.assertIn("{complexity_lane_mandate}", prompt)
        self.assertIn("{cycle_scope_mandate}", prompt)
        self.assertIn("{shared_reviewer_principles}", prompt)
        self.assertIn("4 必須自問", prompt)
        self.assertIn("references/prose-reasoning.md", handoff_part)
        self.assertIn("名簿から外して続行しない", handoff_part)
        profile = (plugin / "agents/tech-writer-reviewer.md").read_text(encoding="utf-8")
        self.assertIn("Before starting any review, read that file from beginning to end", profile)
        self.assertIn("raw output’s first `読取完了:`", profile)
        self.assertIn("Step 1: Fact-Check All References", profile)
        # Exact view extraction includes both language scopes, excluding wrapper/source.
        reasoning = (plugin / "references/prose-reasoning.md").read_text(encoding="utf-8")
        self.assertEqual(len(re.findall(r"(?m)^## 読み手用観点$", reasoning)), 1)
        view = re.search(r"(?ms)^## 読み手用観点\n(.*?)(?=^## |\Z)", reasoning).group(1)
        self.assertTrue(view.strip())
        self.assertIn("### 言語に共通する観点", view)
        self.assertIn("### 日本語の説明文だけに適用する観点", view)
        self.assertNotIn("## 出典", view)
        self.assertNotIn("文書の作成前点検と tech-writer", view)
        readability = (plugin / "references/body-readability-check.md").read_text(encoding="utf-8")
        extraction_blocks = [block for block in re.findall(r"(?ms)^```bash\n(.*?)^```", readability)
                             if "# prose-reasoning-reader-view" in block]
        self.assertEqual(len(extraction_blocks), 1)
        extraction_code = extraction_blocks[0].replace("{plugin_root}", str(plugin))
        result = subprocess.run(["bash", "-c", extraction_code], capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "## 読み手用観点\n" + view)
        self.assertEqual(readability.count("\n{prose_reasoning_checks}\n"), 1)
        # A second or empty section must fail, rather than injecting ambiguous criteria.
        for label, content in [
                ("duplicate", "## 読み手用観点\nfirst\n## 別節\nother\n## 読み手用観点\nsecond\n"),
                ("empty", "## 読み手用観点\n\n## 出典\nsource\n"),
                ("missing heading", "## 別節\ncontent\n")]:
            unreadable.write_text(content, encoding="utf-8")
            result = subprocess.run(["bash", "-c", extraction_blocks[0].replace("{plugin_root}", str(no_prose))],
                                    capture_output=True, text=True, timeout=20)
            self.assertNotEqual(result.returncode, 0, label)
            self.assertEqual(result.stdout, "", label)
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
        measured_reroll = next(line for line in pr_review.splitlines()
                              if line.startswith("| `[CONTEXT] MEASURED_GATE_FAILED=1; reason=verification_preset_by_caller`"))
        self.assertIn("update manifest", likelihood_retry)
        self.assertIn("を更新し", measured_reroll)
        for line, following in [(likelihood_retry, "and rerun this helper"),
                                (measured_reroll, "step 1 の JSON を作り直し step 2")]:
            with self.subTest(route=following):
                for clause in ["manifest", "agent_id", "output_file", "読取完了申告の照合", "5.1 の回収完了ゲート"]:
                    self.assertIn(clause, line)
                self.assertLess(line.index("manifest"), line.index("5.1 の回収完了ゲート"))
                self.assertLess(line.index("5.1 の回収完了ゲート"), line.index(following))
        for marker in ["| rc=1 + `reason ∈ {table_missing,", "retry の回収結果で manifest を更新し",
                       "| rc=1 + `reason=unmet_finding_not_blocking`"]:
            line = next(line for line in pr_review.splitlines() if line.startswith(marker))
            self.assertIn("5.1 の回収完了ゲート", line, marker)
        # Every line that reruns the collection gate replaces a reviewer output, so it
        # reruns the producer gate after it: a regenerated output never reaches
        # aggregation unchecked. The checked lines are the ones that name the
        # collection gate together with 再実行 / rerun. The producer gate's own
        # retry row is left out: it reruns its helper directly (pinned above).
        regenerating = [line for line in pr_review.splitlines()
                        if "回収完了ゲート" in line and ("再実行" in line or "rerun" in line)
                        and line != likelihood_retry]
        for marker in ["| rc=1 + `reason ∈ {table_missing,", "retry の回収結果で manifest を更新し",
                       "| `[CONTEXT] MEASURED_GATE_FAILED=1; reason=verification_preset_by_caller`",
                       "| rc=1 + `reason=unmet_finding_not_blocking`"]:
            self.assertTrue(any(line.startswith(marker) for line in regenerating), marker)
        for line in regenerating:
            with self.subTest(regenerated_by=line[:60]):
                self.assertIn("5.1.0.L", line)
                self.assertLess(line.index("回収完了ゲート"), line.index("5.1.0.L"))
        # The retry of a missing verification table replaces the output too, so its
        # recommendations are extracted again after the producer gate passed.
        retry_row = next(line for line in regenerating if line.startswith("retry の回収結果で manifest を更新し"))
        self.assertIn("推奨事項を抽出し直す", retry_row)
        self.assertLess(retry_row.index("5.1.0.L"), retry_row.index("推奨事項を抽出し直す"))
        # The measured-gate row rebuilds the JSON only after the regenerated output
        # passed every output check and its recommendations were extracted again.
        order = ["5.1 の回収完了ゲート", "5.1.0.L", "5.1.0.AC", "推奨事項を抽出し直し", "step 1 の JSON を作り直し step 2"]
        for clause in order:
            self.assertIn(clause, measured_reroll)
        positions = [measured_reroll.index(clause) for clause in order]
        self.assertEqual(positions, sorted(positions), order)
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

    def run_readability(self, command):
        return subprocess.run(command, cwd=self.fixture, env=self.env,
                              capture_output=True, text=True, timeout=20)

    def readability_guard(self):
        reference = (plugin / "references/body-readability-check.md").read_text(encoding="utf-8")
        blocks = [b for b in re.findall(r"(?ms)^```python\n(.*?)^```", reference)
                  if b.startswith("# readability-version-guard\n")]
        self.assertEqual(len(blocks), 1)
        guard = self.fixture / "readability_guard.py"
        guard.write_text(blocks[0], encoding="utf-8")
        return guard

    def record_readability(self, guard, title, body, record, status="reviewed"):
        command = ["python3", str(guard), "record", "--title-file", str(title),
                   "--body-file", str(body), "--record-file", str(record), "--status", status]
        if status != "reviewed":
            warning = record.with_suffix(".warning")
            warning.write_text("箇所: 冒頭; 不足: 続行理由\n", encoding="utf-8")
            command += ["--warning-file", str(warning)]
        result = self.run_readability(command)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_readability_divergence_requires_all_three_conditions(self):
        text = (plugin / "references/body-readability-check.md").read_text(encoding="utf-8")
        step = text.split("6. 次の順で停止条件を判定する。", 1)[1].split("\n7. ", 1)[0]
        divergence = step.split("**発散**:", 1)[1].split("\n   - **点検不能**:", 1)[0]
        for clause in ["前回の指摘がすべて解消済み", "4 つの問いにすべて根拠つきで答えられ",
                       "新しい指摘が前回とは別の細部だけ", "三条件がすべて成立するときだけ",
                       "前回指摘が未解消", "回答または根拠が不足", "新しい指摘が細部以外なら発散としない",
                       "「不明」「推測が必要」が残る間", "書き直して再点検する"]:
            self.assertIn(clause, divergence)
        self.assertIn("発散も非収束と同じ下の Bash で stderr へ出し", step)
        self.assertIn("利用者への確認を求めず", step)
        self.assertIn("回数・点数による合否は設けない", step)

    def test_readability_non_convergence_and_reader_contract_are_preserved(self):
        text = (plugin / "references/body-readability-check.md").read_text(encoding="utf-8")
        step = text.split("6. 次の順で停止条件を判定する。", 1)[1].split("\n7. ", 1)[0]
        non_convergence = step.split("**非収束**:", 1)[1].split("\n   - **発散**:", 1)[0]
        self.assertIn("同じ意味の指摘（不足している情報と本文の該当箇所が同じ）が再出現", non_convergence)
        self.assertIn("書き直してもタイトル・冒頭本文が変わらなかった", non_convergence)
        self.assertIn("表現や並び順の変更は解消と数えない", step)
        self.assertIn("書き直した版は再点検前に記録しない", text)
        for clause in ["会話を引き継がない新しい読み手", "同じエージェントへ follow-up しない",
                       "図の読取失敗や共有観点の抽出失敗をこの経路へ回さない"]:
            self.assertIn(clause, text)

    def test_readability_version_checks_title_and_summary_boundary(self):
        guard = self.readability_guard()
        title, body, record = [self.fixture / name for name in ["title.txt", "body.md", "receipt.json"]]
        title.write_text("本文の点検\n", encoding="utf-8")
        original = "## 要約\n説明\n<details>契約</details>\n"
        body.write_text(original, encoding="utf-8")
        self.record_readability(guard, title, body, record)
        check = ["python3", str(guard), "check", "--title-file", str(title),
                 "--body-file", str(body), "--record-file", str(record)]
        result = self.run_readability(check)
        self.assertEqual(result.returncode, 0, result.stderr)
        body.write_text(original.replace("契約", "契約更新"), encoding="utf-8")
        self.assertEqual(self.run_readability(check).returncode, 0)
        for changed_title, changed_body in [("別のタイトル", original),
                                            ("本文の点検", original.replace("説明", "書き直した説明"))]:
            title.write_text(changed_title + "\n", encoding="utf-8")
            body.write_text(changed_body, encoding="utf-8")
            result = self.run_readability(check)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("作成せず手順 2 へ戻る", result.stderr)
        record.unlink()
        self.assertNotEqual(self.run_readability(check).returncode, 0)

    def test_readability_continuation_status_and_warning_belong_to_one_version(self):
        guard = self.readability_guard()
        title, body, record = [self.fixture / name for name in ["title.txt", "body.md", "receipt.json"]]
        title.write_text("作成前の点検\n", encoding="utf-8")
        body.write_text("冒頭本文\n<details>契約</details>\n", encoding="utf-8")
        labels = {"reviewed": "点検済み", "unreviewed": "未点検で続行",
                  "non_convergent": "非収束で続行", "divergent": "発散で続行"}
        for status, label in labels.items():
            with self.subTest(status=status):
                self.record_readability(guard, title, body, record, status)
                check = ["python3", str(guard), "check", "--title-file", str(title),
                         "--body-file", str(body), "--record-file", str(record)]
                result = self.run_readability(check)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(label, result.stdout)
                if status != "reviewed":
                    self.assertNotIn("点検済み", result.stdout)
                    self.assertIn("箇所: 冒頭; 不足: 続行理由", result.stdout)
                body.write_text("変更した冒頭\n<details>契約</details>\n", encoding="utf-8")
                self.assertNotEqual(self.run_readability(check).returncode, 0)
                body.write_text("冒頭本文\n<details>契約</details>\n", encoding="utf-8")
        result = self.run_readability(["python3", str(guard), "record", "--title-file", str(title),
                                   "--body-file", str(body), "--record-file", str(record), "--status", "unreviewed"])
        self.assertNotEqual(result.returncode, 0, "unreviewed continuation requires its reason")

    def test_readability_spec_checks_parent_and_each_child_before_creation(self):
        guard = self.readability_guard()
        issue = (plugin / "skills/issue-create/SKILL.md").read_text(encoding="utf-8")
        blocks = re.findall(r"(?ms)^```bash\n(.*?)^```", issue)
        single = next(b for b in blocks if "result=$(bash {plugin_root}/scripts/create-issue-with-projects.sh" in b)
        decomposed = next(b for b in blocks if "bash {plugin_root}/scripts/decompose-issues.sh --spec" in b)
        mock_plugin = self.fixture / "creator"
        (mock_plugin / "scripts").mkdir(parents=True)
        log = self.fixture / "create.log"
        for helper in ["create-issue-with-projects.sh", "decompose-issues.sh"]:
            (mock_plugin / "scripts" / helper).write_text(
                '#!/bin/bash\nprintf "%s\\n" "$@" > "$CREATE_LOG"\n'
                'printf \'%s\\n\' \'{"issue_number":123,"project_registration":"registered"}\'\n',
                encoding="utf-8")
        (self.fixture / "attachments.json").write_text("[]", encoding="utf-8")
        self.env["CREATE_LOG"] = str(log)
        self.env["TMPDIR"] = str(self.fixture)

        def execute_caller(payload):
            values = {"plugin_root": str(mock_plugin), "owner_repo": "fixture/repo",
                      "owner": "fixture", "project_number": "1", "labels_csv": "",
                      "priority": "Medium", "complexity": "S", "field_name_status": "Status",
                      "field_name_priority": "Priority", "field_name_complexity": "Complexity",
                      "ATTACHMENTS_JSON_FILE": str(self.fixture / "attachments.json"),
                      "READABILITY_GUARD_FILE": str(guard), "DECOMPOSE_WORKDIR": str(self.fixture)}
            block = decomposed
            if "issue" in payload:
                doc = payload["issue"]
                values.update(title=doc["title"],
                              READABILITY_RECORD_FILE=records[doc["body_file"]])
                block = single.replace("\n{body}\n", "\n" + pathlib.Path(doc["body_file"]).read_text() + "\n")
            for key, value in values.items():
                block = block.replace("{" + key + "}", value)
            # Use each caller's own failure boundary, without adding set -e.
            return self.run_readability(["bash", "-c", block])

        documents, records = [], {}
        for name in ["parent", "child1", "child2"]:
            title, body, record = [self.fixture / (name + suffix) for suffix in [".txt", ".md", ".json"]]
            title.write_text(name + "\n", encoding="utf-8")
            body.write_text(name + "\n<details>契約</details>\n", encoding="utf-8")
            self.record_readability(guard, title, body, record)
            documents.append({"title": name, "body_file": str(body)})
            records[str(body)] = str(record)
        spec, mapping = self.fixture / "spec.json", self.fixture / "readability-records.json"
        mapping.write_text(json.dumps(records), encoding="utf-8")
        for payload in [{"issue": documents[0]}, {"parent": documents[0], "sub_issues": documents[1:]}]:
            spec.write_text(json.dumps(payload), encoding="utf-8")
            command = ["python3", str(guard), "check-spec", "--spec-file", str(spec)]
            command += (["--record-file", records[payload["issue"]["body_file"]]] if "issue" in payload
                        else ["--records-file", str(mapping)])
            self.assertEqual(self.run_readability(command).returncode, 0)
            result = execute_caller(payload)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(log.is_file(), "matching versions reach the creation helper")
            self.assertIn("READABILITY_VERSION=ok", result.stdout)
            log.unlink()
            targets = [payload["issue"]] if "issue" in payload else [payload["parent"], *payload["sub_issues"]]
            for doc in targets:
                for defect in ["title", "body", "record"]:
                    with self.subTest(document=doc["title"], defect=defect):
                        body = pathlib.Path(doc["body_file"])
                        record = pathlib.Path(records[str(body)])
                        old_title, old_body, old_record = doc["title"], body.read_text(), record.read_text()
                        if defect == "title":
                            doc["title"] += " changed"
                        elif defect == "body":
                            body.write_text("書き直し\n<details>契約</details>\n", encoding="utf-8")
                        else:
                            record.unlink()
                        spec.write_text(json.dumps(payload), encoding="utf-8")
                        result = self.run_readability(command)
                        self.assertNotEqual(result.returncode, 0)
                        self.assertNotIn("READABILITY_VERSION=ok", result.stdout)
                        retained = {path: path.read_bytes() for path in [body, spec, mapping, guard]
                                    if path.exists()}
                        if record.exists():
                            retained[record] = record.read_bytes()
                        result = execute_caller(payload)
                        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                        self.assertFalse(log.exists(), "rejected versions must not call the creation helper")
                        self.assertIn("作成せず手順 2 へ戻る", result.stderr)
                        for path, contents in retained.items():
                            self.assertTrue(path.is_file(), "rejection preserves " + path.name)
                            self.assertEqual(path.read_bytes(), contents)
                        doc["title"] = old_title
                        body.write_text(old_body, encoding="utf-8")
                        record.write_text(old_record, encoding="utf-8")

    def test_readability_callers_gate_real_creation_and_keep_result(self):
        issue = (plugin / "skills/issue-create/SKILL.md").read_text(encoding="utf-8")
        pr = (plugin / "skills/pr-create/SKILL.md").read_text(encoding="utf-8")
        sections = [issue.split("### 4.3 Issue 作成", 1)[1].split("### 4.4", 1)[0],
                    issue.split("**(B) body / spec の生成", 1)[1].split("### 5.5 Step 2", 1)[0],
                    pr.split("**(B) title / body の生成", 1)[1].split("### 3.5", 1)[0]]
        for section, mutation in zip(sections, ["result=$(bash {plugin_root}/scripts/create-issue-with-projects.sh",
                                               "bash {plugin_root}/scripts/decompose-issues.sh",
                                               "gh pr create -R"]):
            self.assertLess(section.index("記号の作成前検査"), section.index("読みやすさ点検"))
            self.assertLess(section.index("読みやすさ点検"), section.index("python3 "))
            self.assertLess(section.index("python3 "), section.index(mutation))
            self.assertIn("作成する版の記録と照合", section)
            self.assertNotIn("三条件", section)
            self.assertNotIn("**発散**", section)
        self.assertEqual(issue.count("共通照合出力の点検結果と警告全文"), 2)
        self.assertIn("E2E の表示省略時も caller へ返し", pr)
        # Run the actual PR creation block: guard rejection must prevent the gh
        # invocation and preserve files for a fresh reader, even with EXIT cleanup.
        guard = self.readability_guard()
        title, body, record = [self.fixture / name for name in ["pr_title.txt", "pr_body.md", "readability-record.json"]]
        title.write_text("作成前の点検\n", encoding="utf-8")
        body.write_text("冒頭\n<details>契約</details>\n", encoding="utf-8")
        (self.fixture / "attachments.json").write_text("[]", encoding="utf-8")
        self.record_readability(guard, title, body, record)
        log = self.fixture / "create.log"
        (self.bin / "gh").write_text('#!/bin/bash\nprintf "created\\n" >> "$CREATE_LOG"\nprintf "CREATE_CALLED\\n"\n', encoding="utf-8")
        self.env["CREATE_LOG"] = str(log)
        block = next(b for b in re.findall(r"(?ms)^```bash\n(.*?)^```", pr)
                     if b.startswith('pr_workdir="{PR_CREATE_WORKDIR}"'))
        for key, value in {"PR_CREATE_WORKDIR": str(self.fixture), "owner_repo": "fixture/repo",
                           "base_branch": "develop", "branch_name": "feature"}.items():
            block = block.replace("{" + key + "}", value)
        for defect in ["missing", "title", "body"]:
            saved = title.read_text(), body.read_text(), record.read_text()
            if defect == "missing":
                record.unlink()
            elif defect == "title":
                title.write_text("変更したタイトル\n", encoding="utf-8")
            else:
                body.write_text("書き直し後\n<details>契約</details>\n", encoding="utf-8")
            result = self.run_readability(["bash", "-c", block])
            self.assertNotEqual(result.returncode, 0, defect)
            self.assertFalse(log.exists(), defect)
            self.assertTrue(self.fixture.is_dir(), "failed check preserves workdir")
            for target, contents in zip([title, body, record], saved):
                target.write_text(contents, encoding="utf-8")
        result = self.run_readability(["bash", "-c", block])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.fixture.exists(), "successful create cleans its scratch directory")
        self.assertIn("CREATE_CALLED", result.stdout)
        self.assertIn("READABILITY_VERSION=ok", result.stdout)

    def lint_result_state(self, caller, result):
        lint = (plugin / "skills/lint/SKILL.md").read_text(encoding="utf-8")
        blocks = [b for b in re.findall(r"(?ms)^```bash\n(.*?)^```", lint)
                  if b.startswith("# lint-result-state\n")]
        self.assertEqual(len(blocks), 1)
        table = lint.split("| Caller | Result | `{lint_handoff}` |", 1)[1].split("\n\n", 1)[0]
        matches = []
        for row in table.splitlines():
            cells = [cell.strip() for cell in row.strip("|").split("|")]
            if len(cells) == 3 and "`" + caller + "`" in cells[0]:
                if "[lint:" + result + "]" in cells[1] or cells[1] == "全結果":
                    matches.append(cells[2])
        self.assertEqual(len(matches), 1, "expected one handoff row for " + caller + "/" + result)
        value = matches[0]
        self.assertTrue(value == "空" or re.fullmatch(r"`[^`]+`", value), "invalid handoff cell: " + value)
        handoff = "" if value == "空" else value.strip("`").replace("{issue_number}", "2624")
        code = blocks[0]
        for key, value in {"plugin_root": str(distribution), "lint_caller": caller,
                           "phase_value": "lint", "next_action_value": "return " + result,
                           "lint_handoff": handoff}.items():
            code = code.replace("{" + key + "}", value)
        self.run_command(["bash", "-c", code])
        return json.loads(self.flow_file.read_text())

    def open_lint_state(self):
        self.run_command(["bash", str(distribution / "hooks/flow-state.sh"), "set", "--phase", "lint",
                          "--issue", "2624", "--branch", "feature", "--pr", "0", "--next", "run lint"])

    def lint_stop(self):
        payload = json.dumps({"cwd": str(self.fixture), "session_id": self.current_id,
                              "stop_hook_active": False, "last_assistant_message": "[lint:skipped]"})
        result = subprocess.run(["bash", str(distribution / "hooks/stop-loop-continuation.sh")],
                                input=payload, cwd=self.fixture, env=self.env, capture_output=True,
                                text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout) if result.stdout else None

    def test_open_lint_return_blocks_early_stop_and_clears_after_real_pr_block(self):
        # Execute distributed state/Stop helpers and the actual PR creation block.
        # gh is a fixture: this is not a native Claude conversation or user choice.
        self.open_lint_state()
        state = self.lint_result_state("open", "skipped")
        self.assertEqual(state["handoff"], "OPEN:skipped:2624")
        bounce = self.lint_stop()
        self.assertEqual(bounce["decision"], "block")
        self.assertIn("[lint:skipped]", bounce["reason"])
        self.assertIn("ステップ 6", bounce["reason"])
        self.assertNotIn("[lint:success]", bounce["reason"])
        self.assertIsNone(self.lint_stop(), "consumed handoff must not loop")
        # Normal continuation may reach PR creation without an intervening Stop.
        self.lint_result_state("open", "skipped")
        pr = (plugin / "skills/pr-create/SKILL.md").read_text(encoding="utf-8")
        code = next(b for b in re.findall(r"(?ms)^```bash\n(.*?)^```", pr)
                    if b.startswith('pr_workdir="{PR_CREATE_WORKDIR}"'))
        scratch = self.fixture / "pr-create"
        scratch.mkdir()
        title, body, record = [scratch / n for n in ["pr_title.txt", "pr_body.md", "readability-record.json"]]
        title.write_text("lint スキップ後の継続\n", encoding="utf-8")
        lint = (plugin / "skills/lint/SKILL.md").read_text(encoding="utf-8")
        reason = re.search(r"(?m)^理由: (.+)$", lint).group(1)
        body.write_text("スキップ後も PR を作成する。\n<details>\n## Known Issues\n- lint 未実行（" +
                        reason + "）\n</details>\n", encoding="utf-8")
        (scratch / "attachments.json").write_text("[]", encoding="utf-8")
        guard = self.readability_guard()
        shutil.copy(guard, scratch / "readability_guard.py")
        self.record_readability(guard, title, body, record)
        self.env["CREATE_LOG"] = str(self.fixture / "create.log")
        self.env["CREATED_BODY"] = str(self.fixture / "created-body.md")
        (self.bin / "gh").write_text('#!/bin/bash\nset -eu\n'
                                     '[ "$1 $2" = "pr create" ]\n'
                                     'printf "%s\\n" "$*" >> "$CREATE_LOG"\n'
                                     'while [ "$#" -gt 0 ]; do\n'
                                     '  if [ "$1" = "--body-file" ]; then cp "$2" "$CREATED_BODY"; fi\n'
                                     '  shift\ndone\n'
                                     'printf "https://github.com/fixture/repo/pull/3000\\n"\n', encoding="utf-8")
        for key, value in {"PR_CREATE_WORKDIR": str(scratch), "owner_repo": "fixture/repo",
                           "base_branch": "develop", "branch_name": "feature"}.items():
            code = code.replace("{" + key + "}", value)
        output = self.run_command(["bash", "-c", code])
        self.assertIn("/pull/3000", output)
        self.assertIn("--draft", pathlib.Path(self.env["CREATE_LOG"]).read_text())
        self.assertIn(reason, pathlib.Path(self.env["CREATED_BODY"]).read_text())
        open_skill = (plugin / "skills/open/SKILL.md").read_text(encoding="utf-8")
        finish = open_skill.split("### 6.3 flow-state 更新", 1)[1]
        code = re.findall(r"(?ms)^```bash\n(.*?)^```", finish)[0]
        for key, value in {"plugin_root": str(distribution), "issue_number": "2624",
                           "branch_name": "feature", "pr_number": "3000"}.items():
            code = code.replace("{" + key + "}", value)
        self.run_command(["bash", "-c", code])
        state = json.loads(self.flow_file.read_text())
        self.assertEqual((state["phase"], state["pr_number"]), ("pr", 3000))
        self.assertNotIn("handoff", state)
        self.assertIsNone(self.lint_stop())
        self.assertEqual(len(pathlib.Path(self.env["CREATE_LOG"]).read_text().splitlines()), 1)

    def test_standalone_lint_skip_leaves_existing_open_state_untouched(self):
        self.open_lint_state()
        original = self.flow_file.read_bytes()
        state = self.lint_result_state("standalone", "skipped")
        self.assertEqual(self.flow_file.read_bytes(), original)
        self.assertNotIn("handoff", state)
        self.assertIsNone(self.lint_stop())
        self.assertFalse((self.fixture / "gh.log").exists())

    def test_lint_abort_and_error_clear_pending_open_continuation(self):
        for result in ["aborted", "error"]:
            self.open_lint_state()
            self.lint_result_state("open", "skipped")
            state = self.lint_result_state("open", result)
            self.assertNotIn("handoff", state)
            self.assertIsNone(self.lint_stop())
            self.assertEqual(state["pr_number"], 0)
        # Retry error remains stopped; only a successful retry arms continuation.
        self.lint_result_state("open", "error")
        self.assertIsNone(self.lint_stop())
        self.lint_result_state("open", "success")
        self.assertIn("[lint:success]", self.lint_stop()["reason"])
        self.assertFalse((self.fixture / "gh.log").exists())

    def test_other_lint_caller_and_batch_skip_keep_their_return_boundaries(self):
        self.open_lint_state()
        state = self.lint_result_state("other", "skipped")
        self.assertNotIn("handoff", state)
        self.assertIsNone(self.lint_stop())
        self.queue.write_text('{"issues":[2624],"cursor":0,"mode":"default","active":true}\n')
        original = self.queue.read_bytes()
        self.lint_result_state("open", "skipped")
        self.assertEqual(self.lint_stop()["decision"], "block")
        self.assertEqual(self.queue.read_bytes(), original)
        self.assert_foreign_unchanged()

    def test_lint_early_return_and_nested_caller_contracts_are_connected(self):
        lint = (plugin / "skills/lint/SKILL.md").read_text(encoding="utf-8")
        early = lint.split("### 1.3 When Command Cannot Be Detected", 1)[1].split("## Phase 2:", 1)[0]
        self.assertIn("結果表示前に Phase 4.0、4.4", early)
        self.assertIn("Phase 4.0 を aborted で実行", early)
        self.assertIn("sub-skill の return でありターン終了ではない", early)
        self.assertIn("保存 state・ブランチ・過去の open の会話だけで caller を推定しない", lint)
        implement = (plugin / "skills/issue-implement/SKILL.md").read_text(encoding="utf-8")
        self.assertIn("**4c**: lint の return 後", implement)
        self.assertIn("継続 handoff を別の `flow-state.sh set` で消さず", implement)
        open_skill = (plugin / "skills/open/SKILL.md").read_text(encoding="utf-8")
        consume = open_skill.split("## ステップ 5:", 1)[1].split("## ステップ 6:", 1)[0]
        self.assertIn("**同じターンでステップ 6 の push と PR 作成を実行**", consume)
        self.assertIn("再失敗なら停止", consume)
        self.assertIn("**1 回だけ**", consume)
        self.assertIn("Known Issues", consume)

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
