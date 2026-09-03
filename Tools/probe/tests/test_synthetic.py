"""The two hand-written S6 dialog fixtures (spec §4.7) and the gate they have to pass."""
import json
import os
import shutil
import tempfile
import unittest
import _paths  # noqa: F401
import verify
from synthetic import dialogs


def read_json(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def read_frames(path):
    with open(path, encoding="utf-8") as fh:
        return [json.loads(line) for line in fh if line.strip()]


class SyntheticDialogFixturesTests(unittest.TestCase):
    def test_build_both_fixtures_and_they_verify_once_signed(self):
        root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, root, True)
        paths = dialogs.build(root)
        self.assertEqual(sorted(os.path.basename(p) for p in paths), ["dialog-fable-overage", "dialog-refusal-fallback"])
        for p in paths:
            meta = read_json(os.path.join(p, "fixture.json"))
            self.assertTrue(meta["synthetic"]); self.assertTrue(meta["hypothesis"]); self.assertFalse(meta["census"])
            self.assertEqual(meta["review"]["reviewer"], "")
            errors, _ = verify.verify_fixture(p)
            self.assertEqual([e for e in errors if "review" not in e], [])
        frames = read_frames(os.path.join(paths[1], "frames.ndjson"))
        results = [f["frame"]["response"]["response"].get("result") for f in frames
                   if f["dir"] == "in" and f["frame"]["type"] == "control_response" and "result" in (f["frame"]["response"].get("response") or {})]
        self.assertEqual(sorted(set(results)), ["cancelled", "edit_prompt", "retry_fallback"])
        kinds = {f["frame"]["request"].get("dialog_kind") for f in frames if f["dir"] == "out" and f["frame"]["type"] == "control_request"}
        self.assertIn("refusal_fallback_prompt", kinds); self.assertIn("undeclared_probe_kind", kinds)
        self.assertTrue(any(f["frame"]["type"] == "control_cancel_request" for f in frames))
        frames2 = read_frames(os.path.join(paths[0], "frames.ndjson"))
        self.assertTrue(any(f["frame"].get("subtype") == "model_consent_fallback" for f in frames2))
        ovs = [f["frame"]["request"]["payload"]["overagesEnabled"] for f in frames2 if f["dir"] == "out" and f["frame"]["type"] == "control_request" and f["frame"]["request"].get("dialog_kind") == "fable_overage_consent_prompt"]
        self.assertEqual(sorted(set(ovs)), [False, True])


if __name__ == "__main__":
    unittest.main()
