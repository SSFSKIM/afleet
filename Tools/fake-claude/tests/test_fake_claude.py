import json
import os
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
import _paths  # noqa: F401
import fake_claude

EXE = os.path.join(_paths.TOOL_DIR, "fake-claude")
SID = "33333333-3333-4333-8333-333333333333"
REC_CWD = "/private/tmp/afleet-fixtures/tiny"


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        fh.write(text)


def tiny_fixture(root, name="tiny", mirror_root="~/.claude", init_id="init-1"):
    """Two turns: initialize, user -> system/init + assistant + mirror + result; host get_usage; user -> result; end_session.
    `mirror_root` is the config home the recording ran under and `init_id` the id it gave its
    initialize request; neither is a constant of the format, so both are variable here."""
    d = os.path.join(root, name)
    rec_slug = fake_claude.slug_of(REC_CWD)
    fp = "%s/projects/%s/%s.jsonl" % (mirror_root, rec_slug, SID)
    # `parentPath` below stands in for any record field naming a path inside the recorded config
    # home: emission and the final-state comparison have to rewrite it the same way or never agree.
    frames = [
        {"t": 0, "dir": "in", "frame": {"type": "control_request", "request_id": init_id, "request": {"subtype": "initialize"}}},
        {"t": 2, "dir": "out", "frame": {"type": "control_response", "response": {"subtype": "success", "request_id": init_id, "response": {"commands": [], "current_model": "haiku"}}}},
        {"t": 10, "dir": "in", "frame": {"type": "user", "uuid": "u1", "message": {"role": "user", "content": "one"}}},
        {"t": 20, "dir": "out", "frame": {"type": "system", "subtype": "init", "session_id": SID, "capabilities": [], "cwd": REC_CWD}},
        {"t": 30, "dir": "out", "frame": {"type": "assistant", "uuid": "a1", "message": {"role": "assistant", "content": [{"type": "text", "text": "one"}]}}},
        {"t": 35, "dir": "out", "frame": {"type": "transcript_mirror", "filePath": fp, "entries": [{"type": "user", "uuid": "u1", "cwd": REC_CWD, "parentPath": fp}, {"type": "assistant", "uuid": "a1"}]}},
        {"t": 40, "dir": "out", "frame": {"type": "control_request", "request_id": "c1", "request": {"subtype": "can_use_tool", "tool_name": "Write", "input": {}}}},
        {"t": 50, "dir": "in", "frame": {"type": "control_response", "response": {"subtype": "success", "request_id": "c1", "response": {"behavior": "allow"}}}},
        {"t": 55, "dir": "out", "frame": {"type": "system", "subtype": "task_notification", "output_file": "<artifacts>/%s/%s/tasks/t1.output" % (rec_slug, SID)}},
        {"t": 60, "dir": "out", "frame": {"type": "result", "subtype": "success", "result": "one"}},
        {"t": 70, "dir": "in", "frame": {"type": "control_request", "request_id": "h1", "request": {"subtype": "get_usage"}}},
        {"t": 75, "dir": "out", "frame": {"type": "control_response", "response": {"subtype": "success", "request_id": "h1", "response": {"session": {"total_cost_usd": 0}}}}},
        {"t": 80, "dir": "in", "frame": {"type": "user", "uuid": "u2", "message": {"role": "user", "content": "two"}}},
        {"t": 90, "dir": "out", "frame": {"type": "transcript_mirror", "filePath": fp, "entries": [{"type": "user", "uuid": "u2"}]}},
        {"t": 95, "dir": "out", "frame": {"type": "result", "subtype": "success", "result": "two"}},
        {"t": 100, "dir": "in", "frame": {"type": "control_request", "request_id": "end-1", "request": {"subtype": "end_session"}}},
        {"t": 101, "dir": "out", "frame": {"type": "control_response", "response": {"subtype": "success", "request_id": "end-1", "response": {}}}},
    ]
    meta = {"name": "tiny", "cli_version": "2.1.259", "session_id": SID, "cwd": REC_CWD, "deterministic": False, "synthetic": False,
            "hypothesis": False, "late_responses": [], "launch": {"argv": [], "env": {}},
            "review": {"reviewer": "t", "date": "2026-09-04", "checklist_version": 1}}
    write(os.path.join(d, "fixture.json"), json.dumps(meta))
    with open(os.path.join(d, "frames.ndjson"), "w") as fh:
        for f in frames:
            fh.write(json.dumps(f) + "\n")
    write(os.path.join(d, "census.json"), json.dumps({"version": "2.1.259", "flags": ["--print", "--session-mirror"], "capabilities": [], "pairs": {}}))
    write(os.path.join(d, "redaction.json"), json.dumps({"rules": {}}))
    write(os.path.join(d, "initial", "_slug_", SID + ".jsonl"), json.dumps({"type": "summary", "cwd": REC_CWD}) + "\n")
    init_size = os.path.getsize(os.path.join(d, "initial", "_slug_", SID + ".jsonl"))
    write(os.path.join(d, "streams.json"), json.dumps({"_slug_/%s.jsonl" % SID: init_size}))
    write(os.path.join(d, "transcript", "_slug_", SID + ".jsonl"),
          json.dumps({"type": "summary", "cwd": REC_CWD}) + "\n" + json.dumps({"type": "user", "uuid": "u1", "cwd": REC_CWD, "parentPath": fp}) + "\n" +
          json.dumps({"type": "assistant", "uuid": "a1"}) + "\n" + json.dumps({"type": "user", "uuid": "u2"}) + "\n")
    write(os.path.join(d, "artifacts", rec_slug, SID, "tasks", "t1.output"), "bg-done\n")   # artifacts keep the recorded slug, as collect_artifacts stores them
    return d


