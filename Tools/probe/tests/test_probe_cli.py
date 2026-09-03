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
# Writes the transcript the real CLI would have written, so `snapshot`'s file-copy half of
# §4.5 has something to copy. The stand-in writes none.
TRANSCRIPT_SCENARIO_SRC = '''
import json
import os
import fixture
import probe

META = {"name": "cli-transcript", "purpose": "cli test: a transcript for snapshot to copy",
        "serves": ["test"], "census": True, "deterministic": True, "isolation": "config-home",
        "launch": {"binary_args": [%(stand_in)r], "max_turns": 2},
        "prompts": ["hello"], "resume_of": None, "setup": None, "spikes": []}

def run(session, ctx):
    # This scenario writes a transcript, which is the one thing X9 forbids inside a real or
    # scratch config home. The guard lives here, with the capability, rather than resting on
    # every future caller handing it a throwaway directory -- and it runs before anything
    # else, so being wrong costs nothing.
    home = probe.forbidden_config_home(ctx["config_home"])
    if home is not None:
        raise RuntimeError("cli_transcript writes a transcript and must not be aimed at the config home " + home)
    session.send_user("hello")
    session.wait_result(20)
    sid = session.system_init["session_id"]
    d = os.path.join(ctx["config_home"], "projects", fixture.slug_of(ctx["cwd"]))
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, sid + ".jsonl"), "w") as fh:
        fh.write(json.dumps({"type": "user", "sessionId": sid, "cwd": ctx["cwd"],
                             "account": {"email": "leak@example.com"}, "apiKey": "s3cret",
                             "message": {"role": "user", "content": "my key is sk-ant-api03-LEAKLEAK"}}) + "\\n")
'''
RESUME_SCENARIO_SRC = '''
import json
import os

META = {"name": "cli-resume", "purpose": "cli test: a scenario that resumes another fixture",
        "serves": ["test"], "census": True, "deterministic": True, "isolation": "config-home",
        "launch": {"binary_args": [%(stand_in)r], "max_turns": 2},
        "prompts": ["hello"], "resume_of": "cli-demo", "setup": None, "spikes": []}

def run(session, ctx):
    with open(os.path.join(ctx["cwd"], "argv.json"), "w") as fh:
        json.dump(ctx["launch"].argv(), fh)
    session.send_user("hello")
    session.wait_result(20)
'''
MERGE_SCENARIO_SRC = '''
META = {"name": "cli-merge", "purpose": "cli test: a census accumulated across re-recordings",
        "serves": ["test"], "census": True, "deterministic": False, "isolation": "config-home",
        "launch": {"binary_args": [%(stand_in)r], "max_turns": 2},
        "prompts": ["hello"], "resume_of": None, "setup": None, "spikes": []}

def run(session, ctx):
    session.send_user("hello")
    session.wait_result(20)
'''
SPILL_SCENARIO_SRC = '''
META = {"name": "cli-spill", "purpose": "cli test: the spill threshold a scenario declares",
        "serves": ["test"], "census": True, "deterministic": True, "isolation": "config-home",
        "spill_after": 3, "launch": {"binary_args": [%(stand_in)r], "max_turns": 2},
        "prompts": ["hello"], "resume_of": None, "setup": None, "spikes": []}

def run(session, ctx):
    session.send_user("hello")
    session.wait_result(20)
    ctx["notes"].append("spill_after=" + str(session.spill_after))
'''
NO_VERSION_SCENARIO_SRC = '''
META = {"name": "cli-noversion", "purpose": "cli test: a binary that prints no version",
        "serves": ["test"], "census": True, "deterministic": True, "isolation": "config-home",
        "launch": {"binary_args": ["-c", "pass"], "max_turns": 2},
        "prompts": [], "resume_of": None, "setup": None, "spikes": []}

def run(session, ctx):
    raise AssertionError("the version check must refuse before the session is launched")
'''
# Answers the handshake, emits one line that will not decode, then a result. The harness turns
# the bad line into the `__unparseable__` frame the census fingerprints.
GARBAGE_STAND_IN_SRC = '''#!/usr/bin/env python3
import json
import sys
import uuid


def emit(frame):
    sys.stdout.write(json.dumps(frame) + "\\n")
    sys.stdout.flush()


def main():
    if "--version" in sys.argv:
        print("2.1.259 (Claude Code)"); return 0
    if "--help" in sys.argv:
        print("Options:\\n  -p, --print  x\\n"); return 0
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        message = json.loads(line)
        if message.get("type") != "control_request":
            continue
        subtype = (message.get("request") or {}).get("subtype")
        emit({"type": "control_response",
              "response": {"subtype": "success", "request_id": message["request_id"], "response": {}}})
        if subtype == "initialize":
            sys.stdout.write("{ this line will not decode\\n")
            sys.stdout.flush()
            emit({"type": "result", "subtype": "success", "result": "done", "num_turns": 1,
                  "uuid": str(uuid.uuid4())})
        if subtype == "end_session":
            return 0
    return 0


sys.exit(main())
'''
GARBAGE_SCENARIO_SRC = '''
META = {"name": "cli-garbage", "purpose": "cli test: a binary emitting an undecodable line",
        "serves": ["test"], "census": True, "deterministic": True, "isolation": "config-home",
        "launch": {"binary_args": [%(stand_in)r], "max_turns": 2},
        "prompts": [], "resume_of": None, "setup": None, "spikes": []}

def run(session, ctx):
    session.wait_result(20)
'''


