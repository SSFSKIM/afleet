"""Fixture layout and verifier tests (contract X8: spec §4.4, and §4.2's `verify` paragraph)."""
import json
import os
import tempfile
import unittest
import _paths  # noqa: F401
import census
import fixture
import redact
import verify

SID = "22222222-2222-4222-8222-222222222222"
HELP = "  --foo  x\n"


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        fh.write(text)


def write_bytes(path, raw):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(raw)


def read(path):
    with open(path) as fh:
        return fh.read()


def read_json(path):
    with open(path) as fh:
        return json.load(fh)


def fake_config_home(root, cwd="/private/tmp/afleet-fixtures/demo"):
    slug = fixture.slug_of(cwd)
    base = os.path.join(root, "projects", slug)
    write(os.path.join(base, SID + ".jsonl"), json.dumps({"type": "user", "uuid": "u1", "cwd": cwd, "message": {"role": "user", "content": "hi a@b.c"}}) + "\n")
    write(os.path.join(base, SID, "subagents", "agent-x.jsonl"), json.dumps({"type": "assistant", "uuid": "a1"}) + "\n")
    write(os.path.join(base, SID, "subagents", "agent-x.meta.json"), json.dumps({"agentType": "Explore"}))
    return slug


def build_fixture(root, name="demo", **overrides):
    """A tiny valid fixture: one host request answered, one CLI request answered, one cancelled."""
    frames = [
        {"t": 0, "dir": "in", "frame": {"type": "control_request", "request_id": "init-1", "request": {"subtype": "initialize"}}},
        {"t": 5, "dir": "out", "frame": {"type": "control_response", "response": {"subtype": "success", "request_id": "init-1", "response": {"commands": []}}}},
        {"t": 10, "dir": "in", "frame": {"type": "user", "uuid": "u1", "message": {"role": "user", "content": "hi"}}},
        {"t": 20, "dir": "out", "frame": {"type": "system", "subtype": "init", "capabilities": ["x"], "session_id": SID}},
        {"t": 30, "dir": "out", "frame": {"type": "control_request", "request_id": "c1", "request": {"subtype": "can_use_tool", "tool_name": "Write", "input": {}}}},
        {"t": 40, "dir": "in", "frame": {"type": "control_response", "response": {"subtype": "success", "request_id": "c1", "response": {"behavior": "allow"}}}},
        {"t": 50, "dir": "out", "frame": {"type": "control_request", "request_id": "d1", "request": {"subtype": "request_user_dialog", "dialog_kind": "zzz"}}},
        {"t": 60, "dir": "out", "frame": {"type": "control_cancel_request", "request_id": "d1"}},
        {"t": 70, "dir": "out", "frame": {"type": "transcript_mirror", "filePath": "~/.claude/projects/_slug_/%s.jsonl" % SID, "entries": [{"type": "assistant", "uuid": "a2"}]}},
        {"t": 80, "dir": "out", "frame": {"type": "system", "subtype": "task_notification", "output_file": "<artifacts>/_slug_/%s/tasks/t1.output" % SID}},
        {"t": 90, "dir": "out", "frame": {"type": "result", "subtype": "success", "result": "done"}},
    ]
    c = census.census([f["frame"] for f in frames], help_text=HELP, version="2.1.259")
    meta = {"name": name, "purpose": "test", "recorded_at": "2026-09-04T00:00:00Z", "cli_version": "2.1.259",
            "launch": {"argv": ["claude", "-p"], "env": {"CLAUDE_CODE_FORK_SUBAGENT": "1"}}, "prompts": ["hi"], "serves": ["item 1"],
            "census": True, "deterministic": True, "synthetic": False, "hypothesis": False, "late_responses": [],
            "review": {"reviewer": "kimmi", "date": "2026-09-04", "checklist_version": 1}}
    meta.update(overrides)
    d = os.path.join(root, name)
    os.makedirs(os.path.join(d, "initial"), exist_ok=True)
    os.makedirs(os.path.join(d, "transcript", "_slug_"), exist_ok=True)
    os.makedirs(os.path.join(d, "artifacts", "_slug_", SID, "tasks"), exist_ok=True)
    write(os.path.join(d, "fixture.json"), json.dumps(meta, indent=1))
    with open(os.path.join(d, "frames.ndjson"), "w") as fh:
        for f in frames:
            fh.write(json.dumps(f) + "\n")
    write(os.path.join(d, "census.json"), json.dumps(c))
    write(os.path.join(d, "redaction.json"), json.dumps({"rules": {}}))
    write(os.path.join(d, "streams.json"), json.dumps({"_slug_/%s.jsonl" % SID: 0}))
    write(os.path.join(d, "transcript", "_slug_", SID + ".jsonl"), json.dumps({"type": "assistant", "uuid": "a2"}) + "\n")
    write(os.path.join(d, "artifacts", "_slug_", SID, "tasks", "t1.output"), "bg-done\n")
    return d


