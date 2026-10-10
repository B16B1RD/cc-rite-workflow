#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 - "$SCRIPT_DIR/../scripts/wiki-promotion-candidates.py" <<'PY'
import importlib.util
import contextlib
import io
import json
import subprocess
import sys
import tempfile
import unittest
import shlex
import re
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("promotion", sys.argv[1])
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


class Candidates(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "raw/reviews").mkdir(parents=True)
        (self.root / "pages/patterns").mkdir(parents=True)
        self.raw = "raw/reviews/example.md"
        (self.root / self.raw).write_text("---\ntype: review\ningested: false\n---\n\nRite insight\nDomain insight\n")
        self.item = {"summary": "Route knowledge", "source": {"start_line": 1, "end_line": 1},
                     "condition": "workflow review", "consumer": "plugins/rite/hooks/scripts/consumer.sh"}
        self.input = self.root / "input.json"
        (self.root / "log.md").write_text("# Directory Update Log\n")

    def tearDown(self):
        self.tmp.cleanup()

    def save(self, candidates=None, pages=None, **extra):
        self.input.write_text(json.dumps(dict(candidates=candidates if candidates is not None else [self.item],
                                               pages=pages or [], **extra)))
        p.record(self.root, self.raw, self.input)

    def test_rite_candidates_never_create_or_update_existing_pages(self):
        existing = self.root / "pages/patterns/rite.md"
        existing.write_text("existing rite page")
        for mechanically_detectable in (True, False):
            for page_exists in (True, False):
                with self.subTest(detectable=mechanically_detectable, existing=page_exists):
                    self.save()
                    p.finish(self.root, self.raw)
                    self.assertEqual(existing.read_text(), "existing rite page")
                    self.assertEqual(len(list((self.root / "pages").rglob("*.md"))), 1)
                    rows = p.listed(self.root)
                    self.assertEqual(rows[0]["excerpt"], "Rite insight")
                    self.assertIn(self.raw, (self.root / "log.md").read_text())

    def test_mixed_and_domain_only_save_before_extraction(self):
        page = "pages/patterns/domain.md"
        for candidates in ([self.item], []):
            with self.subTest(mixed=bool(candidates)):
                (self.root / self.raw).write_text("---\ntype: review\ningested: false\n---\n\nRite insight\nDomain insight\n")
                (self.root / page).unlink(missing_ok=True)
                self.save(candidates=candidates, pages=[page])
                with self.assertRaises(FileNotFoundError):
                    p.finish(self.root, self.raw)
                self.assertEqual(p.field(p.read_raw(self.root, self.raw), "ingested"), "false")
                (self.root / page).write_text('---\nsources:\n  - type: review\n    resource: "' + self.raw + '"\n---\n\ndomain insight')
                (self.root / "index.md").write_text(page)
                (self.root / "log.md").write_text((self.root / "log.md").read_text() + "\n* Update " + page + " from " + self.raw)
                p.finish(self.root, self.raw)
                self.assertEqual(p.field(p.read_raw(self.root, self.raw), "ingested"), "true")
                self.assertEqual(len(p.raw_candidates(self.root, self.raw)), len(candidates))

    def test_raw_and_log_save_failure_preserve_reextractable_source(self):
        original = (self.root / self.raw).read_text()
        real_write = p.atomic_write
        for failing in (self.root / self.raw, self.root / "log.md"):
            (self.root / "log.md").write_text("# Directory Update Log\n")
            def write(path, text, *args, **kwargs):
                if path == failing:
                    raise OSError("injected save failure")
                return real_write(path, text, *args, **kwargs)
            with self.subTest(path=failing), patch.object(p, "atomic_write", write):
                with self.assertRaisesRegex(OSError, "injected"):
                    self.save()
            self.assertEqual(p.field(p.read_raw(self.root, self.raw), "ingested"), "false")
            self.assertIn("Rite insight", (self.root / self.raw).read_text())
            self.save()
            p.finish(self.root, self.raw)
            (self.root / self.raw).write_text(original)

    def test_candidate_replay_is_idempotent_and_keeps_source_identity(self):
        self.save()
        first = p.listed(self.root)[0]
        p.finish(self.root, self.raw)
        self.save()
        second = p.listed(self.root)[0]
        self.assertEqual(first["id"], second["id"])
        self.assertEqual((self.root / "log.md").read_text().count("rite-promotion:"), 1)
        text = (self.root / self.raw).read_text().replace("Rite insight", "Changed insight", 1)
        (self.root / self.raw).write_text(text)
        with self.assertRaisesRegex(ValueError, "source changed"):
            p.listed(self.root)

    def test_legacy_ingested_and_uningested_candidates_are_both_listed(self):
        for ingested in ("true", "false"):
            path = self.root / ("raw/reviews/" + ingested + ".md")
            path.write_text('---\ningested: ' + ingested + '\ningest_status: skipped\nskip_reason: "detector-candidate: same responsibility"\n---\n\nOriginal condition and counterexample\n')
        rows = p.listed(self.root)
        self.assertEqual(len(rows), 2)
        self.assertTrue(all(x["legacy"] for x in rows))
        self.assertTrue(all("counterexample" in x["excerpt"] for x in rows))

    def test_partial_domain_failure_does_not_discard_saved_candidate(self):
        self.save(pages=["pages/patterns/domain.md"])
        with self.assertRaises(OSError):
            p.finish(self.root, self.raw)
        self.assertEqual(len(p.listed(self.root)), 1)
        self.assertEqual(p.field(p.read_raw(self.root, self.raw), "ingested"), "false")

    def test_reclassification_retains_existing_candidates(self):
        self.save()
        before = p.listed(self.root)[0]["id"]
        self.save(candidates=[])
        self.assertEqual(p.listed(self.root)[0]["id"], before)

    def test_sentinel_conditions_roundtrip_in_existing_log_comments(self):
        self.item["condition"] = "when <!-- sentinel --> occurs"
        self.save()
        item = p.listed(self.root)[0]
        work = dict(candidate=item["id"], raw=self.raw, issue_url="https://github.com/example/project/issues/1",
                    consumer=item["consumer"], condition=item["condition"])
        self.input.write_text(json.dumps([work]))
        p.link(self.root, self.input)
        self.assertEqual(p.listed(self.root)[0]["work"]["condition"], self.item["condition"])

    def test_completion_is_rechecked_and_acquisition_failure_stays_unresolved(self):
        self.save()
        with patch.object(p, "maintainer"), patch.object(p, "proof", return_value="a" * 40):
            p.reconcile(self.root, self.root, "example/project")
        self.assertEqual(p.listed(self.root)[0]["work"]["status"], "complete")
        with patch.object(p, "maintainer"), patch.object(p, "proof", side_effect=ValueError("API failed")):
            p.reconcile(self.root, self.root, "example/project")
        self.assertEqual(p.listed(self.root)[0]["work"]["status"], "unresolved")
        self.assertEqual(p.listed(self.root)[0]["work"]["reason"], "API failed")
        with patch.object(p, "maintainer"), patch.object(p, "proof", return_value="a" * 40):
            p.reconcile(self.root, self.root, "example/project")
        self.assertEqual(p.listed(self.root)[0]["work"]["status"], "complete")

    def test_partial_os_write_failures_keep_raw_and_log_originals(self):
        program = """
import pathlib, resource, runpy, signal, sys
p = runpy.run_path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
resource.setrlimit(resource.RLIMIT_FSIZE, (64, 64))
try:
    if sys.argv[3] == "record":
        p["record"](root, "raw/reviews/example.md", root / "input.json")
    elif sys.argv[3] == "finish":
        p["finish"](root, "raw/reviews/example.md")
    else:
        p["log_event"](root, {"candidate":"old", "raw":"raw/reviews/example.md", "status":"unresolved", "reason":"x"*200})
except OSError as error:
    print(str(error), file=sys.stderr)
    sys.exit(0)
sys.exit(1)
"""
        for action in ("record", "finish", "log"):
            with self.subTest(action=action):
                self.save()
                before_raw = (self.root / self.raw).read_bytes()
                before_log = (self.root / "log.md").read_bytes()
                self.input.write_text(json.dumps({"candidates":[self.item], "pages":[]}))
                result = subprocess.run(["python3", "-c", program, p.__file__, str(self.root), action],
                                        text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(str(self.root / ("log.md" if action == "log" else self.raw)), result.stderr)
                self.assertEqual((self.root / self.raw).read_bytes(), before_raw)
                self.assertEqual((self.root / "log.md").read_bytes(), before_log)
                self.assertFalse(list(self.root.rglob(".rite-promotion-*.tmp")))

    def test_legacy_candidate_reclassification_keeps_its_id_and_work(self):
        original = (self.root / self.raw).read_text()
        legacy = p.set_field(original, "skip_reason", '"detector-candidate: unresolved original"')
        (self.root / self.raw).write_text(legacy)
        item = p.listed(self.root)[0]
        work = dict(candidate=item["id"], raw=self.raw, condition="trigger", consumer=self.item["consumer"],
                    issue_url="https://github.com/example/project/issues/1")
        self.input.write_text(json.dumps([work]))
        p.link(self.root, self.input)
        self.save(candidates=[], pages=["pages/patterns/domain.md"])
        row = p.listed(self.root)[0]
        self.assertEqual(row["id"], item["id"])
        self.assertEqual(row["work"]["issue_url"], work["issue_url"])
        self.assertEqual(p.field(p.read_raw(self.root, self.raw), "ingest_status"), "partial")

    def test_identical_text_in_distinct_ranges_survives_replay(self):
        (self.root / self.raw).write_text("---\ningested: false\n---\n\nRite insight\nMiddle\nRite insight\n")
        second = dict(self.item, source={"end_line":3, "start_line":3})
        self.save(candidates=[self.item, second])
        first_ids = [x["id"] for x in p.listed(self.root)]
        self.assertEqual(len(set(first_ids)), 2)
        self.save(candidates=[self.item, dict(second, source={"start_line":3, "end_line":3})])
        self.assertEqual([x["id"] for x in p.listed(self.root)], first_ids)
        self.assertEqual({x["source"]["start_line"] for x in p.listed(self.root)}, {1,3})

    def test_record_list_finish_preserve_original_trailing_spaces(self):
        original = "---\ningested: false\n---\n\nRite insight  \n"
        (self.root / self.raw).write_text(original)
        self.save()
        row = p.listed(self.root)[0]
        self.assertEqual(row["excerpt"], "Rite insight  ")
        p.finish(self.root, self.raw)
        self.assertIn("Rite insight  \n", (self.root / self.raw).read_text())

    def test_work_history_uses_newest_event_and_keeps_distinct_conditions(self):
        self.save(candidates=[self.item, dict(self.item, condition="second condition")])
        rows = p.listed(self.root)
        self.assertNotEqual(rows[0]["id"], rows[1]["id"])
        item = rows[0]
        work = dict(candidate=item["id"], raw=self.raw, issue_url="https://github.com/example/project/issues/1",
                    consumer=item["consumer"], condition=item["condition"])
        self.input.write_text(json.dumps([work]))
        p.link(self.root, self.input)
        p.log_event(self.root, dict(work, status="unresolved", reason="draft"))
        self.assertEqual(p.listed(self.root)[0]["work"]["reason"], "draft")
        self.assertEqual(p.listed(self.root)[0]["work"]["issue_url"], work["issue_url"])
        self.save(candidates=[self.item])
        self.assertEqual(p.listed(self.root)[0]["work"]["issue_url"], work["issue_url"])

    def test_distribution_list_and_record_never_send_or_edit_plugin(self):
        with patch.object(p, "command", side_effect=AssertionError("unexpected external command")):
            self.save()
            p.finish(self.root, self.raw)
            self.assertEqual(len(p.listed(self.root)), 1)
        with self.assertRaises((ValueError, OSError)):
            p.maintainer(self.root, "example/project")


class Evidence(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cwd = Path(self.tmp.name)
        self.repo = "example/project"
        self.consumer = "plugins/rite/hooks/scripts/consumer.sh"
        self.caller = "plugins/rite/skills/example/SKILL.md"
        self.test = "plugins/rite/hooks/tests/consumer.test.sh"
        for path, text in {
            self.consumer: "#!/bin/bash\nprintf 'called\\n'\n",
            self.caller: '# Example\n\n```bash\nbash {plugin_root}/hooks/scripts/consumer.sh\n```\n',
            self.test: """#!/bin/bash
set -e
caller=plugins/rite/skills/example/SKILL.md
command=$(sed -n '/^```bash/,/^```/p' "$caller" | sed '1d;$d;s@{plugin_root}@plugins/rite@g')
test "$command" = "bash plugins/rite/hooks/scripts/consumer.sh"
test "$(bash -c "$command")" = called
""",
        }.items():
            target = self.cwd / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text)
        subprocess.run(["git", "init", "-q", str(self.cwd)], check=True)
        self.git("add", ".")
        self.git("-c", "user.name=fixture", "-c", "user.email=fixture@localhost", "commit", "-qm", "fixture")
        self.rev = self.git("rev-parse", "HEAD").strip()
        self.pr = dict(state="MERGED", isDraft=False, mergeCommit={"oid": self.rev},
                       closingIssuesReferences=[{"number": 1, "url": "https://github.com/example/project/issues/1"}])
        self.item = dict(id="source", raw="raw/reviews/source.md", consumer=self.consumer, condition="trigger",
                         work=dict(issue_url="https://github.com/example/project/issues/1",
                                   pr_url="https://github.com/example/project/pull/2", consumer=self.consumer,
                                   caller=self.caller, test=self.test, revision=self.rev, condition="trigger"))

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.cwd, text=True)

    def tearDown(self):
        self.tmp.cleanup()

    def verify(self):
        original = p.command
        def command(args, cwd=None):
            return json.dumps(self.pr) if args[0] == "gh" else original(args, cwd)
        with patch.object(p, "command", command):
            return p.proof(self.cwd, self.repo, self.item)

    def test_only_merged_caller_and_matching_verification_complete(self):
        self.assertEqual(self.verify(), self.rev)

    def test_display_only_caller_and_presence_only_test_are_unresolved(self):
        (self.cwd / self.caller).write_text('# Example\n\n```bash\nprintf "%s\\n" "bash plugins/rite/hooks/scripts/consumer.sh"\n```\n')
        (self.cwd / self.test).write_text('test -f ' + self.caller + '\ntest -f ' + self.consumer + '\n')
        self.publish()
        with self.assertRaisesRegex(ValueError, "not observed"):
            self.verify()

    def test_reference_read_through_executed_caller_is_observed(self):
        consumer = "plugins/rite/references/rule.md"
        (self.cwd / consumer).parent.mkdir(parents=True)
        (self.cwd / consumer).write_text("Read this rule\n")
        (self.cwd / self.caller).write_text('# Read references/rule.md\n\n```bash\ncat plugins/rite/references/rule.md\n```\n')
        self.item["consumer"] = consumer
        self.item["work"]["consumer"] = consumer
        (self.cwd / self.test).write_text('set -e\ncommand=$(sed -n \'/^\x60\x60\x60bash/,/^\x60\x60\x60/p\' ' +
                                         self.caller + ' | sed \'1d;$d\')\ntest "$(bash -c "$command")" = "Read this rule"\n')
        self.publish()
        self.assertEqual(self.verify(), self.rev)

    def test_reference_path_in_search_or_unread_arguments_stays_unresolved(self):
        consumer = "plugins/rite/references/rule.md"
        (self.cwd / consumer).parent.mkdir(parents=True)
        (self.cwd / consumer).write_text("NEVER READ\n")
        (self.cwd / "unrelated.txt").write_text(consumer + "\n")
        self.item["consumer"] = consumer
        self.item["work"]["consumer"] = consumer
        commands = [
            'printf "%s\\n" ' + consumer + ' | grep ' + consumer,
            'grep -q ' + consumer + ' unrelated.txt',
            "sed -n '1q' unrelated.txt " + consumer,
            # GNU cat prints help; BSD cat rejects --help. Neither reads the file.
            "cat --help " + consumer + " || :",
        ]
        for command in commands:
            with self.subTest(command=command):
                (self.cwd / self.caller).write_text('# Read references/rule.md\n\n```bash\n' + command + '\n```\n')
                (self.cwd / self.test).write_text('set -e\ncommand=$(sed -n \'/^```bash/,/^```/p\' ' +
                    self.caller + ' | sed \'1d;$d\')\nbash -c "$command" >/dev/null\n')
                self.publish()
                with self.assertRaisesRegex(ValueError, "not observed"):
                    self.verify()

    def test_actual_batch_fence_with_required_argument_substitutions_is_observed(self):
        caller = "plugins/rite/skills/batch-run/SKILL.md"
        consumer = "plugins/rite/hooks/scripts/wiki-promotion-candidates.sh"
        original = (Path(p.__file__).resolve().parents[2] / "skills/batch-run/SKILL.md").read_text()
        target = self.cwd / caller
        target.parent.mkdir(parents=True)
        target.write_text(original)
        (self.cwd / consumer).write_text('#!/bin/bash\nprintf "called\\n"\n')
        command = re.findall(r"```bash\n(.*?)\n[ \t]*```", original.split("## 昇格候補の消化", 1)[1], re.S)[0]
        for key, value in {"plugin_root": "plugins/rite", "wiki_root_abs": str(self.cwd / ".rite/wiki"),
                           "execution_cwd": str(self.cwd), "owner_repo": self.repo}.items():
            command = command.replace("{" + key + "}", value)
        (self.cwd / self.test).write_text('set -e\ncat ' + caller + ' >/dev/null\ntest "$(bash -c ' +
                                        shlex.quote(command) + ')" = called\n')
        self.item["consumer"] = consumer
        self.item["work"].update(consumer=consumer, caller=caller)
        self.publish()
        self.assertEqual(self.verify(), self.rev)
        (self.cwd / self.test).write_text('set -e\ncat ' + caller + ' >/dev/null\nbash -c ' +
                                        shlex.quote("printf unrelated; bash " + consumer) + '\n')
        self.publish()
        with self.assertRaisesRegex(ValueError, "not observed"):
            self.verify()

    def test_script_dir_wrapper_has_observed_python_invocation(self):
        caller = "plugins/rite/hooks/scripts/wrapper.sh"
        consumer = "plugins/rite/hooks/scripts/consumer.py"
        (self.cwd / caller).write_text('#!/bin/bash\nSCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\nexec python3 "$SCRIPT_DIR/consumer.py"\n')
        (self.cwd / consumer).write_text('print("called")\n')
        (self.cwd / self.test).write_text('test "$(bash ' + caller + ')" = called\n')
        self.item["consumer"] = consumer
        self.item["work"].update(consumer=consumer, caller=caller)
        self.publish()
        self.assertEqual(self.verify(), self.rev)

    def test_reader_only_and_independent_consumer_calls_do_not_prove_caller_use(self):
        caller = "plugins/rite/hooks/scripts/wrapper.sh"
        (self.cwd / caller).write_text('#!/bin/bash\nprintf "other\\n"\n')
        self.item["work"]["caller"] = caller
        for commands in ("cat " + caller + " >/dev/null\n", "bash " + caller + " >/dev/null\n"):
            (self.cwd / self.test).write_text(commands + 'test "$(bash ' + self.consumer + ')" = called\n')
            self.publish()
            with self.subTest(commands=commands), self.assertRaises(ValueError):
                self.verify()

    def test_unused_markdown_function_and_independent_call_do_not_complete(self):
        (self.cwd / self.caller).write_text('# Example\n\n```bash\nunused() { bash plugins/rite/hooks/scripts/consumer.sh; }\ntrue\n```\n')
        (self.cwd / self.test).write_text("""#!/bin/bash
caller=plugins/rite/skills/example/SKILL.md
command=$(sed -n '/^```bash/,/^```/p' "$caller" | sed '1d;$d;s@{plugin_root}@plugins/rite@g')
bash -c "$command"
test "$(bash plugins/rite/hooks/scripts/consumer.sh)" = called
""")
        self.publish()
        with self.assertRaisesRegex(ValueError, "not used through"):
            self.verify()

    def test_missing_draft_unmerged_other_issue_and_stale_revision_stay_unresolved(self):
        for key in ("pr_url", "consumer", "caller", "test", "revision"):
            original = self.item["work"].pop(key)
            with self.subTest(missing=key), self.assertRaises(ValueError):
                self.verify()
            self.item["work"][key] = original
        for field, value in (("state", "OPEN"), ("isDraft", True),
                             ("mergeCommit", None), ("closingIssuesReferences", [{"number": 99}])):
            original = self.pr[field]
            self.pr[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.verify()
            self.pr[field] = original
        self.item["work"]["revision"] = "f" * 40
        with self.assertRaisesRegex(ValueError, "merged revision"):
            self.verify()

    def publish(self):
        self.git("add", ".")
        self.git("-c", "user.name=fixture", "-c", "user.email=fixture@localhost", "commit", "-qm", "fixture change")
        self.rev = self.git("rev-parse", "HEAD").strip()
        self.pr["mergeCommit"]["oid"] = self.rev
        self.item["work"]["revision"] = self.rev

    def test_reference_prose_is_not_an_invoked_consumer(self):
        (self.cwd / self.caller).write_text("See [consumer](../../hooks/scripts/consumer.sh)")
        self.publish()
        with self.assertRaises(ValueError):
            self.verify()

    def test_verification_failure_and_unrelated_test_do_not_complete(self):
        for code in ("exit 1", "exit 0"):
            (self.cwd / self.test).write_text("#!/bin/bash\n" + code + "\n")
            self.publish()
            with self.subTest(code=code), self.assertRaises(ValueError):
                self.verify()


with contextlib.redirect_stdout(io.StringIO()):
    unittest.main(argv=["wiki-promotion-candidates"], verbosity=2)
PY
