import unittest
import _paths  # noqa: F401
import census


def frame(t, **kw):
    d = {"type": t}
    d.update(kw)
    return d


class PairOfTests(unittest.TestCase):
    def test_system_frame_uses_subtype(self):
        self.assertEqual(census.pair_of(frame("system", subtype="init"), {}), "system/init")

    def test_control_request_uses_request_subtype(self):
        f = frame("control_request", request_id="r1", request={"subtype": "can_use_tool"})
        self.assertEqual(census.pair_of(f, {}), "control_request/can_use_tool")

    def test_control_response_is_keyed_by_the_request_it_answers(self):
        f = frame("control_response", response={"subtype": "success", "request_id": "r1", "response": {}})
        self.assertEqual(census.pair_of(f, {"r1": "get_usage"}), "control_response/get_usage")
        self.assertEqual(census.pair_of(f, {}), "control_response/?")

    def test_plain_frame_has_no_subtype(self):
        self.assertEqual(census.pair_of(frame("assistant", message={}), {}), "assistant")


class CensusTests(unittest.TestCase):
    def frames(self):
        return [
            frame("system", subtype="init", capabilities=["a", "b"], tools=[], uuid="u"),
            frame("control_request", request_id="r1", request={"subtype": "can_use_tool", "tool_name": "Write", "input": {}}),
            frame("control_response", response={"subtype": "success", "request_id": "r1", "response": {"behavior": "allow"}}),
            frame("assistant", message={"role": "assistant", "content": [{"type": "text", "text": "hi"}, {"type": "tool_use", "id": "t"}]}),
            frame("assistant", message={"role": "assistant", "content": [{"type": "text", "text": "again"}], "model": "x"}),
        ]

    def test_pairs_keys_payload_keys_and_block_types(self):
        c = census.census(self.frames(), help_text="  --foo  x\n  -p, --print  y\n", version="2.1.259")
        self.assertEqual(c["version"], "2.1.259")
        self.assertEqual(c["flags"], ["--foo", "--print"])
        self.assertEqual(c["capabilities"], ["a", "b"])
        p = c["pairs"]
        self.assertEqual(sorted(p), ["assistant", "control_request/can_use_tool", "control_response/can_use_tool", "system/init"])
        self.assertEqual(p["control_request/can_use_tool"]["payload_keys"], ["input", "subtype", "tool_name"])
        self.assertEqual(p["control_response/can_use_tool"]["payload_keys"], ["behavior"])
        self.assertEqual(p["assistant"]["block_types"], ["text", "tool_use"])
        self.assertEqual(p["assistant"]["count"], 2)
        # required keys = keys present in every frame of the pair; keys = union
        self.assertEqual(p["assistant"]["keys"], ["message", "type"])
        self.assertEqual(p["assistant"]["payload_keys"], ["content", "model", "role"])
        self.assertEqual(p["assistant"]["required_payload_keys"], ["content", "role"])

    def test_merge_required_intersects_required_and_unions_keys(self):
        a = census.census(self.frames())
        b = census.census(self.frames()[:1] + [frame("system", subtype="init", capabilities=["a"], extra=1)])
        m = census.merge_required(a, b)
        self.assertEqual(m["pairs"]["system/init"]["keys"], ["capabilities", "extra", "subtype", "tools", "type", "uuid"])
        self.assertEqual(m["pairs"]["system/init"]["required_keys"], ["capabilities", "subtype", "type"])
        self.assertIn("assistant", m["pairs"])  # pairs only in one side are kept as recorded


class DiffTests(unittest.TestCase):
    def base(self):
        return census.census([
            frame("system", subtype="init", capabilities=["a"], tools=[]),
            frame("assistant", message={"role": "assistant", "content": []}),
        ], help_text="  --foo  x\n", version="2.1.259")

    def test_exact_mode_reports_added_pair_removed_key_and_flag_changes(self):
        rec = self.base()
        obs = census.census([
            frame("system", subtype="init", capabilities=["a", "z"]),
            frame("assistant", message={"role": "assistant", "content": []}),
            frame("afleet_invented", x=1),
        ], help_text="  --foo  x\n  --bar  y\n", version="2.1.260")
        lines = census.diff(rec, obs, "exact")
        self.assertIn("added pair afleet_invented", lines)
        self.assertIn("system/init: removed keys tools", lines)
        self.assertIn("capabilities: added z", lines)
        self.assertIn("flags: added --bar", lines)
        self.assertNotIn("version", " ".join(lines))  # version is informational

    def test_required_mode_ignores_optional_keys_and_counts(self):
        rec = census.merge_required(
            census.census([frame("assistant", message={"role": "assistant", "content": [], "model": "m"})]),
            census.census([frame("assistant", message={"role": "assistant", "content": []})]),
        )
        obs = census.census([
            frame("assistant", message={"role": "assistant", "content": []}),
            frame("assistant", message={"role": "assistant", "content": []}),
        ])
        self.assertEqual(census.diff(rec, obs, "required"), [])
        obs2 = census.census([frame("assistant", message={"content": []})])
        self.assertEqual(census.diff(rec, obs2, "required"), ["assistant: removed required payload keys role"])

    def test_identical_census_has_no_diff(self):
        self.assertEqual(census.diff(self.base(), self.base(), "exact"), [])


if __name__ == "__main__":
    unittest.main()