def append_frame(path, rec):
    """Append one record to frames.ndjson and re-derive census.json from the result.

    `census.json` is a fingerprint of `frames.ndjson`, so a test that appends a frame and
    leaves the census behind is testing the census check, not the check it named. Only
    the tests that isolate census drift edit `census.json` by hand.
    """
    with open(os.path.join(path, "frames.ndjson"), "a") as fh:
        fh.write(json.dumps(rec) + "\n")
    frames = fixture.load(path)["frames"]
    c = census.census([r["frame"] for r in frames if "frame" in r], help_text=HELP, version="2.1.259")
    write(os.path.join(path, "census.json"), json.dumps(c))


class SlugAndSnapshotTests(unittest.TestCase):
    def test_slug_of_replaces_every_non_alphanumeric(self):
        self.assertEqual(fixture.slug_of("/Users/new/Developer/GitHub/afleet"), "-Users-new-Developer-GitHub-afleet")
        self.assertEqual(fixture.slug_of("/private/tmp/afleet-fixtures/x.y"), "-private-tmp-afleet-fixtures-x-y")

    def test_find_and_snapshot_redacts_and_rewrites_the_slug(self):
        home = tempfile.mkdtemp(); dest = tempfile.mkdtemp()
        slug = fake_config_home(home)
        self.assertEqual(fixture.find_session(home, SID)[0], slug)
        sizes = fixture.snapshot(home, SID, dest, redact.Redactor(home="/Users/probe", hostname="probe-mac"))
        self.assertEqual(sorted(sizes), ["_slug_/%s.jsonl" % SID, "_slug_/%s/subagents/agent-x.jsonl" % SID, "_slug_/%s/subagents/agent-x.meta.json" % SID])
        text = read(os.path.join(dest, "_slug_", SID + ".jsonl"))
        self.assertIn("<email>", text); self.assertNotIn("a@b.c", text)
        # the source tree is untouched
        self.assertIn("a@b.c", read(os.path.join(home, "projects", slug, SID + ".jsonl")))
        self.assertEqual(fixture.stream_sizes(dest)["_slug_/%s.jsonl" % SID], sizes["_slug_/%s.jsonl" % SID])

    def test_snapshot_stubs_a_file_it_cannot_decode(self):
        """No unredacted byte reaches disk: a file the rules cannot read is not copied through."""
        home = tempfile.mkdtemp(); dest = tempfile.mkdtemp()
        slug = fake_config_home(home)
        write_bytes(os.path.join(home, "projects", slug, SID, "blob.bin"), b"\xff\xfe\x00 a@b.c")
        fixture.snapshot(home, SID, dest, redact.Redactor(home="/Users/probe", hostname="probe-mac"))
        stub = read_json(os.path.join(dest, "_slug_", SID, "blob.bin"))
        self.assertEqual(stub["omitted"], "undecodable file")

    def test_collect_artifacts_and_tokenise(self):
        art_src = tempfile.mkdtemp(); dest = tempfile.mkdtemp()
        out = os.path.join(art_src, "claude-501", "-slug", SID, "tasks", "t9.output")
        write(out, "hello\n")
        binary = os.path.join(art_src, "claude-501", "-slug", SID, "tasks", "t10.output")
        write_bytes(binary, b"\xff\xfe\x00 not utf-8")
        write(out, "hello leak@example.com\n")
        frames = [{"type": "system", "subtype": "task_notification", "output_file": out}, {"type": "system", "subtype": "task_notification", "output_file": binary}]
        r = redact.Redactor(home="/Users/probe", hostname="probe-mac")
        mapping = fixture.collect_artifacts(frames, [], dest, r, task_root=os.path.join(art_src, "claude-501"))
        self.assertEqual(mapping[out], "<artifacts>/-slug/%s/tasks/t9.output" % SID)
        self.assertEqual(read(os.path.join(dest, "-slug", SID, "tasks", "t9.output")), "hello <email>\n")
        self.assertEqual(read_json(os.path.join(dest, "-slug", SID, "tasks", "t10.output"))["omitted"], "binary artifact")
        self.assertEqual(fixture.tokenise(frames, mapping)[0]["output_file"], "<artifacts>/-slug/%s/tasks/t9.output" % SID)