def scratch_home_fixture(root):
    """The same recording with none of the hand-written conveniences: the mirror path is rooted at
    the scratch CLAUDE_CONFIG_DIR every scenario records under, and the initialize request carries
    the id the recording gave it rather than the literal the brief's fixture used."""
    return tiny_fixture(root, name="scratch", mirror_root="/private/tmp/afleet-fixtures/config-home", init_id="req_7f3a")


def drive_two_turns(h):
    """Answer a tiny-fixture replay exactly as the recording expects, and return its mirror and
    task-notification frames."""
    h.send({"type": "control_request", "request_id": "i", "request": {"subtype": "initialize"}}); h.wait(lambda f: f.get("type") == "control_response")
    h.send({"type": "user", "uuid": "x", "message": {"role": "user", "content": "one"}})
    mirror = h.wait(lambda f: f.get("type") == "transcript_mirror")
    h.send({"type": "control_response", "response": {"subtype": "success", "request_id": "c1", "response": {"behavior": "allow"}}})
    notif = h.wait(lambda f: f.get("subtype") == "task_notification")   # recorded after the c1 answer, so replay cannot reach it before it
    h.wait(lambda f: f.get("type") == "result")
    h.send({"type": "control_request", "request_id": "zz", "request": {"subtype": "get_usage"}}); h.wait(lambda f: f.get("type") == "control_response" and f["response"]["request_id"] == "zz")
    h.send({"type": "user", "uuid": "y", "message": {"role": "user", "content": "two"}}); h.wait(lambda f: f.get("result") == "two")
    h.finish()
    return mirror, notif


