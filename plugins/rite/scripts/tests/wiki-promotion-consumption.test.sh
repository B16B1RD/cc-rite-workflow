#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 - "$SCRIPT_DIR/../../.." <<'PY'
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

plugin = Path(sys.argv[1]).resolve() / "rite"
batch = (plugin / "skills/batch-run/SKILL.md").read_text()
ingest = (plugin / "skills/wiki-ingest/SKILL.md").read_text()


class Caller(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cwd = Path(self.tmp.name) / "source"
        self.cwd.mkdir()
        self.wiki = self.cwd / ".rite/wiki"
        (self.wiki / "raw/reviews").mkdir(parents=True)
        scripts = self.cwd / "plugins/rite/hooks/scripts"
        scripts.mkdir(parents=True)
        for name in ("wiki-promotion-candidates.sh", "wiki-promotion-candidates.py"):
            shutil.copy(plugin / "hooks/scripts" / name, scripts / name)
        subprocess.run(["git", "init", "-q", str(self.cwd)], check=True)
        subprocess.run(["git", "remote", "add", "origin", "https://github.com/example/project.git"],
                       cwd=self.cwd, check=True)
        subprocess.run(["git", "add", "plugins"], cwd=self.cwd, check=True)
        self.raw = "raw/reviews/example.md"
        (self.wiki / self.raw).write_text('---\ningested: true\ningest_status: skipped\nskip_reason: "detector-candidate: preserve source"\n---\n\nOriginal condition and counterexample\n')
        self.input = Path(self.tmp.name) / "work.json"
        self.replacements = {"{plugin_root}": str(self.cwd / "plugins/rite"),
                             "{wiki_root_abs}": str(self.wiki), "{execution_cwd}": str(self.cwd),
                             "{owner_repo}": "example/project", "{promotion_work_file}": str(self.input)}
        entry = batch.split("## 昇格候補の消化", 1)[1].split("## ステップ 0:", 1)[0]
        self.calls = re.findall(r"```bash\n(.*?)\n[ \t]*```", entry, re.S)

    def tearDown(self):
        self.tmp.cleanup()

    def invoke(self, index, cwd=None):
        command = self.calls[index]
        for source, value in self.replacements.items():
            command = command.replace(source, value)
        return subprocess.run(["bash", "-e", "-c", command], cwd=cwd or self.cwd,
                              text=True, capture_output=True)

    def test_actual_caller_fences_persist_work_and_resume_legacy_candidates(self):
        first = self.invoke(0)
        self.assertEqual(first.returncode, 0, first.stderr)
        rows = json.loads(first.stdout)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["status"], "unresolved")
        self.assertIn("counterexample", rows[0]["excerpt"])
        work = dict(candidate=rows[0]["id"], raw=self.raw, condition="review trigger",
                    consumer="plugins/rite/hooks/scripts/example.sh",
                    issue_url="https://github.com/example/project/issues/1")
        self.input.write_text(json.dumps([work]))
        self.assertEqual(self.invoke(1).returncode, 0)
        again = self.invoke(0)
        item = json.loads(again.stdout)[0]
        self.assertEqual(item["work"]["issue_url"], work["issue_url"])
        self.assertEqual(item["status"], "unresolved")
        self.assertEqual((self.wiki / "log.md").read_text().count('"status": "linked"'), 1)
        self.assertIn("detector-candidate:", (self.wiki / self.raw).read_text())

    def test_distribution_source_and_repository_mismatch_stop_before_external_calls(self):
        installed = Path(self.tmp.name) / "installed/rite/hooks/scripts"
        installed.mkdir(parents=True)
        shutil.copy(plugin / "hooks/scripts/wiki-promotion-candidates.py", installed)
        self.replacements["{plugin_root}"] = str(installed.parents[1])
        rejected = self.invoke(0)
        self.assertNotEqual(rejected.returncode, 0)
        self.replacements["{plugin_root}"] = str(self.cwd / "plugins/rite")
        self.replacements["{owner_repo}"] = "another/project"
        rejected = self.invoke(0)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertFalse((self.wiki / "log.md").exists())

    def test_failed_link_preserves_raw_and_existing_issue_evidence(self):
        first = json.loads(self.invoke(0).stdout)[0]
        self.input.write_text(json.dumps([dict(candidate=first["id"], raw=self.raw,
                                              consumer="consumer.sh", condition="trigger")]))
        failed = self.invoke(1)
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("missing work issue_url", failed.stderr)
        self.assertIn("Original condition", (self.wiki / self.raw).read_text())
        self.assertEqual(len(json.loads(self.invoke(0).stdout)), 1)

    def test_skill_handoffs_use_issue_create_gate_projects_open_iterate_and_recover(self):
        entry = batch.split("## 昇格候補の消化", 1)[1].split("## ステップ 0:", 1)[0]
        self.assertIn("skill: rite:issue-create", entry)
        self.assertIn("promotion_caller=batch-run", entry)
        self.assertIn("[create:returned-to-caller:N]", entry)
        self.assertIn("Projects 登録の実結果", entry)
        self.assertLess(entry.index("skill: rite:issue-create"), entry.index("wiki-promotion-candidates.sh link"))
        self.assertIn("skill: rite:open", batch.split("## ステップ 2:", 1)[1].split("## ステップ 3:", 1)[0])
        self.assertIn("skill: rite:iterate", batch.split("## ステップ 3:", 1)[1].split("## ステップ 4:", 1)[0])
        create = (plugin / "skills/issue-create/SKILL.md").read_text()
        for required in ("duplicate_check", "--step confirm", "fact_check", "Projects"):
            self.assertIn(required, create)
        recover = (plugin / "skills/recover/SKILL.md").read_text().split("### 5.5.3", 1)[1]
        self.assertIn("結果の突合と再開", recover)
        self.assertIn("cursor 前進", recover)

    def test_ingest_classifies_before_matching_and_finishes_after_all_saves(self):
        section = ingest.split("## ステップ 4:", 1)[1].split("### 4.1", 1)[0]
        rows = [line for line in section.splitlines() if line.startswith("| ")]
        self.assertIn("rite の責務", rows[1])
        self.assertIn("既存更新もしない", rows[1])
        self.assertNotIn("detector_candidate=true", section)
        saving = ingest.split("### 5.0 ", 1)[1].split("### 5.0.r", 1)[0]
        self.assertLess(saving.index("wiki-promotion-candidates.sh record"), saving.index("3. **新規 Wiki"))
        self.assertLess(saving.index("7. **log.md"), saving.index("wiki-promotion-candidates.sh finish"))
        self.assertIn("domain ページのみ登録", ingest)
        for strategy in ("separate_branch", "same_branch"):
            self.assertIn(strategy, saving)

    def test_schema_template_and_readmes_match_the_candidate_contract(self):
        schema = (plugin / "templates/wiki/schema-template.md").read_text()
        for path in ("README.md", "README.ja.md"):
            text = (plugin.parent.parent / path).read_text()
            self.assertIn("/rite:batch-run --promotions", text)
        self.assertIn("新規 `promote: rite-plugin` ページを作らない", schema)
        self.assertIn("既存の `promote` / `reference`", schema)
        self.assertIn("抽出完了で、昇格完了ではない", schema)

    def test_domain_and_candidate_save_commit_and_relist_in_both_strategies(self):
        for strategy in ("same_branch", "separate_branch"):
            with self.subTest(strategy=strategy):
                root = Path(self.tmp.name) / strategy
                root.mkdir()
                shutil.copytree(plugin / "hooks", root / "plugins/rite/hooks")
                subprocess.run(["git", "init", "-q", str(root)], check=True)
                for key, value in (("user.name", "fixture"), ("user.email", "fixture@localhost")):
                    subprocess.run(["git", "config", key, value], cwd=root, check=True)
                config = "wiki:\n  enabled: true\n  branch_strategy: " + strategy + "\n  branch_name: wiki\n"
                (root / "rite-config.yml").write_text(config)
                subprocess.run(["git", "add", "plugins", "rite-config.yml"], cwd=root, check=True)
                subprocess.run(["git", "commit", "-qm", "fixture"], cwd=root, check=True)
                environment = dict(os.environ)
                for key in ("RITE_STATE_ROOT", "CODEX_THREAD_ID", "CLAUDE_CODE_SESSION_ID", "CLAUDE_SESSION_ID", "GROK_SESSION_ID", "RITE_HOST"):
                    environment.pop(key, None)
                tree = root
                if strategy == "separate_branch":
                    tree = root / ".rite/wiki-worktree"
                    subprocess.run(["git", "worktree", "add", "-qb", "wiki", str(tree)], cwd=root, check=True)
                wiki = tree / ".rite/wiki"
                (wiki / "raw/reviews").mkdir(parents=True)
                (wiki / self.raw).write_text("---\ningested: false\n---\n\nRite rule\nDomain rule\n")
                routing = Path(self.tmp.name) / (strategy + ".json")
                routing.write_text(json.dumps({"candidates": [{"summary": "Rite rule", "source": {"start_line": 1, "end_line": 1},
                                                "condition": "trigger", "consumer": "plugins/rite/hooks/scripts/example.sh"}],
                                                "pages": ["pages/patterns/domain.md"]}))
                helper = root / "plugins/rite/hooks/scripts/wiki-promotion-candidates.sh"
                def call(action, *extra):
                    result = subprocess.run(["bash", str(helper), action, "--wiki-root", str(wiki), *extra],
                                            cwd=root, env=environment, text=True, capture_output=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    return result.stdout
                call("record", "--raw", self.raw, "--input", str(routing))
                (wiki / "pages/patterns").mkdir(parents=True)
                page = "pages/patterns/domain.md"
                (wiki / page).write_text('---\nsources:\n  - type: review\n    resource: "' + self.raw + '"\n---\n\nDomain rule')
                (wiki / "index.md").write_text(page)
                (wiki / "log.md").write_text((wiki / "log.md").read_text() + "\n* Update " + page + " " + self.raw)
                call("finish", "--raw", self.raw)
                if strategy == "same_branch":
                    section = ingest.split("### 5.2 same_branch", 1)[1].split("### 5.3", 1)[0]
                    block = re.findall(r"```bash\n(.*?)\n```", section, re.S)[0]
                    block = block.replace("{plugin_root}", str(root / "plugins/rite")).replace("{branch_strategy}", strategy)
                    block = block.replace("{numref_verdict}", "clean").replace("{wiki_ingest_commit_message}", "chore(wiki): integrate domain knowledge")
                    result = subprocess.run(["bash", "-c", block], cwd=root, env=environment, text=True, capture_output=True)
                else:
                    result = subprocess.run(["bash", str(root / "plugins/rite/hooks/scripts/wiki-worktree-commit.sh"),
                                             "--commit-only", "--message", "chore(wiki): integrate domain knowledge"],
                                            cwd=root, env=environment, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                stored = subprocess.check_output(["git", "show", "HEAD:.rite/wiki/" + self.raw], cwd=tree, text=True)
                self.assertIn("ingested: true", stored)
                self.assertEqual(len(json.loads(call("list"))), 1)
                lint = subprocess.run(["bash", str(root / "plugins/rite/hooks/scripts/wiki-lint-source-refs.sh"),
                                       "--branch-strategy", strategy, "--wiki-branch", "wiki", "--repo-root", str(root)],
                                      input=".rite/wiki/" + page + "\n", cwd=root, env=environment, text=True, capture_output=True)
                self.assertEqual(lint.returncode, 0, lint.stderr)
                self.assertIn("read_ok=true", lint.stdout)


unittest.main(argv=["wiki-promotion-consumption"], verbosity=2)
PY