class WriteAndLoadTests(unittest.TestCase):
    def test_write_is_atomic_and_load_round_trips(self):
        root = tempfile.mkdtemp(); src = build_fixture(tempfile.mkdtemp())
        loaded = fixture.load(src)
        path = fixture.write_fixture(root, "copy", loaded["meta"], loaded["frames"], loaded["census"], {"rules": {}},
                                     os.path.join(src, "initial"), os.path.join(src, "transcript"), os.path.join(src, "artifacts"))
        self.assertEqual(path, os.path.join(root, "copy"))
        self.assertEqual(sorted(os.listdir(root)), ["copy"])  # no temp dir left behind
        again = fixture.load(path)
        self.assertEqual(again["frames"], loaded["frames"]); self.assertEqual(again["meta"]["name"], "copy")


class VerifyTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="afleet-fx-")

    def errors(self, path):
        e, w = verify.verify_fixture(path, home="/Users/probe", author="Probe Person")
        return e

    def test_valid_fixture_passes(self):
        self.assertEqual(self.errors(build_fixture(self.root)), [])

    def test_unsigned_review_fails(self):
        d = build_fixture(self.root, review={"reviewer": "", "date": "", "checklist_version": 1})
        self.assertTrue(any("review" in e for e in self.errors(d)))

    def test_planted_email_fails_in_any_file(self):
        d = build_fixture(self.root)
        with open(os.path.join(d, "transcript", "_slug_", SID + ".jsonl"), "a") as fh:
            fh.write(json.dumps({"type": "user", "message": {"content": "write to someone@example.org"}}) + "\n")
        self.assertTrue(any("email" in e for e in self.errors(d)))

    def test_orphaned_request_fails(self):
        d = build_fixture(self.root)
        append_frame(d, {"t": 95, "dir": "out", "frame": {"type": "control_request", "request_id": "c9", "request": {"subtype": "can_use_tool"}}})
        self.assertTrue(any("c9" in e and "unanswered" in e for e in self.errors(d)))

    def test_cancelled_then_late_needs_the_late_responses_entry(self):
        d = build_fixture(self.root)
        append_frame(d, {"t": 95, "dir": "in", "frame": {"type": "control_response", "response": {"subtype": "success", "request_id": "d1", "response": {}}}})
        self.assertTrue(any("d1" in e and "late" in e for e in self.errors(d)))
        d2 = build_fixture(self.root, name="demo2", late_responses=["d1"])
        append_frame(d2, {"t": 95, "dir": "in", "frame": {"type": "control_response", "response": {"subtype": "success", "request_id": "d1", "response": {}}}})
        self.assertEqual(self.errors(d2), [])

    def test_tombstone_is_skipped_by_the_lifecycle_check(self):
        d = build_fixture(self.root)
        append_frame(d, {"t": 95, "dir": "out", "dropped": "update_environment_variables", "request_id": "e1"})
        self.assertEqual(self.errors(d), [])

    def test_missing_artifact_and_bad_stream_offset_fail(self):
        d = build_fixture(self.root)
        os.remove(os.path.join(d, "artifacts", "_slug_", SID, "tasks", "t1.output"))
        self.assertTrue(any("artifacts" in e for e in self.errors(d)))
        d2 = build_fixture(self.root, name="demo2")
        write(os.path.join(d2, "streams.json"), json.dumps({"_slug_/%s.jsonl" % SID: 999}))
        self.assertTrue(any("streams.json" in e for e in self.errors(d2)))

    def test_census_mismatch_fails_and_required_mode_tolerates_optional_keys(self):
        d = build_fixture(self.root)
        c = read_json(os.path.join(d, "census.json")); c["pairs"]["system/init"]["keys"].append("ghost")
        write(os.path.join(d, "census.json"), json.dumps(c))
        self.assertTrue(any("census" in e for e in self.errors(d)))
        d2 = build_fixture(self.root, name="demo2", deterministic=False)
        c2 = read_json(os.path.join(d2, "census.json")); c2["pairs"]["system/init"]["keys"].append("optional_key")
        write(os.path.join(d2, "census.json"), json.dumps(c2))
        self.assertEqual(self.errors(d2), [])

    def test_hypothesis_requires_synthetic_and_synthetic_skips_census_recount(self):
        d = build_fixture(self.root, hypothesis=True, synthetic=False)
        self.assertTrue(any("hypothesis" in e for e in self.errors(d)))
        d2 = build_fixture(self.root, name="demo2", hypothesis=True, synthetic=True, census=False)
        self.assertEqual(self.errors(d2), [])

    def test_mirror_entries_must_reproduce_the_transcript(self):
        d = build_fixture(self.root)
        with open(os.path.join(d, "transcript", "_slug_", SID + ".jsonl"), "a") as fh:
            fh.write(json.dumps({"type": "assistant", "uuid": "not-mirrored"}) + "\n")
        self.assertTrue(any("mirror entries" in e for e in self.errors(d)))

    def test_a_file_the_scanners_cannot_read_is_a_finding(self):
        """The gate's coverage has to be total: an unscannable file is reported, not skipped."""
        d = build_fixture(self.root)
        write_bytes(os.path.join(d, "artifacts", "_slug_", SID, "tasks", "t2.output"), b"\xff\xfe\x00 secret")
        self.assertTrue(any("not UTF-8" in e for e in self.errors(d)))

    def test_names_only_files_are_scanned_as_text_not_as_structure(self):
        """census.json and redaction.json fingerprint names; nothing in them is a value.

        Read structurally they trip the scanner's identity-key predicate on ordinary
        content -- the census of any fixture carrying a `user` frame has the pair key
        `user`, and redacting an `email` field leaves `...email` as a manifest path. Read
        as text, the pattern rules still apply, so a planted address still fails.
        """
        d = build_fixture(self.root)
        write(os.path.join(d, "redaction.json"),
              json.dumps({"rules": {"identity": {"count": 2, "paths": {"user": 1, "response.email": 1}}}}))
        self.assertEqual(self.errors(d), [])
        write(os.path.join(d, "redaction.json"),
              json.dumps({"rules": {"identity": {"count": 1, "paths": {"leak@example.com": 1}}}}))
        self.assertTrue(any("email" in e for e in self.errors(d)))

    def test_malformed_transcript_is_reported_rather_than_crashing(self):
        """A gate's input is by definition possibly-malformed, so a bad line is a finding.

        The planted line is both unparseable and carries a bare `<artifacts>/` with nothing
        after it, which is the other shape that reaches the verifier only when a fixture is
        wrong: both the mirror comparison and the artifact-token scan have to survive it.
        """
        d = build_fixture(self.root)
        with open(os.path.join(d, "transcript", "_slug_", SID + ".jsonl"), "a") as fh:
            fh.write("not json <artifacts>/\n")
        self.assertTrue(any("not valid JSONL" in e for e in self.errors(d)))

    def test_report_only_warning_for_author_name(self):
        d = build_fixture(self.root)
        write(os.path.join(d, "README.md"), "recorded by Probe Person\n")
        e, w = verify.verify_fixture(d, home="/Users/probe", author="Probe Person")
        self.assertEqual(e, []); self.assertTrue(any("author" in x for x in w))


if __name__ == "__main__":
    unittest.main()