class Host:
    """Launches fake-claude like the app would and talks stream-json to it."""
    live = []

    def __init__(self, fixture, cwd, env=None, argv_extra=()):
        env_all = dict(os.environ); env_all.update({"FAKE_CLAUDE_FIXTURE": fixture, "FAKE_CLAUDE_SPEED": "0"}); env_all.update(env or {})
        self.p = subprocess.Popen([EXE, "-p", "--output-format", "stream-json", "--session-id", SID] + list(argv_extra), cwd=cwd, env=env_all,
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        self.frames, self.cond = [], threading.Condition()
        self.reader = threading.Thread(target=self._read, daemon=True); self.reader.start()
        Host.live.append(self)

    @classmethod
    def close_all(cls):
        """Reap every host a test started, so no pipe is left for the collector to warn about."""
        while cls.live:
            cls.live.pop().close()

    def close(self):
        if self.p.poll() is None:
            self.p.kill()
        self.p.wait()
        self.reader.join(timeout=5)
        for pipe in (self.p.stdin, self.p.stdout, self.p.stderr):
            try:
                pipe.close()
            except (OSError, ValueError):
                pass

    def _read(self):
        for line in self.p.stdout:
            if line.strip():
                with self.cond:
                    self.frames.append(json.loads(line)); self.cond.notify_all()

    def send(self, frame):
        self.p.stdin.write(json.dumps(frame) + "\n"); self.p.stdin.flush()

    def wait(self, pred, timeout=5):
        deadline = time.time() + timeout
        with self.cond:
            while True:
                for f in self.frames:
                    if pred(f):
                        return f
                rem = deadline - time.time()
                if rem <= 0:
                    return None
                self.cond.wait(rem)

    def finish(self, timeout=5):
        try:
            self.p.stdin.close()
        except OSError:
            pass
        try:
            return self.p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.p.kill(); return None


class ToolTest(unittest.TestCase):
    """Reaps every host a test started, then removes every temp directory it made."""
    def tmp(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, ignore_errors=True)
        return d

    def tearDown(self):
        Host.close_all()


class VersionHelpTests(ToolTest):
    def setUp(self):
        self.root = self.tmp(); self.fx = tiny_fixture(self.root)

    def test_version_and_help_come_from_the_fixture(self):
        env = dict(os.environ, FAKE_CLAUDE_FIXTURE=self.fx)
        self.assertEqual(subprocess.run([EXE, "--version"], capture_output=True, text=True, env=env).stdout.strip(), "2.1.259 (Claude Code)")
        env["FAKE_CLAUDE_VERSION"] = "9.9.9"
        self.assertEqual(subprocess.run([EXE, "--version"], capture_output=True, text=True, env=env).stdout.strip(), "9.9.9 (Claude Code)")
        out = subprocess.run([EXE, "--help"], capture_output=True, text=True, env=env).stdout
        self.assertIn("--session-mirror", out); self.assertIn("--print", out)

    def test_help_survives_a_census_that_never_captured_the_flag_list(self):
        cen = os.path.join(self.fx, "census.json")
        with open(cen) as fh:
            recorded = json.load(fh)
        recorded["flags"] = None                 # census.py writes null for a run whose `claude --help` was never captured
        write(cen, json.dumps(recorded))
        r = subprocess.run([EXE, "--help"], capture_output=True, text=True, env=dict(os.environ, FAKE_CLAUDE_FIXTURE=self.fx))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("Usage:", r.stdout)


class ReplayTests(ToolTest):
    def setUp(self):
        self.root = self.tmp(); self.fx = tiny_fixture(self.root); self.cwd = self.tmp()

    def test_reactive_order_blocking_and_request_id_substitution(self):
        h = Host(self.fx, self.cwd)
        h.send({"type": "control_request", "request_id": "my-init", "request": {"subtype": "initialize"}})
        r = h.wait(lambda f: f.get("type") == "control_response"); self.assertEqual(r["response"]["request_id"], "my-init")
        time.sleep(0.3); self.assertFalse(any(f.get("type") == "assistant" for f in h.frames))     # blocks on the user line
        h.send({"type": "user", "uuid": "x", "message": {"role": "user", "content": "anything"}})
        req = h.wait(lambda f: f.get("type") == "control_request"); self.assertEqual(req["request_id"], "c1")
        h.send({"type": "control_response", "response": {"subtype": "success", "request_id": "c1", "response": {"behavior": "allow"}}})
        self.assertIsNotNone(h.wait(lambda f: f.get("type") == "result"))
        h.send({"type": "control_request", "request_id": "zz", "request": {"subtype": "get_usage"}})
        r2 = h.wait(lambda f: f.get("type") == "control_response" and f["response"]["request_id"] == "zz")
        self.assertEqual(r2["response"]["response"]["session"]["total_cost_usd"], 0)
        h.send({"type": "user", "uuid": "y", "message": {"role": "user", "content": "two"}})
        self.assertIsNotNone(h.wait(lambda f: f.get("type") == "result" and f.get("result") == "two"))
        h.send({"type": "control_request", "request_id": "e", "request": {"subtype": "end_session"}})
        self.assertIsNotNone(h.wait(lambda f: f.get("type") == "control_response" and f["response"]["request_id"] == "e"))
        self.assertEqual(h.finish(), 0)

    def test_leading_and_trailing_expects_fail_when_the_host_stays_silent(self):
        lead = os.path.join(self.root, "lead.json"); write(lead, json.dumps([{"expect": {"type": "control_request", "request.subtype": "get_usage"}, "timeout_ms": 500}]))
        h = Host(self.fx, self.cwd, env={"FAKE_CLAUDE_SCRIPT": lead})
        self.assertEqual(h.finish(timeout=5), 3)                                    # nothing sent: leading expect times out
        trail = os.path.join(self.root, "trail.json"); write(trail, json.dumps([{"after": 999, "emit": {"type": "system", "subtype": "late"}}, {"expect": {"type": "user"}, "timeout_ms": 500}]))
        h = Host(self.fx, self.cwd, env={"FAKE_CLAUDE_SCRIPT": trail})
        h.send({"type": "control_request", "request_id": "i", "request": {"subtype": "initialize"}}); h.wait(lambda f: f.get("type") == "control_response")
        h.send({"type": "user", "uuid": "x", "message": {"role": "user", "content": "one"}})
        h.send({"type": "control_response", "response": {"subtype": "success", "request_id": "c1", "response": {"behavior": "allow"}}})
        h.send({"type": "control_request", "request_id": "zz", "request": {"subtype": "get_usage"}}); h.wait(lambda f: f.get("type") == "control_response" and f["response"]["request_id"] == "zz")
        h.send({"type": "user", "uuid": "y", "message": {"role": "user", "content": "two"}}); h.wait(lambda f: f.get("result") == "two")
        h.send({"type": "control_request", "request_id": "e", "request": {"subtype": "end_session"}})
        self.assertEqual(h.finish(timeout=5), 3)                                    # trailing emit fires at the end, then the expect times out

    def test_patch_step_removes_keys_from_matching_out_frames(self):
        script = os.path.join(self.root, "patch.json"); write(script, json.dumps([{"patch": {"type": "system", "subtype": "init"}, "remove": ["capabilities"]}]))
        h = Host(self.fx, self.cwd, env={"FAKE_CLAUDE_SCRIPT": script})
        h.send({"type": "control_request", "request_id": "i", "request": {"subtype": "initialize"}}); h.wait(lambda f: f.get("type") == "control_response")
        h.send({"type": "user", "uuid": "x", "message": {"role": "user", "content": "one"}})
        init = h.wait(lambda f: f.get("subtype") == "init"); self.assertNotIn("capabilities", init); h.finish()

    def test_unexpected_host_traffic_fails_with_exit_3_unless_a_rule_allows_it(self):
        h = Host(self.fx, self.cwd)
        h.send({"type": "control_request", "request_id": "i", "request": {"subtype": "initialize"}}); h.wait(lambda f: f.get("type") == "control_response")
        h.send({"type": "control_request", "request_id": "surprise", "request": {"subtype": "interrupt"}})
        self.assertEqual(h.finish(), 3)
        self.assertIn("unexpected", h.p.stderr.read())
        script = os.path.join(self.root, "rule.json"); write(script, json.dumps([{"rule": "generic-success", "subtypes": ["interrupt"]}]))
        h = Host(self.fx, self.cwd, env={"FAKE_CLAUDE_SCRIPT": script})
        h.send({"type": "control_request", "request_id": "i", "request": {"subtype": "initialize"}}); h.wait(lambda f: f.get("type") == "control_response")
        h.send({"type": "control_request", "request_id": "surprise", "request": {"subtype": "interrupt"}})
        r = h.wait(lambda f: f.get("type") == "control_response" and f["response"]["request_id"] == "surprise")
        self.assertEqual(r["response"]["subtype"], "success"); h.finish()

    def test_init_override_replaces_only_the_recorded_initialize_response(self):
        fx = scratch_home_fixture(self.root)              # its recorded initialize id is not the brief's "init-1"
        override = os.path.join(self.root, "init.json"); write(override, json.dumps({"commands": [{"name": "afleet"}], "current_model": "opus"}))
        h = Host(fx, self.cwd, env={"FAKE_CLAUDE_INIT": override})
        h.send({"type": "control_request", "request_id": "my-init", "request": {"subtype": "initialize"}})
        r = h.wait(lambda f: f.get("type") == "control_response")
        self.assertEqual(r["response"]["request_id"], "my-init")
        self.assertEqual(r["response"]["response"], {"commands": [{"name": "afleet"}], "current_model": "opus"})
        h.send({"type": "user", "uuid": "x", "message": {"role": "user", "content": "one"}})
        h.send({"type": "control_response", "response": {"subtype": "success", "request_id": "c1", "response": {"behavior": "allow"}}})
        h.send({"type": "control_request", "request_id": "zz", "request": {"subtype": "get_usage"}})
        r2 = h.wait(lambda f: f.get("type") == "control_response" and f["response"]["request_id"] == "zz")
        self.assertEqual(r2["response"]["response"], {"session": {"total_cost_usd": 0}})   # every other response is left alone
        h.finish()

    def test_a_user_frame_whose_text_differs_from_the_recording_is_logged_and_replay_continues(self):
        h = Host(self.fx, self.cwd)
        h.send({"type": "control_request", "request_id": "i", "request": {"subtype": "initialize"}}); h.wait(lambda f: f.get("type") == "control_response")
        h.send({"type": "user", "uuid": "x", "message": {"role": "user", "content": "a prompt the recording never saw"}})
        self.assertIsNotNone(h.wait(lambda f: f.get("type") == "assistant"))
        h.finish()
        err = h.p.stderr.read()
        self.assertIn("user text differs from the recording", err); self.assertIn("a prompt the recording never saw", err)

    def test_a_control_request_without_a_request_id_is_unexpected_traffic(self):
        h = Host(self.fx, self.cwd)
        h.send({"type": "control_request", "request": {"subtype": "initialize"}})
        self.assertEqual(h.finish(), 3)
        self.assertIn("unexpected", h.p.stderr.read())

    def test_script_emit_expect_answer(self):
        script = os.path.join(self.root, "s.json")
        write(script, json.dumps([
            {"after": 2, "emit": {"type": "afleet_invented", "x": 1}},
            {"after": 3, "emit": {"type": "control_request", "request_id": "inj-1", "request": {"subtype": "bogus_kind"}}},
            {"expect": {"type": "control_response", "request_id": "$last", "response.subtype": "error"}, "timeout_ms": 2000},
            {"answer": {"type": "system", "subtype": "stand_in_ack"}},
        ]))
        h = Host(self.fx, self.cwd, env={"FAKE_CLAUDE_SCRIPT": script})
        h.send({"type": "control_request", "request_id": "i", "request": {"subtype": "initialize"}}); h.wait(lambda f: f.get("type") == "control_response")
        h.send({"type": "user", "uuid": "x", "message": {"role": "user", "content": "one"}})
        self.assertIsNotNone(h.wait(lambda f: f.get("type") == "afleet_invented"))
        inj = h.wait(lambda f: f.get("type") == "control_request" and f["request_id"] == "inj-1"); self.assertIsNotNone(inj)
        h.send({"type": "control_response", "response": {"subtype": "error", "request_id": "inj-1", "error": "subtype bogus_kind not supported"}})
        self.assertIsNotNone(h.wait(lambda f: f.get("subtype") == "stand_in_ack"))
        # the recorded can_use_tool still follows and must be answered
        h.send({"type": "control_response", "response": {"subtype": "success", "request_id": "c1", "response": {"behavior": "allow"}}})
        self.assertIsNotNone(h.wait(lambda f: f.get("type") == "result")); h.finish()
        h2 = Host(self.fx, self.cwd, env={"FAKE_CLAUDE_SCRIPT": script})
        h2.send({"type": "control_request", "request_id": "i", "request": {"subtype": "initialize"}}); h2.wait(lambda f: f.get("type") == "control_response")
        h2.send({"type": "user", "uuid": "x", "message": {"role": "user", "content": "one"}})
        h2.wait(lambda f: f.get("type") == "control_request" and f["request_id"] == "inj-1")
        self.assertEqual(h2.finish(timeout=6), 3)                                   # expect timed out, host never answered


class MaterializeTests(ToolTest):
    def setUp(self):
        self.root = self.tmp(); self.fx = tiny_fixture(self.root)
        self.fake_real_home = os.path.join(self.root, "real-claude"); os.makedirs(self.fake_real_home)
        self.env = dict(os.environ, CLAUDE_CONFIG_DIR=self.fake_real_home)

    def run_materialize(self, dest, cwd="/private/tmp/afleet-fixtures/tiny", fixture=None):
        return subprocess.run([EXE, "materialize", fixture or self.fx, dest, "--cwd", cwd], capture_output=True, text=True, env=self.env)

    def test_refuses_the_real_home_a_symlink_into_it_and_unmarked_directories(self):
        self.assertEqual(self.run_materialize(self.fake_real_home).returncode, 2)
        link = os.path.join(self.root, "link"); os.symlink(self.fake_real_home, link)
        self.assertEqual(self.run_materialize(link).returncode, 2)
        unmarked = os.path.join(self.root, "unmarked"); os.makedirs(unmarked)
        self.assertEqual(self.run_materialize(unmarked).returncode, 2)
        self.assertEqual(os.listdir(unmarked), [])
        victim = os.path.join(self.fake_real_home, "victim"); write(victim, "")
        faked = os.path.join(self.root, "faked-marker"); os.makedirs(faked)
        os.symlink(victim, os.path.join(faked, fake_claude.MARKER))
        self.assertEqual(self.run_materialize(faked).returncode, 2)
        self.assertEqual(os.listdir(faked), [fake_claude.MARKER])

    def test_creates_marks_lays_down_initial_state_and_refuses_an_existing_transcript(self):
        dest = os.path.realpath(os.path.join(self.root, "fake-home"))
        r = self.run_materialize(dest); self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(os.path.isfile(os.path.join(dest, ".afleet-fake-home")))
        slug = fake_claude.slug_of("/private/tmp/afleet-fixtures/tiny")
        t = os.path.join(dest, "projects", slug, SID + ".jsonl")
        with open(t) as fh:
            self.assertEqual(fh.read().count("\n"), 1)
        self.assertEqual(self.run_materialize(dest).returncode, 2)               # transcript already there

    def test_nested_symlink_under_a_marked_home_is_refused_by_materialize_and_replay(self):
        dest = os.path.realpath(os.path.join(self.root, "fake-home")); elsewhere = os.path.join(self.root, "elsewhere"); os.makedirs(elsewhere)
        os.makedirs(dest); write(os.path.join(dest, fake_claude.MARKER), "")
        os.symlink(elsewhere, os.path.join(dest, "projects"))
        self.assertEqual(self.run_materialize(dest).returncode, 2); self.assertEqual(os.listdir(elsewhere), [])
        os.unlink(os.path.join(dest, "projects")); r = self.run_materialize(dest, cwd="/private/tmp/afleet-fixtures/other-cwd"); self.assertEqual(r.returncode, 0)
        os.symlink(elsewhere, os.path.join(dest, "tasks"))                       # replay must refuse the artifact write
        h = Host(self.fx, self.tmp(), env={"FAKE_CLAUDE_CONFIG_HOME": dest, "FAKE_CLAUDE_CWD": "/private/tmp/afleet-fixtures/other-cwd"})
        h.send({"type": "control_request", "request_id": "i", "request": {"subtype": "initialize"}}); h.wait(lambda f: f.get("type") == "control_response")
        h.send({"type": "user", "uuid": "x", "message": {"role": "user", "content": "one"}})
        h.send({"type": "control_response", "response": {"subtype": "success", "request_id": "c1", "response": {"behavior": "allow"}}})
        self.assertEqual(h.finish(timeout=10), 2); self.assertEqual(os.listdir(elsewhere), [])

    def test_replay_refuses_a_marked_home_planted_inside_the_real_config_home(self):
        planted = os.path.join(self.fake_real_home, "planted"); os.makedirs(planted)
        write(os.path.join(planted, fake_claude.MARKER), "")
        h = Host(self.fx, self.tmp(), env={"FAKE_CLAUDE_CONFIG_HOME": planted, "CLAUDE_CONFIG_DIR": self.fake_real_home,
                                                   "FAKE_CLAUDE_CWD": REC_CWD})
        self.assertEqual(h.finish(timeout=5), 2)
        self.assertEqual(os.listdir(planted), [fake_claude.MARKER])

    def test_replay_with_config_home_reproduces_the_final_filesystem(self):
        dest = os.path.realpath(os.path.join(self.root, "fake-home")); cwd = "/private/tmp/afleet-fixtures/other-cwd"
        self.assertEqual(self.run_materialize(dest, cwd=cwd).returncode, 0)
        mirror, notif = drive_two_turns(Host(self.fx, self.tmp(), env={"FAKE_CLAUDE_CONFIG_HOME": dest, "FAKE_CLAUDE_CWD": cwd}))
        slug = fake_claude.slug_of(cwd)
        self.assertEqual(mirror["filePath"], os.path.join(dest, "projects", slug, SID + ".jsonl"))
        self.assertTrue(notif["output_file"].startswith(os.path.join(dest, "tasks")))
        self.assertTrue(os.path.isfile(notif["output_file"]))
        ok, report = fake_claude.compare_final_state(self.fx, dest, cwd)
        self.assertTrue(ok, report)

    def test_a_mirror_path_rooted_at_a_scratch_config_home_replays_into_the_fake_home(self):
        fx = scratch_home_fixture(self.root)              # filePath rooted at /private/tmp/afleet-fixtures/config-home, not at ~
        dest = os.path.realpath(os.path.join(self.root, "scratch-fake-home")); cwd = "/private/tmp/afleet-fixtures/other-cwd"
        self.assertEqual(self.run_materialize(dest, cwd=cwd, fixture=fx).returncode, 0)
        mirror, notif = drive_two_turns(Host(fx, self.tmp(), env={"FAKE_CLAUDE_CONFIG_HOME": dest, "FAKE_CLAUDE_CWD": cwd}))
        self.assertEqual(mirror["filePath"], os.path.join(dest, "projects", fake_claude.slug_of(cwd), SID + ".jsonl"))
        self.assertTrue(os.path.isfile(notif["output_file"]))
        ok, report = fake_claude.compare_final_state(fx, dest, cwd)
        self.assertTrue(ok, report)

    def test_a_file_the_fixture_does_not_hold_fails_the_final_state_comparison(self):
        dest = os.path.realpath(os.path.join(self.root, "fake-home")); cwd = "/private/tmp/afleet-fixtures/other-cwd"
        self.assertEqual(self.run_materialize(dest, cwd=cwd).returncode, 0)
        drive_two_turns(Host(self.fx, self.tmp(), env={"FAKE_CLAUDE_CONFIG_HOME": dest, "FAKE_CLAUDE_CWD": cwd}))
        self.assertTrue(fake_claude.compare_final_state(self.fx, dest, cwd)[0])
        write(os.path.join(dest, "shell-snapshots", "snap.sh"), "echo\n")       # neither a transcript nor an artifact
        ok, report = fake_claude.compare_final_state(self.fx, dest, cwd)
        self.assertFalse(ok); self.assertIn("shell-snapshots/snap.sh", report)

    def test_a_frame_naming_an_artifact_the_fixture_does_not_hold_is_reported(self):
        dest = os.path.realpath(os.path.join(self.root, "fake-home")); cwd = "/private/tmp/afleet-fixtures/other-cwd"
        self.assertEqual(self.run_materialize(dest, cwd=cwd).returncode, 0)
        os.remove(os.path.join(self.fx, "artifacts", fake_claude.slug_of(REC_CWD), SID, "tasks", "t1.output"))
        h = Host(self.fx, self.tmp(), env={"FAKE_CLAUDE_CONFIG_HOME": dest, "FAKE_CLAUDE_CWD": cwd})
        _, notif = drive_two_turns(h)
        self.assertFalse(os.path.exists(notif["output_file"]))    # the frame still names it, so the gap has to be said out loud
        self.assertIn("artifact the fixture does not hold", h.p.stderr.read())

    def test_replay_refuses_a_home_whose_initial_state_was_never_materialized(self):
        dest = os.path.realpath(os.path.join(self.root, "bare-home")); os.makedirs(dest)
        write(os.path.join(dest, fake_claude.MARKER), "")
        h = Host(self.fx, self.tmp(), env={"FAKE_CLAUDE_CONFIG_HOME": dest, "FAKE_CLAUDE_CWD": REC_CWD})
        h.send({"type": "control_request", "request_id": "i", "request": {"subtype": "initialize"}}); h.wait(lambda f: f.get("type") == "control_response")
        h.send({"type": "user", "uuid": "x", "message": {"role": "user", "content": "one"}})
        self.assertEqual(h.finish(timeout=10), 2)
        self.assertIn("materialize this fixture", h.p.stderr.read())


if __name__ == "__main__":
    unittest.main()
