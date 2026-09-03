import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import _paths  # noqa: F401
import census
import probe
import verify

STAND_IN = os.path.join(os.path.dirname(__file__), "stand_in.py")
SCENARIO_SRC = '''
import os
META = {"name": "%(name)s", "purpose": "cli test", "serves": ["test"], "census": True, "deterministic": True,
        "isolation": "config-home", "launch": {"binary_args": [%(stand_in)r], "max_turns": 2},
        "prompts": ["hello"], "resume_of": None, "setup": None, "spikes": []}

def run(session, ctx):
    session.send_user("hello")
    session.wait_result(20)
    ctx["notes"].append("ran")
'''
# A host request the scenario withdraws by hand. The stand-in's responder answers it either
# way, so the withdrawal is visible only where `record` reads it from: the session's own
# cancel record. The `dialog` feature adds the other cancel -- the CLI withdrawing one of
# its own requests -- which must never reach `withdrawn_requests`.
CANCEL_SCENARIO_SRC = '''
META = {"name": "cli-cancel", "purpose": "cli test: a host request the scenario withdraws",
        "serves": ["test"], "census": True, "deterministic": True, "isolation": "config-home",
        "launch": {"binary_args": [%(stand_in)r], "max_turns": 2},
        "prompts": ["hello"], "resume_of": None, "setup": None, "spikes": []}

def run(session, ctx):
    rid = session.request_async("get_context_usage")
    session.cancel(rid)
    session.wait_response(rid, 20)
    session.send_user("hello")
    session.wait_result(20)
    ctx["notes"].append("withdrew " + rid)
'''


def read_bytes(path):
    with open(path, "rb") as fh:
        return fh.read()


