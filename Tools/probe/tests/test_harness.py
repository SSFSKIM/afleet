import json
import os
import shutil
import sys
import threading
import tempfile
import time
import unittest
import warnings
import _paths  # noqa: F401
import harness
import redact

STAND_IN = os.path.join(os.path.dirname(__file__), "stand_in.py")


def make_launch(tmp, **kw):
    args = dict(binary=sys.executable, binary_args=[STAND_IN], cwd=tmp, session_id="11111111-1111-4111-8111-111111111111",
                config_home=None, max_turns=2)
    args.update(kw)
    return harness.Launch(**args)


class LaunchTests(unittest.TestCase):
    def test_argv_matches_the_parent_launch_line_in_order(self):
        l = harness.Launch(binary="claude", cwd="/tmp/x", session_id="s", model="haiku", permission_mode="default", max_turns=3)
        self.assertEqual(l.argv(), [
            "claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--replay-user-messages", "--forward-subagent-text", "--include-hook-events",
            "--permission-prompt-tool", "stdio", "--permission-prompts", "host",
            "--session-id", "s", "--model", "haiku", "--permission-mode", "default",
            "--enable-auth-status", "--session-mirror", "--setting-sources", "", "--strict-mcp-config", "--max-turns", "3"])

    def test_resume_fork_and_optional_flags(self):
        l = harness.Launch(binary="claude", cwd="/tmp/x", resume="r", fork=True, agent="Explore", effort="low", name="n",
                           add_dirs=["/a"], worktree="wt", allow_bypass=True, prompt_suggestions=True,
                           setting_sources=None, strict_mcp_config=False, extra_flags=["--foo"])
        a = l.argv()
        for seq in (["--resume", "r", "--fork-session"], ["--agent", "Explore"], ["--effort", "low"], ["-n", "n"], ["--add-dir", "/a"],
                    ["-w", "wt"], ["--allow-dangerously-skip-permissions"], ["--prompt-suggestions", "true"], ["--foo"]):
            i = a.index(seq[0]); self.assertEqual(a[i:i + len(seq)], seq)
        self.assertNotIn("--setting-sources", a); self.assertNotIn("--strict-mcp-config", a)

    def test_refuses_a_line_without_the_stdio_prompt_tool(self):
        with self.assertRaises(ValueError):
            harness.Launch(binary="claude", cwd="/tmp/x", session_id="s", extra_flags=["--permission-prompt-tool", "none"]).argv()

    def test_environment_applies_the_table_and_strips_forbidden_variables(self):
        base = {"PATH": "/bin", "CLAUDE_CODE_REMOTE": "1", "CLAUDE_CODE_CONTAINER_ID": "c", "CLAUDE_CODE_ENTRYPOINT": "cli", "HOME": "/Users/probe"}
        env = harness.Launch(binary="claude", cwd="/tmp/x", session_id="s", config_home="/tmp/ch").environment(base)
        for k, v in harness.DEFAULT_ENV_TABLE.items():
            self.assertEqual(env[k], v)
        self.assertEqual(env["CLAUDE_CONFIG_DIR"], "/tmp/ch")
        for k in ("CLAUDE_CODE_REMOTE", "CLAUDE_CODE_CONTAINER_ID", "CLAUDE_CODE_ENTRYPOINT"):
            self.assertNotIn(k, env)
        self.assertEqual(env["PATH"], "/bin")


class SessionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="afleet-harness-")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        # The variable is read by a subprocess, so leaving it set leaks into any sibling
        # test module in the same discovery run that spawns one.
        self.addCleanup(self._restore_features, os.environ.get("STAND_IN_FEATURES"))
        self.redactor = redact.Redactor(home="/Users/probe", hostname="probe-mac")

    @staticmethod
    def _restore_features(previous):
        if previous is None:
            os.environ.pop("STAND_IN_FEATURES", None)
        else:
            os.environ["STAND_IN_FEATURES"] = previous

    def run_session(self, features, **kw):
        os.environ["STAND_IN_FEATURES"] = ",".join(features)
        s = harness.Session(make_launch(self.tmp, **kw), self.redactor)
        self.addCleanup(s.close)          # a test that fails early must not orphan a child
        init = s.start(timeout=10)
        self.assertEqual(init["current_model"], "haiku")
        return s

    def test_handshake_user_turn_and_capture_order(self):
        s = self.run_session([])
        s.send_user("hello")
        res = s.wait_result(timeout=10)
        self.assertEqual(res["subtype"], "success")
        self.assertEqual(s.system_init["claude_code_version"], "2.1.259")
        code = s.close()
        self.assertEqual(code, 0)
        kinds = [(c["dir"], c["frame"]["type"]) for c in s.frames() if "frame" in c]
        self.assertEqual(kinds[0], ("in", "control_request"))          # initialize
        self.assertEqual(kinds[1], ("out", "control_response"))
        self.assertIn(("in", "user"), kinds); self.assertIn(("out", "result"), kinds)
        ts = [c["t"] for c in s.frames()]
        self.assertEqual(ts, sorted(ts)); self.assertEqual(ts[0], 0)

    def test_capture_is_redacted_before_it_is_stored(self):
        s = self.run_session(["leak"])
        s.send_user("hi"); s.wait_result(10); s.close()
        blob = json.dumps(s.frames())
        self.assertNotIn("sk-ant-api03", blob); self.assertNotIn("leak@example.com", blob); self.assertNotIn("real@example.com", blob)
        self.assertIn("<email>", blob)

    def test_allow_deny_and_script_policies(self):
        s = self.run_session(["permission"])
        s.send_user("go"); s.wait_result(10); s.close()
        saw = [c["frame"] for c in s.frames() if c.get("frame", {}).get("subtype") == "stand_in_saw"]
        self.assertEqual(saw[0]["behavior"], "allow")
        s = self.run_session(["permission"]); s.on("can_use_tool", "deny")
        s.send_user("go"); s.wait_result(10); s.close()
        saw = [c["frame"] for c in s.frames() if c.get("frame", {}).get("subtype") == "stand_in_saw"]
        self.assertEqual(saw[0]["behavior"], "deny")
        s = self.run_session(["permission"])
        s.on("can_use_tool", lambda f: {"behavior": "allow", "updatedInput": {"file_path": "y.txt", "content": "changed"}})
        s.send_user("go"); s.wait_result(10); s.close()
        # "in" is host to CLI (spec §4.4), which is the direction our own answers travel.
        answers = [c["frame"] for c in s.frames() if c["dir"] == "in" and c.get("frame", {}).get("type") == "control_response"]
        self.assertTrue(any(((a["response"].get("response") or {}).get("updatedInput") or {}).get("content") == "changed" for a in answers))

    def test_unknown_request_gets_the_immediate_error_and_undeclared_dialog_is_left(self):
        s = self.run_session(["unknown", "dialog"])
        s.send_user("go"); s.wait_result(10); s.close()
        saw = {c["frame"]["what"]: c["frame"] for c in s.frames() if c.get("frame", {}).get("subtype") == "stand_in_saw"}
        self.assertEqual(saw["unknown"]["error"], "subtype bogus_probe_request not supported by afleet %s" % harness.VERSION)
        self.assertFalse(saw["dialog"]["answered"])
        cancels = [c for c in s.frames() if c.get("frame", {}).get("type") == "control_cancel_request"]
        self.assertEqual(len(cancels), 1)

    def test_mcp_server_answers_the_five_methods_and_notifications(self):
        for name, body in (("a.txt", "A"), ("b.txt", "B")):
            with open(os.path.join(self.tmp, name), "w") as fh:
                fh.write(body)
        s = self.run_session(["mcp"])
        s.send_user("go"); s.wait_result(10); s.close()
        seen = {c["frame"]["id"]: c["frame"]["mcp_response"] for c in s.frames() if c.get("frame", {}).get("what") == "mcp"}
        self.assertEqual(seen[1]["result"]["serverInfo"]["name"], "afleet")
        self.assertEqual(seen[None], {"jsonrpc": "2.0", "result": {}, "id": 0})
        self.assertEqual(seen[2]["result"], {})
        tools = seen[3]["result"]["tools"]; self.assertEqual(tools[0]["name"], "send_user_file")
        self.assertEqual(tools[0]["inputSchema"]["required"], ["files", "status"])
        self.assertIn("a.txt", seen[4]["result"]["content"][0]["text"]); self.assertIn("b.txt", seen[4]["result"]["content"][0]["text"])
        self.assertEqual(seen[5]["error"]["code"], -32601)

    def test_hook_callback_default_answer(self):
        s = self.run_session(["hook"])
        s.send_user("go"); s.wait_result(10); s.close()
        saw = [c["frame"] for c in s.frames() if c.get("frame", {}).get("what") == "hook"][0]
        self.assertEqual(saw["response"], {"continue": True})

    def test_update_environment_variables_becomes_a_tombstone_and_its_answer_is_not_captured(self):
        s = self.run_session(["envvars"])
        s.send_user("go"); s.wait_result(10); s.close()
        blob = json.dumps(s.frames())
        self.assertNotIn("s3cret", blob)
        tomb = [c for c in s.frames() if c.get("dropped") == "update_environment_variables"]
        self.assertEqual(len(tomb), 1); self.assertIn("request_id", tomb[0])
        rid = tomb[0]["request_id"]
        self.assertFalse(any(c.get("frame", {}).get("response", {}).get("request_id") == rid for c in s.frames()))

    def test_declared_dialog_and_elicitation_settle_neutrally(self):
        # Parent §6.3: everything except an undeclared dialog kind must be settled, and a
        # kind named in our own handshake must not come back "not supported".
        s = self.run_session(["dialog_declared", "elicitation"])
        s.send_user("go"); s.wait_result(10); s.close()
        saw = {c["frame"]["what"]: c["frame"] for c in s.frames() if c.get("frame", {}).get("subtype") == "stand_in_saw"}
        self.assertEqual(saw["dialog_declared"]["response"], {"behavior": "cancelled"})
        # `cancel`, not `decline`: settling without making a decision the scenario did not
        # make, which is what the CLI itself answers (parity 31-27, the "Any error during
        # elicitation" row, 31 §15.2).
        self.assertEqual(saw["elicitation"]["response"], {"action": "cancel"})

    def test_a_scenario_policy_overrides_the_neutral_defaults(self):
        s = self.run_session(["elicitation"])
        s.on("elicitation", lambda f: {"action": "accept", "content": {"choice": "second"}})
        s.send_user("go"); s.wait_result(10); s.close()
        saw = [c["frame"] for c in s.frames() if c.get("frame", {}).get("what") == "elicitation"][0]
        self.assertEqual(saw["response"], {"action": "accept", "content": {"choice": "second"}})

    def test_request_returns_the_response_and_captures_both_directions(self):
        s = self.run_session([])
        resp = s.request("set_model", timeout=10, model="haiku", note="round trip")
        self.assertEqual(resp["subtype"], "success")
        self.assertEqual(resp["response"], {"echo": "set_model", "note": "round trip"})
        s.send_user("go"); s.wait_result(10); s.close()
        captured = s.frames()
        sent = [c for c in captured if c["dir"] == "in" and c.get("frame", {}).get("request", {}).get("subtype") == "set_model"]
        self.assertEqual(len(sent), 1)
        self.assertEqual(sent[0]["frame"]["request"]["model"], "haiku")
        rid = sent[0]["frame"]["request_id"]
        self.assertEqual(resp["request_id"], rid)
        back = [c for c in captured if c["dir"] == "out" and c.get("frame", {}).get("response", {}).get("request_id") == rid]
        self.assertEqual(len(back), 1)
        self.assertLess(captured.index(sent[0]), captured.index(back[0]))

    def test_concurrent_sends_are_captured_in_the_order_they_are_written(self):
        """Two threads sending at once must record in the order they wrote, or the fixture
        says the host answered B before A when it answered A first."""
        s = self.run_session([])
        record = s._record

        def slow_record(direction, frame):
            recorded = record(direction, frame)
            if (frame.get("request") or {}).get("note") == "A":
                time.sleep(0.15)      # descheduled between recording and writing
            return recorded

        s._record = slow_record
        first = threading.Thread(target=s.request_async, args=("probe_order",), kwargs={"note": "A"})
        first.start()
        time.sleep(0.03)
        s.request_async("probe_order", note="B")
        first.join(10)
        s.send_user("go"); s.wait_result(10); s.close()
        captured = s.frames()
        recorded_order = [c["frame"]["request"]["note"] for c in captured
                          if c["dir"] == "in" and c.get("frame", {}).get("request", {}).get("subtype") == "probe_order"]
        # The stand-in answers strictly in the order it read the requests, so the order of
        # the answers coming back is the order they went out on the wire.
        wire_order = [c["frame"]["response"]["response"]["note"] for c in captured
                      if c["dir"] == "out" and (c.get("frame", {}).get("response", {}).get("response") or {}).get("echo") == "probe_order"]
        self.assertEqual(recorded_order, ["A", "B"])
        self.assertEqual(wire_order, recorded_order)

    def test_stderr_tail_is_redacted_at_the_source(self):
        s = self.run_session([])
        s._stderr.append("failed at /Users/probe/x on probe-mac\n")
        self.assertEqual(s.stderr_tail(), "failed at ~/x on <host>\n")
        s.send_user("go"); s.wait_result(10); s.close()

    def test_a_failed_handshake_does_not_leave_the_child_running(self):
        os.environ["STAND_IN_FEATURES"] = "no_initialize"
        s = harness.Session(make_launch(self.tmp), self.redactor)
        self.addCleanup(s.close)
        with self.assertRaises(RuntimeError):
            s.start(timeout=1)
        self.assertIsNotNone(s.proc.poll())        # reaped, not orphaned holding the session id

    def test_close_is_bounded_when_a_writer_holds_the_stdin_lock(self):
        """§6.7's 5 s bound has to hold even when a dispatch thread is wedged mid-write:
        otherwise SIGTERM waits on the very writer only SIGTERM can unblock."""
        s = self.run_session([])
        s.send_user("go"); s.wait_result(10)
        s.proc.stdin.close()          # the child sees EOF and exits of its own accord
        s._write_lock.acquire()       # a wedged writer never gives the lock back
        try:
            t0 = time.time(); code = s.close(); dt = time.time() - t0
        finally:
            s._write_lock.release()
        self.assertIsNotNone(code)    # close returned at all
        self.assertLess(dt, 11.0)

    def test_request_round_trip_and_close_sequence_with_a_stubborn_child(self):
        s = self.run_session(["ignore_end_session"])
        s.send_user("go"); s.wait_result(10)
        t0 = time.time(); code = s.close(); dt = time.time() - t0
        self.assertIn(code, (-15, 143))           # SIGTERM after the 5 s end_session wait
        self.assertGreaterEqual(dt, 5.0); self.assertLess(dt, 11.0)

    def test_the_spill_directory_is_removed_on_close_without_losing_frames(self):
        s = self.run_session(["leak", "leak"])
        s.spill_after = 3
        s.send_user("hi"); s.wait_result(10)
        spool_dir = s._spool[0]
        self.assertTrue(os.path.isdir(spool_dir))
        spilled = len(s.frames())
        s.close()
        self.assertFalse(os.path.exists(spool_dir))
        kept = s.frames()
        self.assertGreaterEqual(len(kept), spilled)        # the spilled records came back
        self.assertEqual([c["t"] for c in kept], sorted(c["t"] for c in kept))
        s.close()                                          # idempotent: a second close is harmless
        self.assertEqual(len(s.frames()), len(kept))

    def test_spill_keeps_order_and_content(self):
        s = self.run_session(["leak", "leak"], )
        s.spill_after = 3
        s.send_user("hi"); s.wait_result(10); s.close()
        fr = s.frames()
        self.assertGreater(len(fr), 3)
        self.assertEqual([c["t"] for c in fr], sorted(c["t"] for c in fr))
        self.assertTrue(all("frame" in c or "dropped" in c for c in fr))


