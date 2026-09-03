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
            "withdrawn_requests": [],
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


def rewrite_frames(path, mutate):
    """Apply `mutate` to every frame in frames.ndjson and write it back.

    For edits that change a frame's values but not its key sets, which leaves census.json
    describing the result as faithfully as it described the original.
    """
    frames = fixture.load(path)["frames"]
    for rec in frames:
        if "frame" in rec:
            mutate(rec["frame"])
    with open(os.path.join(path, "frames.ndjson"), "w") as fh:
        for rec in frames:
            fh.write(json.dumps(rec) + "\n")


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

    def test_hypothesis_requires_synthetic_and_a_synthetic_census_is_still_recounted(self):
        """The recount needs no binary, so a hand-written census is held to its own frames.

        §4.4 excludes a synthetic fixture from `diff`, the live-binary drift command. This
        is not that command, and a hand-written census is the one nothing else reads.
        """
        d = build_fixture(self.root, hypothesis=True, synthetic=False)
        self.assertTrue(any("hypothesis" in e for e in self.errors(d)))
        d2 = build_fixture(self.root, name="demo2", hypothesis=True, synthetic=True, census=False)
        self.assertEqual(self.errors(d2), [])
        c = read_json(os.path.join(d2, "census.json")); c["pairs"]["system/init"]["keys"].append("ghost")
        write(os.path.join(d2, "census.json"), json.dumps(c))
        self.assertTrue(any("census" in e for e in self.errors(d2)))

    def test_fixture_json_must_declare_the_required_metadata(self):
        """A missing `deterministic` is not a default but a silent downgrade.

        It reads as false, which picks the permissive census comparison over the strict one
        -- the ambiguity `census.diff` refuses to resolve by defaulting at its own boundary.
        """
        d = build_fixture(self.root)
        meta = read_json(os.path.join(d, "fixture.json")); del meta["deterministic"]
        write(os.path.join(d, "fixture.json"), json.dumps(meta, indent=1))
        self.assertTrue(any("missing deterministic" in e for e in self.errors(d)))

    def test_a_flag_field_present_but_not_a_boolean_fails(self):
        """Presence is the wrong instrument for the field whose value picks the comparison.

        `"deterministic": null` is present and reads as false, which is the same silent
        downgrade of the strict gate to the permissive one that a missing field makes.
        """
        for field in ("census", "deterministic", "synthetic", "hypothesis"):
            d = build_fixture(self.root, name=field, **{field: None})
            self.assertTrue(any("%s must be true or false" % field in e for e in self.errors(d)), field)

    def test_census_version_must_match_the_declared_cli_version(self):
        d = build_fixture(self.root, cli_version="2.1.260")
        self.assertTrue(any("cli_version" in e for e in self.errors(d)))

    def test_a_mis_shaped_census_is_reported_rather_than_crashing(self):
        """The recount reads hand-written censuses now, which are the ones that are mis-shaped."""
        d = build_fixture(self.root)
        write(os.path.join(d, "census.json"), json.dumps({}))
        self.assertTrue(any("pairs map" in e for e in self.errors(d)))
        d2 = build_fixture(self.root, name="demo2")
        c = read_json(os.path.join(d2, "census.json")); c["pairs"]["system/init"] = "not a record"
        write(os.path.join(d2, "census.json"), json.dumps(c))
        self.assertTrue(any("cannot read" in e for e in self.errors(d2)))

    def test_a_reused_request_id_is_reported(self):
        """The second request takes the id's state entry, so the first stops being checked."""
        d = build_fixture(self.root)
        append_frame(d, {"t": 95, "dir": "out", "frame": {"type": "control_request", "request_id": "c1", "request": {"subtype": "can_use_tool"}}})
        append_frame(d, {"t": 96, "dir": "in", "frame": {"type": "control_response", "response": {"subtype": "success", "request_id": "c1", "response": {"behavior": "allow"}}}})
        self.assertTrue(any("c1" in e and "opened twice" in e for e in self.errors(d)))

    def test_mirror_entries_must_reproduce_the_transcript(self):
        d = build_fixture(self.root)
        with open(os.path.join(d, "transcript", "_slug_", SID + ".jsonl"), "a") as fh:
            fh.write(json.dumps({"type": "assistant", "uuid": "not-mirrored"}) + "\n")
        self.assertTrue(any("mirror entries" in e for e in self.errors(d)))

    def test_a_synthetic_fixture_that_declares_a_transcript_is_still_mirror_checked(self):
        """`synthetic` was only ever a proxy for "has no transcript"; the transcript is the fact."""
        d = build_fixture(self.root, synthetic=True, hypothesis=True)
        with open(os.path.join(d, "transcript", "_slug_", SID + ".jsonl"), "a") as fh:
            fh.write(json.dumps({"type": "assistant", "uuid": "not-mirrored"}) + "\n")
        self.assertTrue(any("mirror entries" in e for e in self.errors(d)))

    def test_a_token_inside_prose_is_not_read_as_a_path(self):
        """A false missing-artifact failure is how a gate stops being read."""
        d = build_fixture(self.root)

        def mention(f):
            if f.get("type") == "result":
                f["result"] = "wrote <artifacts>/_slug_/%s/tasks/t1.output for you" % SID

        rewrite_frames(d, mention)
        self.assertEqual(self.errors(d), [])

    def test_a_file_the_scanners_cannot_read_is_a_finding(self):
        """The gate's coverage has to be total: an unscannable file is reported, not skipped."""
        d = build_fixture(self.root)
        write_bytes(os.path.join(d, "artifacts", "_slug_", SID, "tasks", "t2.output"), b"\xff\xfe\x00 secret")
        self.assertTrue(any("not UTF-8" in e for e in self.errors(d)))

    def test_name_bearing_keys_are_moved_out_of_key_position_before_the_scan(self):
        """A protocol name promoted into key position is not a field whose value can leak.

        The census of any fixture carrying a `user` frame has the pair key `user`, and
        redacting an `email` field leaves `...email` as a manifest path, so read as they sit
        both files trip the identity-key predicate on ordinary content. Moved into value
        position they get the pattern rules and nothing else, and a planted address still
        fails.
        """
        d = build_fixture(self.root)
        write(os.path.join(d, "redaction.json"),
              json.dumps({"rules": {"identity": {"count": 2, "paths": {"user": 1, "response.email": 1}}}}))
        self.assertEqual(self.errors(d), [])
        write(os.path.join(d, "redaction.json"),
              json.dumps({"rules": {"identity": {"count": 1, "paths": {"leak@example.com": 1}}}}))
        self.assertTrue(any("email" in e for e in self.errors(d)))

    def test_capabilities_keep_every_predicate_inside_the_census(self):
        """The counterpart: `capabilities` is a value the census copies verbatim off the wire.

        Unreachable for a recorded fixture, whose frames met the redactor before the census
        saw them; reachable for any hand-written `synthetic: true` one, and §4.7 makes those
        load-bearing for the wire paths that cannot be provoked on demand.
        """
        d = build_fixture(self.root)
        c = read_json(os.path.join(d, "census.json"))
        c["capabilities"] = {"account": "11111111-1111-4111-8111-111111111111", "oauthToken": "zzz"}
        write(os.path.join(d, "census.json"), json.dumps(c))
        e = self.errors(d)
        self.assertTrue(any("capabilities.account" in x for x in e))
        self.assertTrue(any("capabilities.oauthToken" in x for x in e))

    def test_only_a_cli_cancel_of_a_cli_request_ends_a_lifecycle(self):
        """§4.2 permits exactly one shape; a host request cannot be excused by a cancel line."""
        d = build_fixture(self.root)
        append_frame(d, {"t": 95, "dir": "in", "frame": {"type": "control_request", "request_id": "h9", "request": {"subtype": "interrupt"}}})
        append_frame(d, {"t": 96, "dir": "in", "frame": {"type": "control_cancel_request", "request_id": "h9"}})
        e = self.errors(d)
        self.assertTrue(any("cancel for h9" in x for x in e))
        self.assertTrue(any("unanswered request h9" in x for x in e))

    def withdrawal(self, name, cancel_dir="in", **overrides):
        """A host request the host cancels: `control-shapes`' oauth-wait shape.

        The request travels `in`, host to CLI, so the cancel that withdraws it travels `in`
        too -- a cancel always names one of the sender's own in-flight requests. `cancel_dir`
        exists to state that the other way round and watch the escape refuse to apply.

        A CLI frame closes the recording so the tail tolerance cannot do the work, which keeps
        each of these about `withdrawn_requests` and nothing else.
        """
        d = build_fixture(self.root, name=name, **overrides)
        append_frame(d, {"t": 95, "dir": "in", "frame": {"type": "control_request", "request_id": "o1", "request": {"subtype": "claude_oauth_wait_for_completion"}}})
        append_frame(d, {"t": 96, "dir": cancel_dir, "frame": {"type": "control_cancel_request", "request_id": "o1"}})
        return d

    def test_a_declared_withdrawal_settles_a_host_request_that_never_answers(self):
        d = self.withdrawal("demo", withdrawn_requests=["o1"])
        append_frame(d, {"t": 97, "dir": "out", "frame": {"type": "result", "subtype": "success", "result": "done"}})
        self.assertEqual(self.errors(d), [])

    def test_a_withdrawn_request_that_settles_later_needs_no_late_responses_entry(self):
        """The CLI honours a host cancel for three subtypes and answers even for those, so a
        response after the cancel is the ordinary case, not the exception `late_responses` licenses."""
        d = self.withdrawal("demo", withdrawn_requests=["o1"])
        append_frame(d, {"t": 97, "dir": "out", "frame": {"type": "control_response", "response": {"subtype": "error", "request_id": "o1", "error": "cancelled"}}})
        self.assertEqual(self.errors(d), [])

    def test_a_host_cancel_without_the_declaration_still_fails(self):
        d = self.withdrawal("demo")
        append_frame(d, {"t": 97, "dir": "out", "frame": {"type": "result", "subtype": "success", "result": "done"}})
        e = self.errors(d)
        self.assertTrue(any("cancel for o1" in x for x in e))
        self.assertTrue(any("unanswered request o1" in x for x in e))

    def test_a_declared_withdrawal_cancelled_the_wrong_way_round_is_not_excused(self):
        """The direction is the hazard: it is easy to state backwards, and backwards it either
        excuses nothing or excuses everything, both invisibly until a recording is rejected."""
        d = self.withdrawal("demo", cancel_dir="out", withdrawn_requests=["o1"])
        append_frame(d, {"t": 97, "dir": "out", "frame": {"type": "result", "subtype": "success", "result": "done"}})
        e = self.errors(d)
        self.assertTrue(any("cancel for o1" in x for x in e))
        self.assertTrue(any("unanswered request o1" in x for x in e))

    def test_a_declaration_without_the_cancel_frame_still_fails(self):
        d = build_fixture(self.root, withdrawn_requests=["o1"])
        append_frame(d, {"t": 95, "dir": "in", "frame": {"type": "control_request", "request_id": "o1", "request": {"subtype": "claude_oauth_wait_for_completion"}}})
        append_frame(d, {"t": 96, "dir": "out", "frame": {"type": "result", "subtype": "success", "result": "done"}})
        self.assertTrue(any("unanswered request o1" in e for e in self.errors(d)))

    def test_a_response_travelling_the_wrong_direction_fails(self):
        d = build_fixture(self.root)
        append_frame(d, {"t": 95, "dir": "out", "frame": {"type": "control_request", "request_id": "c9", "request": {"subtype": "can_use_tool"}}})
        append_frame(d, {"t": 96, "dir": "out", "frame": {"type": "control_response", "response": {"subtype": "success", "request_id": "c9", "response": {}}}})
        self.assertTrue(any("c9" in e and "wrong direction" in e for e in self.errors(d)))

    def test_a_duplicate_response_fails(self):
        d = build_fixture(self.root)
        append_frame(d, {"t": 95, "dir": "in", "frame": {"type": "control_response", "response": {"subtype": "success", "request_id": "c1", "response": {"behavior": "allow"}}}})
        self.assertTrue(any("duplicate response to c1" in e for e in self.errors(d)))

    def test_a_response_to_an_unknown_request_fails(self):
        d = build_fixture(self.root)
        append_frame(d, {"t": 95, "dir": "in", "frame": {"type": "control_response", "response": {"subtype": "success", "request_id": "nope", "response": {}}}})
        self.assertTrue(any("response to unknown request nope" in e for e in self.errors(d)))

    def test_late_responses_licenses_one_answer_not_a_stream(self):
        d = build_fixture(self.root, late_responses=["d1"])
        late = {"t": 95, "dir": "in", "frame": {"type": "control_response", "response": {"subtype": "success", "request_id": "d1", "response": {}}}}
        append_frame(d, late)
        self.assertEqual(self.errors(d), [])
        append_frame(d, dict(late, t=96))
        self.assertTrue(any("duplicate response to d1" in e for e in self.errors(d)))

    def test_end_session_may_go_unanswered_only_as_the_last_host_frame(self):
        """The harness sends it and closes stdin in the same breath (§6.7).

        That is the whole reason its response may be absent, so later host traffic means the
        stream was still open and the missing response is a real gap.
        """
        d = build_fixture(self.root)
        append_frame(d, {"t": 95, "dir": "in", "frame": {"type": "control_request", "request_id": "end-1", "request": {"subtype": "end_session"}}})
        # A CLI frame after it, so this isolates the end_session carve-out from the separate
        # tolerance for one unwritten record sitting at the very tail.
        append_frame(d, {"t": 96, "dir": "out", "frame": {"type": "result", "subtype": "success", "result": "done"}})
        self.assertEqual(self.errors(d), [])
        append_frame(d, {"t": 97, "dir": "in", "frame": {"type": "user", "uuid": "u2", "message": {"role": "user", "content": "still open"}}})
        self.assertTrue(any("unanswered request end-1" in e for e in self.errors(d)))

    def test_one_unwritten_trailing_host_request_is_tolerated_but_only_one(self):
        """`Session._send_locked` records then writes while holding one lock (§4.3).

        A child that exits between the two leaves exactly one frame in the capture that never
        reached the wire, which is a legitimate recording. It can only sit at the tail: the
        failing write raises, so nothing the host sent follows it. A second trailing request
        is something other than one failed final write.
        """
        d = build_fixture(self.root)
        append_frame(d, {"t": 95, "dir": "in", "frame": {"type": "control_request", "request_id": "w1", "request": {"subtype": "get_settings"}}})
        self.assertEqual(self.errors(d), [])
        append_frame(d, {"t": 96, "dir": "in", "frame": {"type": "control_request", "request_id": "w2", "request": {"subtype": "get_settings"}}})
        e = self.errors(d)
        self.assertTrue(any("unanswered request w1" in x for x in e))
        self.assertFalse(any("unanswered request w2" in x for x in e))

    def test_an_unanswered_host_request_before_the_tail_still_fails(self):
        d = build_fixture(self.root)
        append_frame(d, {"t": 95, "dir": "in", "frame": {"type": "control_request", "request_id": "w1", "request": {"subtype": "get_settings"}}})
        append_frame(d, {"t": 96, "dir": "out", "frame": {"type": "result", "subtype": "success", "result": "done"}})
        self.assertTrue(any("unanswered request w1" in e for e in self.errors(d)))

    def test_timestamps_must_not_go_backwards(self):
        d = build_fixture(self.root)
        append_frame(d, {"t": 1, "dir": "out", "frame": {"type": "result", "subtype": "success", "result": "done"}})
        self.assertTrue(any("non-decreasing" in e for e in self.errors(d)))

    def test_a_bad_timestamp_does_not_poison_the_records_after_it(self):
        """One malformed value costs the reviewer one line, not every line that follows."""
        d = build_fixture(self.root)
        append_frame(d, {"t": "95", "dir": "out", "frame": {"type": "result", "subtype": "success", "result": "done"}})
        append_frame(d, {"t": 96, "dir": "out", "frame": {"type": "result", "subtype": "success", "result": "done"}})
        self.assertEqual([e for e in self.errors(d) if "timestamp" in e],
                         ["frames.ndjson line 12: timestamp not a non-decreasing int"])

    def test_a_stream_offset_must_be_a_non_negative_integer(self):
        d = build_fixture(self.root)
        write(os.path.join(d, "streams.json"), json.dumps({"_slug_/%s.jsonl" % SID: -1}))
        self.assertTrue(any("non-negative integer" in e for e in self.errors(d)))

    def test_transcript_must_extend_initial(self):
        d = build_fixture(self.root)
        write(os.path.join(d, "initial", "_slug_", SID + ".jsonl"), json.dumps({"type": "assistant", "uuid": "prior"}) + "\n")
        self.assertTrue(any("does not extend" in e for e in self.errors(d)))

    def test_an_artifact_named_only_by_initial_is_required(self):
        """A resume fixture's `initial/` is a prior session's records and names artifacts too."""
        d = build_fixture(self.root)
        write(os.path.join(d, "initial", "_slug_", SID + ".jsonl"),
              json.dumps({"type": "assistant", "uuid": "prior",
                          "output_file": "<artifacts>/_slug_/%s/tasks/prior.output" % SID}) + "\n")
        self.assertTrue(any("tasks/prior.output" in e and "missing" in e for e in self.errors(d)))

    def test_an_artifact_path_with_a_space_is_not_truncated(self):
        """A false missing-artifact failure trains a reviewer to override the gate."""
        d = build_fixture(self.root)
        tasks = os.path.join(d, "artifacts", "_slug_", SID, "tasks")
        os.rename(os.path.join(tasks, "t1.output"), os.path.join(tasks, "t 1.output"))

        def retarget(f):
            if f.get("subtype") == "task_notification":
                f["output_file"] = "<artifacts>/_slug_/%s/tasks/t 1.output" % SID

        rewrite_frames(d, retarget)
        self.assertEqual(self.errors(d), [])

    def test_the_mirror_check_rewrites_the_recorded_slug_from_meta_cwd(self):
        """A recorded `transcript_mirror.filePath` names the recording slug, not the token."""
        cwd = "/private/tmp/afleet-fixtures/demo"
        d = build_fixture(self.root, cwd=cwd)

        def relocate(f):
            if f.get("type") == "transcript_mirror":
                f["filePath"] = "~/.claude/projects/%s/%s.jsonl" % (fixture.slug_of(cwd), SID)

        rewrite_frames(d, relocate)
        self.assertEqual(self.errors(d), [])

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

    def test_the_review_signature_is_not_a_finding_but_a_second_mention_is(self):
        """§4.5 asks the reviewer to sign; a warning that fires on every run is one nobody reads."""
        signed = {"reviewer": "Probe Person", "date": "2026-09-04", "checklist_version": 1}
        d = build_fixture(self.root, review=signed)
        e, w = verify.verify_fixture(d, home="/Users/probe", author="Probe Person")
        self.assertEqual(e, []); self.assertEqual([x for x in w if "author" in x], [])
        d2 = build_fixture(self.root, name="demo2", review=signed, purpose="asked for by Probe Person")
        e2, w2 = verify.verify_fixture(d2, home="/Users/probe", author="Probe Person")
        self.assertEqual(e2, []); self.assertTrue(any("author" in x for x in w2))


if __name__ == "__main__":
    unittest.main()