def read_json(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


class RecordAndDiffTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="afleet-cli-")
        self.scenarios = os.path.join(self.tmp, "scenarios"); os.makedirs(self.scenarios)
        self.fixtures = os.path.join(self.tmp, "Fixtures")
        self.config_home = os.path.join(self.tmp, "config-home"); os.makedirs(self.config_home)
        with open(os.path.join(self.scenarios, "cli_demo.py"), "w") as fh:
            fh.write(SCENARIO_SRC % {"name": "cli-demo", "stand_in": STAND_IN})
        with open(os.path.join(self.scenarios, "cli_cancel.py"), "w") as fh:
            fh.write(CANCEL_SCENARIO_SRC % {"stand_in": STAND_IN})
        self.features = os.environ.get("STAND_IN_FEATURES")
        os.environ["STAND_IN_FEATURES"] = "leak,permission,envvars"

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)
        # The variable steers every stand-in launched from this process, so leaving it set
        # would make a later test's stream depend on which test ran before it.
        if self.features is None:
            os.environ.pop("STAND_IN_FEATURES", None)
        else:
            os.environ["STAND_IN_FEATURES"] = self.features

    def test_record_no_unredacted_byte_reaches_disk_and_review_is_unsigned(self):
        path, errors = probe.record("cli_demo", claude=sys.executable, scenario_dir=self.scenarios,
                                    fixtures_root=self.fixtures, config_home=self.config_home, scratch_root=self.tmp)
        self.assertEqual(path, os.path.join(self.fixtures, "cli-demo"))
        self.assertEqual([e for e in errors if "review" not in e], [])
        self.assertTrue(any("review" in e for e in errors))
        for root, _, files in os.walk(self.tmp):           # fixture, scratch cwd, scratch config home, everything
            for f in files:
                blob = read_bytes(os.path.join(root, f))
                self.assertNotIn(b"sk-ant-api03", blob, os.path.join(root, f))
                self.assertNotIn(b"leak@example.com", blob, os.path.join(root, f))
                self.assertNotIn(b"s3cret", blob, os.path.join(root, f))
        self.assertFalse(os.path.isdir(os.path.join(path, "raw")))
        self.assertFalse(any(n.startswith(".tmp-") for n in os.listdir(self.fixtures)))
        meta = read_json(os.path.join(path, "fixture.json"))
        self.assertEqual(meta["cli_version"], "2.1.259")
        self.assertEqual(sorted(meta["launch"]["env"]), sorted(probe.harness.DEFAULT_ENV_TABLE))
        self.assertIn("--permission-prompt-tool", meta["launch"]["argv"])
        self.assertEqual(meta["review"], {"reviewer": "", "date": "", "checklist_version": 1})

    def test_record_writes_the_required_core_and_declares_only_the_host_cancel(self):
        os.environ["STAND_IN_FEATURES"] = "leak,permission,envvars,dialog"
        path, errors = probe.record("cli_cancel", claude=sys.executable, scenario_dir=self.scenarios,
                                    fixtures_root=self.fixtures, config_home=self.config_home, scratch_root=self.tmp)
        self.assertEqual([e for e in errors if "review" not in e], [])
        meta = read_json(os.path.join(path, "fixture.json"))
        for key in verify.REQUIRED_META:
            self.assertIn(key, meta)
        for key in verify.BOOLEAN_META:
            self.assertIsInstance(meta[key], bool, key)
        cancels = {"in": [], "out": []}
        with open(os.path.join(path, "frames.ndjson"), encoding="utf-8") as fh:
            for line in fh:
                rec = json.loads(line)
                if (rec.get("frame") or {}).get("type") == "control_cancel_request":
                    cancels[rec["dir"]].append(rec["frame"]["request_id"])
        self.assertEqual(len(cancels["in"]), 1)            # the one the scenario withdrew
        self.assertEqual(len(cancels["out"]), 1)           # the CLI withdrawing its own dialog
        self.assertEqual(meta["withdrawn_requests"], cancels["in"])
        self.assertNotIn(cancels["out"][0], meta["withdrawn_requests"])
        probe.sign(path, reviewer="tester")
        self.assertEqual(probe.verify_paths([path])[0], 0, probe.verify_paths([path])[1])

    def test_sign_then_verify_and_diff_against_the_same_binary_is_clean(self):
        path, _ = probe.record("cli_demo", claude=sys.executable, scenario_dir=self.scenarios,
                               fixtures_root=self.fixtures, config_home=self.config_home, scratch_root=self.tmp)
        probe.sign(path, reviewer="tester")
        self.assertEqual(probe.verify_paths([path])[0], 0)
        code, report = probe.diff(claude=sys.executable, scenario_dir=self.scenarios, fixtures_root=self.fixtures,
                                  config_home=self.config_home, scratch_root=self.tmp)
        self.assertEqual(code, 0, report)
        os.environ["STAND_IN_FEATURES"] = "leak,permission,envvars,hook"      # a new (type, subtype) pair appears
        code, report = probe.diff(claude=sys.executable, scenario_dir=self.scenarios, fixtures_root=self.fixtures,
                                  config_home=self.config_home, scratch_root=self.tmp)
        self.assertEqual(code, 1); self.assertIn("added pair", report)

    def test_a_fixture_that_cannot_be_re_run_does_not_take_the_rest_of_the_report_with_it(self):
        probe.record("cli_demo", claude=sys.executable, scenario_dir=self.scenarios,
                     fixtures_root=self.fixtures, config_home=self.config_home, scratch_root=self.tmp)
        broken = os.path.join(self.fixtures, "broken"); os.makedirs(broken)
        with open(os.path.join(broken, "fixture.json"), "w") as fh:
            json.dump({"name": "broken", "scenario": "no_such_scenario", "census": True, "deterministic": True}, fh)
        code, report = probe.diff(claude=sys.executable, scenario_dir=self.scenarios, fixtures_root=self.fixtures,
                                  config_home=self.config_home, scratch_root=self.tmp)
        self.assertEqual(code, 1, report)
        self.assertIn("broken: FAILED to run", report)
        self.assertIn("cli-demo: ok", report)      # the fixture after it still gets a verdict

    def test_verify_paths_passes_a_recording_hostname_through_to_the_scanner(self):
        path, _ = probe.record("cli_demo", claude=sys.executable, scenario_dir=self.scenarios,
                               fixtures_root=self.fixtures, config_home=self.config_home, scratch_root=self.tmp)
        probe.sign(path, reviewer="tester")
        self.assertEqual(probe.verify_paths([path])[0], 0)
        # A review on another machine has to name the recording host or rule 3's hostname
        # half cannot fire at all. `cli-demo` stands in for one: it is in the fixture.
        failed, report = probe.verify_paths([path], hostname="cli-demo")
        self.assertEqual(failed, 1)
        self.assertIn("hostname", report)

    def test_redact_over_a_committed_fixture_changes_nothing(self):
        path, _ = probe.record("cli_demo", claude=sys.executable, scenario_dir=self.scenarios,
                               fixtures_root=self.fixtures, config_home=self.config_home, scratch_root=self.tmp)
        probe.sign(path, reviewer="tester")
        meta_before = read_json(os.path.join(path, "fixture.json"))
        frames_before = read_bytes(os.path.join(path, "frames.ndjson"))
        probe._redact_in_place(path)         # §4.2: in place, idempotently
        self.assertEqual(read_json(os.path.join(path, "fixture.json")), meta_before)
        self.assertEqual(read_bytes(os.path.join(path, "frames.ndjson")), frames_before)
        self.assertEqual(probe.verify_paths([path])[0], 0, probe.verify_paths([path])[1])

    def test_main_usage_and_exit_codes(self):
        out = subprocess.run([sys.executable, os.path.join(probe.HERE, "probe.py")], capture_output=True, text=True)
        self.assertEqual(out.returncode, 2)