class RecordingHostnameTests(unittest.TestCase):
    """The redactor substitutes the recording machine's name as plain text, so a name that
    reads like a word mangles that word throughout the fixture. The harness warns; it never
    fails, and it never changes what is redacted."""

    def sessions_warnings(self, hostname):
        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always")
            session = harness.Session(harness.Launch(binary="claude", cwd="/tmp/x", session_id="s"),
                                      redact.Redactor(home="/Users/probe", hostname=hostname))
        return session, [str(w.message) for w in caught]

    def test_a_word_shaped_hostname_warns_and_the_session_is_still_usable(self):
        session, messages = self.sessions_warnings("dev")
        self.assertEqual(len(messages), 1)
        self.assertIn("dev", messages[0])
        self.assertEqual(session.frames(), [])
        self.assertEqual(session.redactor.hostname, "dev")   # the warning changes no redaction

    def test_ordinary_hostnames_are_quiet(self):
        for hostname in ("Mac-mini.local", "probe-mac", "build17", "Mini", "ci", "workstation"):
            session, messages = self.sessions_warnings(hostname)
            self.assertEqual(messages, [], hostname)
            self.assertIsNotNone(session)

    def test_the_predicate_looks_at_the_short_name_and_spares_what_the_redactor_skips(self):
        self.assertTrue(harness.word_shaped_hostname("app.local"))    # `app` is substituted, and is a word
        self.assertFalse(harness.word_shaped_hostname("ci.local"))    # two characters: never substituted
        self.assertFalse(harness.word_shaped_hostname(None))


if __name__ == "__main__":
    unittest.main()