def read_bytes(path):
    with open(path, "rb") as fh:
        return fh.read()


def read_json(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def write_json(path, obj):
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(obj, fh, indent=1, sort_keys=True)


class RecordAndDiffTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="afleet-cli-")
        self.scenarios = os.path.join(self.tmp, "scenarios"); os.makedirs(self.scenarios)
        self.fixtures = os.path.join(self.tmp, "Fixtures")
        self.config_home = os.path.join(self.tmp, "config-home"); os.makedirs(self.config_home)
        # `cli_transcript` is deliberately not here: its source quotes the planted strings, and
        # the no-unredacted-byte walk covers this whole tree. It is written by the one test
        # that needs it.
        for name, src in (("cli_demo", SCENARIO_SRC % {"name": "cli-demo", "stand_in": STAND_IN}),
                          ("cli_cancel", CANCEL_SCENARIO_SRC % {"stand_in": STAND_IN}),
                          ("cli_resume", RESUME_SCENARIO_SRC % {"stand_in": STAND_IN}),
                          ("cli_merge", MERGE_SCENARIO_SRC % {"stand_in": STAND_IN}),
                          ("cli_spill", SPILL_SCENARIO_SRC % {"stand_in": STAND_IN}),
                          ("cli_noversion", NO_VERSION_SCENARIO_SRC)):
            with open(os.path.join(self.scenarios, name + ".py"), "w") as fh:
                fh.write(src)
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

    def record(self, name, **kw):
        kw.setdefault("claude", sys.executable)
        kw.setdefault("scenario_dir", self.scenarios)
        kw.setdefault("fixtures_root", self.fixtures)
        kw.setdefault("config_home", self.config_home)
        kw.setdefault("scratch_root", self.tmp)
        return probe.record(name, **kw)

    def run_diff(self, **kw):
        kw.setdefault("claude", sys.executable)
        kw.setdefault("scenario_dir", self.scenarios)
        kw.setdefault("fixtures_root", self.fixtures)
        kw.setdefault("config_home", self.config_home)
        kw.setdefault("scratch_root", self.tmp)
        return probe.diff(**kw)

    def test_record_no_unredacted_byte_reaches_disk_and_review_is_unsigned(self):
        path, errors = self.record("cli_demo")
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

    def test_record_redacts_the_transcript_it_copies_out_of_the_config_home(self):
        # The other half of §4.5: the rules run in memory on every frame *and* on every file
        # `snapshot` copies, and the file half is where a live recording carries the prompts,
        # the tool results and the account block.
        with open(os.path.join(self.scenarios, "cli_transcript.py"), "w") as fh:
            fh.write(TRANSCRIPT_SCENARIO_SRC % {"stand_in": STAND_IN})
        path, errors = self.record("cli_transcript")
        self.assertEqual([e for e in errors if e != probe.UNSIGNED_REVIEW], [])
        copied = [os.path.join(r, f) for r, _, fs in os.walk(os.path.join(path, "transcript")) for f in fs]
        self.assertEqual(len(copied), 1, copied)             # snapshot found the transcript
        for planted in (b"sk-ant-api03", b"leak@example.com", b"s3cret"):
            self.assertNotIn(planted, read_bytes(copied[0]), copied[0])
        # Copy, never move: the CLI's own file under the config home is left exactly as it was.
        source = glob.glob(os.path.join(self.config_home, "projects", "*", "*.jsonl"))
        self.assertEqual(len(source), 1)
        self.assertIn(b"sk-ant-api03", read_bytes(source[0]))

    def test_record_writes_the_required_core_and_declares_only_the_host_cancel(self):
        os.environ["STAND_IN_FEATURES"] = "leak,permission,envvars,dialog"
        path, errors = self.record("cli_cancel")
        # Exactly the unsigned-review error and nothing else, which is also what pins
        # `probe.UNSIGNED_REVIEW` to the string `verify` actually emits.
        self.assertEqual(errors, [probe.UNSIGNED_REVIEW])
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

    def test_record_passes_a_declared_spill_threshold_through_to_the_harness(self):
        path, _ = self.record("cli_spill")
        meta = read_json(os.path.join(path, "fixture.json"))
        self.assertIn("spill_after=3", meta["notes"])
        probe.sign(path, reviewer="tester")
        # And the capture survives the spill round trip: the fixture still verifies.
        self.assertEqual(probe.verify_paths([path])[0], 0, probe.verify_paths([path])[1])

    def test_record_refuses_a_binary_that_prints_no_version(self):
        with self.assertRaises(RuntimeError) as caught:
            self.record("cli_noversion")
        self.assertIn("cli_version", str(caught.exception))
        self.assertFalse(os.path.isdir(os.path.join(self.fixtures, "cli-noversion")))

    def test_out_writes_the_fixture_under_the_directory_it_names(self):
        elsewhere = os.path.join(self.tmp, "elsewhere", "renamed")
        path, _ = self.record("cli_demo", out=elsewhere)
        self.assertEqual(path, elsewhere)
        self.assertEqual(read_json(os.path.join(path, "fixture.json"))["name"], "renamed")
        self.assertFalse(os.path.isdir(os.path.join(self.fixtures, "cli-demo")))

    def test_a_re_recording_accumulates_the_census_of_the_run_before_it(self):
        os.environ["STAND_IN_FEATURES"] = "leak,permission,hook"
        path, _ = self.record("cli_merge")
        first = read_json(os.path.join(path, "census.json"))
        self.assertIn("control_request/hook_callback", first["pairs"])
        os.environ["STAND_IN_FEATURES"] = "leak,permission"      # this run sees no hook at all
        path, _ = self.record("cli_merge")
        merged = read_json(os.path.join(path, "census.json"))
        self.assertIn("control_request/hook_callback", merged["pairs"])          # pair names union
        self.assertIn("response", merged["pairs"]["system/stand_in_saw"]["keys"])  # key sets union
        self.assertEqual(merged["pairs"]["system/init"]["count"],
                         first["pairs"]["system/init"]["count"] + 1)             # counts summed

    def test_redact_over_a_committed_fixture_changes_nothing(self):
        path, _ = self.record("cli_demo")
        probe.sign(path, reviewer="tester")
        meta_before = read_json(os.path.join(path, "fixture.json"))
        frames_before = read_bytes(os.path.join(path, "frames.ndjson"))
        streams_before = read_json(os.path.join(path, "streams.json"))
        probe._redact_in_place(path)         # §4.2: in place, idempotently
        self.assertEqual(read_json(os.path.join(path, "fixture.json")), meta_before)
        self.assertEqual(read_bytes(os.path.join(path, "frames.ndjson")), frames_before)
        self.assertEqual(read_json(os.path.join(path, "streams.json")), streams_before)
        self.assertEqual(probe.verify_paths([path])[0], 0, probe.verify_paths([path])[1])

    def test_redact_recomputes_the_stream_offsets_its_own_rules_invalidated(self):
        # `streams.json` holds the byte sizes of the files under `initial/`, so a rule that
        # shortens one leaves every offset in it pointing at the wrong place.
        path, _ = self.record("cli_demo")
        probe.sign(path, reviewer="tester")
        planted = os.path.join(path, "initial", "_slug_", "x.jsonl")
        os.makedirs(os.path.dirname(planted))
        with open(planted, "w") as fh:
            fh.write(json.dumps({"type": "user", "note": "reach me at someone@example.invalid"}) + "\n")
        before = os.path.getsize(planted)
        write_json(os.path.join(path, "streams.json"), {"_slug_/x.jsonl": before})
        probe._redact_in_place(path)
        after = os.path.getsize(planted)
        self.assertNotEqual(after, before)      # the address became a shorter placeholder
        self.assertEqual(read_json(os.path.join(path, "streams.json")), {"_slug_/x.jsonl": after})
        self.assertEqual(probe.verify_paths([path])[0], 0, probe.verify_paths([path])[1])

    def test_sign_then_verify_and_diff_against_the_same_binary_is_clean(self):
        path, _ = self.record("cli_demo")
        probe.sign(path, reviewer="tester")
        self.assertEqual(probe.verify_paths([path])[0], 0)
        code, report = self.run_diff()
        self.assertEqual(code, 0, report)
        os.environ["STAND_IN_FEATURES"] = "leak,permission,envvars,hook"      # a new (type, subtype) pair appears
        code, report = self.run_diff()
        self.assertEqual(code, 1); self.assertIn("added pair", report)

    def test_diff_resumes_a_resuming_scenario_from_the_fixture_it_names(self):
        demo, _ = self.record("cli_demo")
        prior_sid = read_json(os.path.join(demo, "fixture.json"))["session_id"]
        # `diff` reads only fixture.json and census.json off a fixture, so the resuming one is
        # the demo recording under another name. Recording it for real would need the CLI's own
        # transcript to resume from, which the stand-in does not write.
        resuming = os.path.join(self.fixtures, "cli-resume")
        shutil.copytree(demo, resuming)
        meta = read_json(os.path.join(resuming, "fixture.json"))
        meta["name"] = "cli-resume"; meta["scenario"] = "cli_resume"
        write_json(os.path.join(resuming, "fixture.json"), meta)
        code, report = self.run_diff(only="cli-resume")
        self.assertEqual(code, 0, report)
        argv = read_json(os.path.join(self.tmp, "cli-demo", "argv.json"))
        self.assertIn("--resume", argv)
        self.assertEqual(argv[argv.index("--resume") + 1], prior_sid)

    def test_diff_alarms_on_an_undecodable_line_in_the_run_it_observes(self):
        garbage = os.path.join(self.tmp, "garbage_stand_in.py")
        with open(garbage, "w") as fh:
            fh.write(GARBAGE_STAND_IN_SRC)
        with open(os.path.join(self.scenarios, "cli_garbage.py"), "w") as fh:
            fh.write(GARBAGE_SCENARIO_SRC % {"stand_in": garbage})
        path, _ = self.record("cli_garbage")
        # The pair is in the baseline, so nothing about it is added or removed -- and the gate
        # must still shout, because this is the live-binary comparison.
        self.assertIn(census.UNPARSEABLE_PAIR, read_json(os.path.join(path, "census.json"))["pairs"])
        code, report = self.run_diff(only="cli-garbage")
        self.assertEqual(code, 1, report)
        self.assertIn("undecodable stdout line", report)
        self.assertNotIn("removed pair", report)

    def test_a_fixture_that_cannot_be_re_run_does_not_take_the_rest_of_the_report_with_it(self):
        self.record("cli_demo")
        broken = os.path.join(self.fixtures, "broken"); os.makedirs(broken)
        write_json(os.path.join(broken, "fixture.json"),
                   {"name": "broken", "scenario": "no_such_scenario", "census": True, "deterministic": True})
        code, report = self.run_diff()
        self.assertEqual(code, 1, report)
        self.assertIn("broken: FAILED to run", report)
        self.assertIn("cli-demo: ok", report)      # the fixture after it still gets a verdict

    def test_diff_that_compares_nothing_is_a_failure_and_names_every_directory_it_passed_over(self):
        path, _ = self.record("cli_demo")
        meta = read_json(os.path.join(path, "fixture.json"))
        meta["census"] = False
        write_json(os.path.join(path, "fixture.json"), meta)
        code, report = self.run_diff()
        self.assertEqual(code, 1, report)
        self.assertIn("cli-demo: skipped (census: false)", report)
        self.assertIn("proves nothing", report)

    def test_a_synthetic_fixture_with_no_scenario_module_is_skipped_rather_than_failed(self):
        """A synthetic fixture is written from schemas and has no scenario to re-run, so the
        skip has to be decided from `fixture.json` alone. Deciding it after loading the
        scenario made the two hand-written dialog fixtures report `FAILED to run` on a tree
        where nothing was wrong -- and a failure the ritual invents is worse than one it
        misses, because the next reader stops trusting the report."""
        self.record("cli_demo")
        d = os.path.join(self.fixtures, "dialog-demo"); os.makedirs(d)
        write_json(os.path.join(d, "fixture.json"),
                   {"name": "dialog-demo", "scenario": None, "census": False, "synthetic": True, "deterministic": True})
        code, report = self.run_diff()
        self.assertEqual(code, 0, report)
        self.assertIn("dialog-demo: skipped (synthetic)", report)
        self.assertIn("cli-demo: ok", report)

    def test_diff_over_an_empty_fixtures_root_is_a_failure(self):
        os.makedirs(self.fixtures)
        code, report = self.run_diff()
        self.assertEqual(code, 1)
        self.assertIn("proves nothing", report)

    def test_verify_paths_passes_a_recording_hostname_through_to_the_scanner(self):
        path, _ = self.record("cli_demo")
        probe.sign(path, reviewer="tester")
        self.assertEqual(probe.verify_paths([path])[0], 0)
        # A review on another machine has to name the recording host or rule 3's hostname
        # half cannot fire at all. `cli-demo` stands in for one: it is in the fixture.
        failed, report = probe.verify_paths([path], hostname="cli-demo")
        self.assertEqual(failed, 1)
        self.assertIn("hostname", report)

    def test_fresh_scratch_refuses_a_scenario_name_that_resolves_onto_a_config_home(self):
        # The scratch config home and every scenario's scratch cwd are siblings under one
        # root, and this function's first act is an `rmtree`.
        with self.assertRaises(ValueError):
            probe.fresh_scratch("config-home", self.tmp, self.config_home)
        with self.assertRaises(ValueError):
            probe.fresh_scratch("", self.tmp, self.config_home)      # the root *contains* one
        with self.assertRaises(ValueError):
            probe.fresh_scratch("config-home", probe.SCRATCH_ROOT)   # §4.6's, without being told
        self.assertTrue(os.path.isdir(self.config_home))

    def test_fresh_scratch_refuses_a_scratch_root_that_resolves_inside_a_config_home(self):
        # Containment is the dangerous relation and it runs both ways. An `rmtree` on a path
        # *inside* a logged-in config home is the failure X9 exists to prevent, and refusing
        # only the equal and the containing cases leaves it wide open.
        inside = os.path.join(self.config_home, "projects")
        os.makedirs(inside)
        with self.assertRaises(ValueError):
            probe.fresh_scratch("scratch", inside, self.config_home)
        self.assertTrue(os.path.isdir(inside))
        # And through a symlink, which is how a path that does not look like a config home
        # turns out to be one -- so the comparison resolves first.
        link = os.path.join(self.tmp, "link-to-home")
        os.symlink(self.config_home, link)
        with self.assertRaises(ValueError):
            probe.fresh_scratch("scratch", link, self.config_home)
        self.assertTrue(os.path.isdir(self.config_home))

    def test_the_transcript_scenario_refuses_to_write_into_a_real_config_home(self):
        # It writes a transcript, so the guard belongs with the capability rather than with
        # every future caller. The next person to reach for it will be recording, not testing.
        with open(os.path.join(self.scenarios, "cli_transcript.py"), "w") as fh:
            fh.write(TRANSCRIPT_SCENARIO_SRC % {"stand_in": STAND_IN})
        mod = probe.load_scenario("cli_transcript", self.scenarios)
        # `session=None`: the refusal has to land before anything touches the session at all.
        with self.assertRaises(RuntimeError) as caught:
            mod.run(None, {"config_home": probe.harness.SCRATCH_CONFIG_HOME, "cwd": self.tmp})
        self.assertIn(os.path.realpath(probe.harness.SCRATCH_CONFIG_HOME), str(caught.exception))
        self.assertIsNone(probe.forbidden_config_home(self.config_home))   # the test's own is fine

    def test_main_usage_and_exit_codes(self):
        out = subprocess.run([sys.executable, os.path.join(probe.HERE, "probe.py")], capture_output=True, text=True)
        self.assertEqual(out.returncode, 2)


class ErrorClassificationTests(unittest.TestCase):
    def test_a_scanner_hit_on_a_path_containing_the_word_review_is_not_advisory(self):
        # `verify` formats a scanner hit as a fixture-relative path followed by the hit, so a
        # substring test would print an unredacted byte as advice and exit 0.
        hit = "transcript/_slug_/code-review-notes.jsonl: email in key"
        blocking, advisory = probe.classify_errors([probe.UNSIGNED_REVIEW, hit])
        self.assertEqual(blocking, [hit])
        self.assertEqual(advisory, [probe.UNSIGNED_REVIEW])

    def test_an_unsigned_fresh_recording_blocks_nothing(self):
        self.assertEqual(probe.classify_errors([probe.UNSIGNED_REVIEW]), ([], [probe.UNSIGNED_REVIEW]))


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