class BinaryArgvTests(unittest.TestCase):
    def setUp(self):
        self.previous = os.environ.pop("AFLEET_CLAUDE_BINARY", None)

    def tearDown(self):
        # Popped, not just overwritten: the variable outranks every `--claude` argument, so
        # leaving one behind sends every later recording at the wrong binary.
        os.environ.pop("AFLEET_CLAUDE_BINARY", None)
        if self.previous is not None:
            os.environ["AFLEET_CLAUDE_BINARY"] = self.previous

    def test_a_binary_naming_a_path_is_absolutised_and_a_bare_name_is_left_for_path_lookup(self):
        # Popen resolves a relative program against the *child's* cwd, and every scenario
        # runs in a fresh scratch directory, so `make probe CLAUDE=Tools/fake-claude/fake-claude`
        # would exec nothing at all.
        self.assertEqual(probe.binary_argv("Tools/fake-claude/fake-claude"),
                         [os.path.join(os.getcwd(), "Tools", "fake-claude", "fake-claude")])
        self.assertEqual(probe.binary_argv("claude"), ["claude"])
        self.assertEqual(probe.binary_argv(None), ["claude"])
        self.assertEqual(probe.binary_argv("/usr/local/bin/claude"), ["/usr/local/bin/claude"])

    def test_the_environment_override_wins_and_is_absolutised_the_same_way(self):
        os.environ["AFLEET_CLAUDE_BINARY"] = "Tools/fake-claude/fake-claude"
        self.assertEqual(probe.binary_argv("claude"),
                         [os.path.join(os.getcwd(), "Tools", "fake-claude", "fake-claude")])


class VerifyPathsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="afleet-verify-paths-")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def test_an_unexpanded_glob_is_not_a_failing_fixture(self):
        # `make verify-fixtures` passes `Fixtures/*/`, which the shell leaves untouched when
        # no fixture directory exists yet.
        pattern = os.path.join(self.tmp, "*/")
        self.assertEqual(glob.glob(pattern), [])
        failed, report = probe.verify_paths([pattern])
        self.assertEqual(failed, 0)
        self.assertEqual(report, "")

    def test_a_named_fixture_that_is_not_there_still_fails(self):
        failed, report = probe.verify_paths([os.path.join(self.tmp, "no-such-fixture")])
        self.assertEqual(failed, 1)
        self.assertIn("missing fixture.json", report)


class DriftReportTests(unittest.TestCase):
    def test_correlated_lines_about_one_pair_become_one_block(self):
        # One error response shows up as a removed required payload key, a removed required
        # body key and an added `error` payload key. Three correct lines, one cause.
        lines = ["added pair system/invented",
                 "control_response/get_settings: removed required payload keys response",
                 "control_response/get_settings: removed required body keys effective_keys",
                 "control_response/get_settings: added payload keys error",
                 "flags: removed --resume"]
        self.assertEqual(probe.group_drift(lines), [
            "added pair system/invented",
            "control_response/get_settings:",
            "  removed required payload keys response",
            "  removed required body keys effective_keys",
            "  added payload keys error",
            "flags: removed --resume",
        ])

    def test_a_pair_with_one_line_keeps_its_one_line(self):
        self.assertEqual(probe.group_drift(["user: removed keys origin"]), ["user: removed keys origin"])

    def test_nothing_is_dropped(self):
        lines = ["a: one", "b: two", "a: three", "removed pair c"]
        self.assertEqual(probe.group_drift(lines), ["a:", "  one", "  three", "b: two", "removed pair c"])


class CensusUnparseablePairTests(unittest.TestCase):
    """`harness` mints `{"type": "__unparseable__"}` for a stdout line that would not decode."""
    GOOD = {"type": "result", "subtype": "success"}
    BAD = {"type": "__unparseable__", "raw": "{not json"}

    def test_an_unparseable_pair_that_appears_alarms_in_both_modes(self):
        recorded = census.census([self.GOOD])
        observed = census.census([self.GOOD, self.BAD])
        for mode in ("exact", "required"):
            self.assertIn("added pair __unparseable__", census.diff(recorded, observed, mode), mode)

    def test_an_unparseable_pair_in_the_baseline_never_alarms_when_it_is_gone(self):
        # A baseline recorded on a run that hit one truncated line must not demand the pair
        # forever: the next healthy re-record would alarm, and an operator who learns to wave
        # the gate through has lost more than the pair.
        recorded = census.census([self.GOOD, self.BAD])
        observed = census.census([self.GOOD])
        for mode in ("exact", "required"):
            self.assertEqual(census.diff(recorded, observed, mode), [], mode)


class ResumeResolutionTests(unittest.TestCase):
    def test_resolve_resume_reads_the_prior_fixture_for_record_diff_and_spike(self):
        root = tempfile.mkdtemp(); os.makedirs(os.path.join(root, "prior"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        with open(os.path.join(root, "prior", "fixture.json"), "w") as fh:
            json.dump({"session_id": "prior-sid"}, fh)
        self.assertEqual(probe.resolve_resume({"resume_of": "prior"}, root), "prior-sid")
        self.assertIsNone(probe.resolve_resume({"resume_of": None}, root))


class ZeroCostScenarioTests(unittest.TestCase):
    def test_zero_cost_scenario_loads_and_declares_the_requests(self):
        m = probe.load_scenario("zero_cost")
        self.assertEqual(m.META["name"], "zero-cost"); self.assertTrue(m.META["deterministic"])
        self.assertEqual(m.REQUESTS[0], ("get_context_usage", {}))
        self.assertIn(("list_models", {}), m.REQUESTS)
        self.assertNotIn("submit_feedback", [r[0] for r in m.REQUESTS])


if __name__ == "__main__":
    unittest.main()
