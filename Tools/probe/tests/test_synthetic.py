"""The two hand-written S6 dialog fixtures (spec §4.7) and the gate they have to pass."""
import json
import os
import shutil
import tempfile
import unittest
import _paths  # noqa: F401
import probe
import verify
from synthetic import dialogs


def read_json(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def read_frames(path):
    with open(path, encoding="utf-8") as fh:
        return [json.loads(line) for line in fh if line.strip()]


def frames_of(fixture_path):
    return read_frames(os.path.join(fixture_path, "frames.ndjson"))


def out_requests(frames, kind):
    return [f["frame"]["request"] for f in frames
            if f["dir"] == "out" and f["frame"]["type"] == "control_request"
            and f["frame"]["request"].get("dialog_kind") == kind]


def systems(frames, subtype):
    return [f["frame"] for f in frames if f["frame"].get("type") == "system" and f["frame"].get("subtype") == subtype]


class SyntheticDialogFixturesTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.root, True)
        self.paths = dialogs.build(self.root)
        self.fable, self.refusal = self.paths

    def test_build_both_fixtures_and_they_verify_once_signed(self):
        self.assertEqual(sorted(os.path.basename(p) for p in self.paths), ["dialog-fable-overage", "dialog-refusal-fallback"])
        for p in self.paths:
            meta = read_json(os.path.join(p, "fixture.json"))
            self.assertTrue(meta["synthetic"]); self.assertFalse(meta["hypothesis"]); self.assertFalse(meta["census"])
            self.assertEqual(meta["review"]["reviewer"], "")
            errors, _ = verify.verify_fixture(p)
            # Matched exactly, not by substring: `verify` formats a scanner hit as a
            # fixture-relative path followed by the hit, so a fixture file whose name
            # contained the word would let an unredacted byte through this filter. The same
            # defect `probe.classify_errors` had to fix, so the same constant settles it.
            self.assertEqual([e for e in errors if e != probe.UNSIGNED_REVIEW], [])

    def test_the_refusal_fixture_covers_every_result_and_the_close_path(self):
        frames = frames_of(self.refusal)
        results = [f["frame"]["response"]["response"].get("result") for f in frames
                   if f["dir"] == "in" and f["frame"]["type"] == "control_response" and "result" in (f["frame"]["response"].get("response") or {})]
        self.assertEqual(sorted(set(results)), ["cancelled", "edit_prompt", "retry_fallback"])
        kinds = {f["frame"]["request"].get("dialog_kind") for f in frames if f["dir"] == "out" and f["frame"]["type"] == "control_request"}
        self.assertIn("refusal_fallback_prompt", kinds); self.assertIn("undeclared_probe_kind", kinds)
        self.assertTrue(any(f["frame"]["type"] == "control_cancel_request" for f in frames))
        # The close path: an answer carrying `behavior` but no `result` at all.
        closes = [f for f in frames if f["dir"] == "in" and f["frame"]["type"] == "control_response"
                  and (f["frame"]["response"].get("response") or {}).get("behavior") == "cancelled"]
        self.assertEqual(len(closes), 1)
        self.assertNotIn("result", closes[0]["frame"]["response"]["response"])

    def test_the_retry_leg_is_the_only_wire_retraction_and_no_tombstone_is_claimed(self):
        """`tombstone` is an internal event the stream-json emitter filters out, so a fixture
        that carried one would assert a frame no host can receive. The retry leg's `supersedes`
        and the notice's `retracted_message_uuids` are the whole wire signal; the decline legs
        have none, and a host must evict `retractedMessageUuids` itself on resolution."""
        frames = frames_of(self.refusal)
        self.assertEqual([f for f in frames if f["frame"].get("type") == "tombstone"], [])
        superseding = [f["frame"] for f in frames if f["frame"].get("type") == "assistant" and "supersedes" in f["frame"]]
        self.assertEqual(len(superseding), 1)
        retracted = superseding[0]["supersedes"]
        notices = systems(frames, "model_refusal_fallback")
        self.assertEqual(len(notices), 1)
        self.assertEqual(notices[0]["direction"], "retry")
        self.assertEqual(notices[0]["retracted_message_uuids"], retracted)
        # Every dialog payload names the partial its own turn streamed.
        for req in out_requests(frames, "refusal_fallback_prompt"):
            self.assertEqual(len(req["payload"]["retractedMessageUuids"]), 1)
        # The frame the bundle says is not emitted after a declined dialog.
        self.assertEqual(systems(frames, "model_refusal_no_fallback"), [])

    def test_the_fable_fixture_never_consents_against_a_disabled_payload(self):
        """§8.4 offers `consent` only when `overagesEnabled` is true, because a bare wire reply
        never enables billing, so a leg answering it against a false payload would depict a
        reply afleet is specified never to send."""
        frames = frames_of(self.fable)
        requests = out_requests(frames, "fable_overage_consent_prompt")
        self.assertEqual(sorted({r["payload"]["overagesEnabled"] for r in requests}), [False, True])
        enabled_by_id = {}
        for f in frames:
            if f["dir"] == "out" and f["frame"]["type"] == "control_request" and f["frame"]["request"].get("dialog_kind") == "fable_overage_consent_prompt":
                enabled_by_id[f["frame"]["request_id"]] = f["frame"]["request"]["payload"]["overagesEnabled"]
        answered = 0
        for f in frames:
            if f["dir"] == "in" and f["frame"]["type"] == "control_response":
                rid = f["frame"]["response"]["request_id"]
                if enabled_by_id.get(rid) is False:
                    answered += 1
                    self.assertNotEqual((f["frame"]["response"].get("response") or {}).get("result"), "consent")
        self.assertEqual(answered, 2)      # the switch_default leg and the close path

    def test_the_consent_notice_content_tracks_persisted_as_default(self):
        """`content` is what a decision card renders, so one string reused across the frames
        would have asserted that a persisted swap can say "for this session"."""
        notices = systems(frames_of(self.fable), "model_consent_fallback")
        self.assertEqual(sorted({n["choice"] for n in notices}), ["cancelled", "switch_default"])
        for n in notices:
            if n["persisted_as_default"]:
                self.assertIn("now your default model", n["content"])
            else:
                self.assertIn("for this session", n["content"])
            self.assertIn("/model to change", n["content"])

    def test_the_refusal_copy_matches_the_branch_its_category_selects(self):
        """The CLI picks the safeguards sentence from the refusal category -- `cyber` and `bio`
        take the broad-safeguards branch, everything else takes "safe, normal conversations" --
        and appends a `Details` suffix for any non-empty category. Copy from the wrong branch
        is invisible to every other check here and is what a card would render."""
        broad = "Our intentionally broad safeguards"
        general = "This sometimes happens with safe, normal conversations"
        frames = frames_of(self.refusal)
        categories = {r["payload"]["apiRefusalCategory"] for r in out_requests(frames, "refusal_fallback_prompt")}
        self.assertEqual(categories, {dialogs.CATEGORY})
        category = dialogs.CATEGORY
        wants_broad = category in ("cyber", "bio")
        copy = [f["frame"]["content"] for f in frames if f["frame"].get("subtype") == "model_refusal_fallback"]
        copy += [f["frame"]["message"]["content"][0]["text"] for f in frames
                 if f["frame"].get("type") == "assistant" and f["frame"]["uuid"].startswith("a-refusal-")]
        self.assertEqual(len(copy), 3)     # one notice on the retry leg, two refusal messages
        for text in copy:
            self.assertIn(broad if wants_broad else general, text)
            self.assertNotIn(general if wants_broad else broad, text)
            self.assertIn("Details: `[%s]`" % category, text)

    def test_every_result_frame_carries_is_error(self):
        """Both `result` schemas require it, so omitting it on a success would apply the
        fixture's own "keys the bundle shows" rule inconsistently within one frame type."""
        for p in self.paths:
            for f in frames_of(p):
                if f["frame"].get("type") == "result":
                    self.assertIsInstance(f["frame"]["is_error"], bool)
                    self.assertEqual(f["frame"]["is_error"], f["frame"]["subtype"] != "success")

    def test_each_fixture_carries_a_readme_naming_itself_and_the_baseline_it_was_confirmed_against(self):
        for p in self.paths:
            with open(os.path.join(p, "README.md"), encoding="utf-8") as fh:
                text = fh.read()
            self.assertIn(os.path.basename(p), text)
            self.assertIn("2.1.259", text)

    def test_the_build_is_byte_for_byte_reproducible(self):
        """The module's docstring promises `make synthetic` rebuilds both fixtures identically,
        which is what lets a reviewer re-run it and diff against what is committed. Nothing may
        read the clock, the environment or the host."""
        other = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, other, True)
        dialogs.build(other)
        for p in self.paths:
            name = os.path.basename(p)
            first = sorted(os.path.relpath(os.path.join(r, f), p) for r, _, fs in os.walk(p) for f in fs)
            second_root = os.path.join(other, name)
            second = sorted(os.path.relpath(os.path.join(r, f), second_root) for r, _, fs in os.walk(second_root) for f in fs)
            self.assertEqual(first, second)
            for rel in first:
                with open(os.path.join(p, rel), "rb") as a, open(os.path.join(second_root, rel), "rb") as b:
                    self.assertEqual(a.read(), b.read(), "%s/%s differs between builds" % (name, rel))


if __name__ == "__main__":
    unittest.main()
