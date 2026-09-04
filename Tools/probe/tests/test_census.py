import unittest
import _paths  # noqa: F401
import census


def frame(t, **kw):
    d = {"type": t}
    d.update(kw)
    return d


class FlagsFromHelpTests(unittest.TestCase):
    # `claude --help`'s real shape: declarations at exactly two spaces, wrapped
    # description text at the description column. The lines below follow the 2.1.259
    # output, including the camelCase alias pair and the description that names
    # --permission-prompt-tool without declaring it.
    HELP = (
        "Usage: claude [options] [command] [prompt]\n"
        "\n"
        "Options:\n"
        "  -p, --print                           Print response and exit\n"
        "  --bg, --background                    Start the session in the background and\n"
        "                                        detach from the terminal\n"
        "  --allowedTools, --allowed-tools <tools...>\n"
        "                                        Comma or space-separated list of tool\n"
        "                                        names to allow\n"
        "  --permission-prompts <mode>           Controls permission prompting under\n"
        "                                        --print: \"host\" (the SDK host or\n"
        "                                        --permission-prompt-tool) or \"none\"\n"
        "  -h, --help                            Display help for command\n"
    )

    def test_the_declared_flag_list_is_sorted_and_deduplicated(self):
        self.assertEqual(census.flags_from_help(self.HELP), [
            "--allowed-tools", "--allowedTools", "--background", "--bg",
            "--help", "--permission-prompts", "--print",
        ])

    def test_a_camelcase_alias_pair_yields_both_names_untruncated(self):
        flags = census.flags_from_help(self.HELP)
        self.assertIn("--allowedTools", flags)
        self.assertIn("--allowed-tools", flags)
        # --allowed is not a flag; it is the lowercase prefix of --allowedTools
        self.assertNotIn("--allowed", flags)

    def test_a_short_flag_declaration_yields_only_the_long_name(self):
        flags = census.flags_from_help(self.HELP)
        self.assertIn("--print", flags)
        self.assertNotIn("-p", flags)

    def test_two_long_aliases_on_one_line_yield_both(self):
        flags = census.flags_from_help(self.HELP)
        self.assertIn("--bg", flags)
        self.assertIn("--background", flags)

    def test_a_flag_only_named_in_a_description_is_not_declared(self):
        self.assertIn("--permission-prompt-tool", self.HELP)
        self.assertNotIn("--permission-prompt-tool", census.flags_from_help(self.HELP))

    def test_value_placeholders_and_description_words_end_the_declaration(self):
        self.assertEqual(census.flags_from_help("  --file <path>  Read --other from disk\n"), ["--file"])

    def test_missing_or_empty_help_is_safe(self):
        self.assertEqual(census.flags_from_help(None), [])
        self.assertEqual(census.flags_from_help(""), [])


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
        # payload_keys is the `response` envelope (§4.4); body_keys is what it wraps
        self.assertEqual(p["control_response/can_use_tool"]["payload_keys"], ["request_id", "response", "subtype"])
        self.assertEqual(p["control_response/can_use_tool"]["body_keys"], ["behavior"])
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

    def test_merge_required_tells_an_empty_flag_list_from_an_uncaptured_one(self):
        # help_text="" is a run whose `claude --help` answered and declared nothing: record
        # the empty list so later diffs alarm. help_text=None is a run that never captured
        # the help at all, which is no evidence, so the previous list stands.
        previous = census.census([frame("system", subtype="init")], help_text="  --foo  x\n")
        answered_empty = census.census([frame("system", subtype="init")], help_text="")
        never_captured = census.census([frame("system", subtype="init")])
        self.assertEqual(answered_empty["flags"], [])
        self.assertIsNone(never_captured["flags"])
        self.assertEqual(census.merge_required(previous, answered_empty)["flags"], [])
        self.assertEqual(census.merge_required(previous, never_captured)["flags"], ["--foo"])
        # recording the empty list is what makes the loss visible to a later diff
        merged = census.merge_required(previous, answered_empty)
        self.assertEqual(census.diff(merged, previous, "exact"), ["flags: added --foo"])

    def test_a_control_response_records_its_envelope_and_its_body_separately(self):
        frames = [
            frame("control_request", request_id="r1", request={"subtype": "get_usage"}),
            frame("control_request", request_id="r2", request={"subtype": "get_usage"}),
            frame("control_response", response={"subtype": "success", "request_id": "r1", "response": {"tokens": 1}}),
            frame("control_response", response={"subtype": "error", "request_id": "r2", "error": "nope"}),
        ]
        p = census.census(frames)["pairs"]["control_response/get_usage"]
        # the envelope discriminates success from error; both always carry subtype+request_id
        self.assertEqual(p["payload_keys"], ["error", "request_id", "response", "subtype"])
        self.assertEqual(p["required_payload_keys"], ["request_id", "subtype"])
        # the error frame carries no body at all, and an absent body is not an empty one,
        # so it must not empty the recorded body shape
        self.assertEqual(p["body_keys"], ["tokens"])
        self.assertEqual(p["required_body_keys"], ["tokens"])

    def test_a_pair_with_no_body_at_all_omits_the_body_fields(self):
        p = census.census([
            frame("control_request", request_id="r9", request={"subtype": "get_usage"}),
            frame("control_response", response={"subtype": "error", "request_id": "r9", "error": "nope"}),
        ])["pairs"]["control_response/get_usage"]
        self.assertNotIn("body_keys", p)
        self.assertNotIn("required_body_keys", p)

    def test_merge_required_keeps_the_body_shape_when_one_recording_has_no_body(self):
        with_body = census.census([
            frame("control_request", request_id="r1", request={"subtype": "get_usage"}),
            frame("control_response", response={"subtype": "success", "request_id": "r1", "response": {"tokens": 1}}),
        ])
        no_body = census.census([
            frame("control_request", request_id="r2", request={"subtype": "get_usage"}),
            frame("control_response", response={"subtype": "error", "request_id": "r2", "error": "nope"}),
        ])
        for previous, current in ((with_body, no_body), (no_body, with_body)):
            merged = census.merge_required(previous, current)["pairs"]["control_response/get_usage"]
            self.assertEqual(merged["required_body_keys"], ["tokens"])
            self.assertEqual(merged["body_keys"], ["tokens"])

    def test_keep_alive_frames_are_excluded(self):
        c = census.census([frame("keep_alive"), frame("system", subtype="init"), frame("keep_alive")])
        self.assertEqual(sorted(c["pairs"]), ["system/init"])

    def test_frames_that_are_not_dicts_are_skipped(self):
        c = census.census(["not a frame", None, 7, frame("system", subtype="init")])
        self.assertEqual(sorted(c["pairs"]), ["system/init"])


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
        # full equality, so a spurious extra drift line fails the test too
        self.assertEqual(lines, [
            "added pair afleet_invented",
            "system/init: removed keys tools",
            "system/init: removed required keys tools",
            "capabilities: added z",
            "flags: added --bar",
        ])
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

    def test_a_removed_pair_alarms_in_both_modes(self):
        rec = self.base()
        obs = census.census([frame("system", subtype="init", capabilities=["a"], tools=[])],
                            help_text="  --foo  x\n", version="2.1.259")
        self.assertEqual(census.diff(rec, obs, "exact"), ["removed pair assistant"])
        self.assertEqual(census.diff(rec, obs, "required"), ["removed pair assistant"])

    def test_a_pair_only_one_recording_produced_is_marked_optional_and_stops_alarming(self):
        """The accumulation §4.4 mandates has to converge, not oscillate."""
        a = census.census([frame("system", subtype="init"), frame("system", subtype="thinking_tokens")])
        b = census.census([frame("system", subtype="init")])
        m = census.merge_required(a, b)
        self.assertTrue(m["pairs"]["system/thinking_tokens"]["optional"])
        self.assertNotIn("optional", m["pairs"]["system/init"])
        # Neither direction alarms now: absent is licensed, present is in the baseline.
        self.assertEqual(census.diff(m, b, "required"), [])
        self.assertEqual(census.diff(m, a, "required"), [])
        # Without the accumulation the same pair alarms whichever run came first.
        self.assertEqual(census.diff(a, b, "required"), ["removed pair system/thinking_tokens"])
        self.assertEqual(census.diff(b, a, "required"), ["added pair system/thinking_tokens"])

    def test_optional_is_sticky_across_a_later_recording_that_carries_the_pair(self):
        """A run that once lacked the pair is evidence that stands."""
        with_pair = census.census([frame("system", subtype="init"), frame("system", subtype="thinking_tokens")])
        without = census.census([frame("system", subtype="init")])
        m = census.merge_required(census.merge_required(with_pair, without), with_pair)
        self.assertTrue(m["pairs"]["system/thinking_tokens"]["optional"])
        self.assertEqual(census.diff(m, without, "required"), [])

    def test_exact_mode_still_alarms_on_an_optional_pair(self):
        """A deterministic scenario never accumulates, so its gate must stay strict."""
        a = census.census([frame("system", subtype="init"), frame("system", subtype="thinking_tokens")])
        b = census.census([frame("system", subtype="init")])
        m = census.merge_required(a, b)
        self.assertEqual(census.diff(m, b, "exact"), ["removed pair system/thinking_tokens"])

    def test_required_mode_alarms_on_a_removed_top_level_key(self):
        rec = census.census([frame("system", subtype="init", capabilities=["a"], tools=[])])
        obs = census.census([frame("system", subtype="init", capabilities=["a"])])
        self.assertEqual(census.diff(rec, obs, "required"), ["system/init: removed required keys tools"])

    def test_exact_mode_alarms_when_a_key_stops_being_required(self):
        # identical unions, different required sets: only the required comparison sees it
        rec = census.census([frame("assistant", message={"role": "assistant", "content": []})])
        obs = census.merge_required(
            census.census([frame("assistant", message={"role": "assistant", "content": []})]),
            census.census([frame("assistant", message={"content": []})]),
        )
        self.assertEqual(rec["pairs"]["assistant"]["payload_keys"], obs["pairs"]["assistant"]["payload_keys"])
        self.assertEqual(census.diff(rec, obs, "exact"), ["assistant: removed required payload keys role"])

    def test_required_mode_alarms_on_a_removed_required_body_key(self):
        rec = census.census([
            frame("control_request", request_id="r1", request={"subtype": "get_usage"}),
            frame("control_response", response={"subtype": "success", "request_id": "r1", "response": {"tokens": 1}}),
        ])
        obs = census.census([
            frame("control_request", request_id="r1", request={"subtype": "get_usage"}),
            frame("control_response", response={"subtype": "success", "request_id": "r1", "response": {}}),
        ])
        self.assertEqual(census.diff(rec, obs, "required"),
                         ["control_response/get_usage: removed required body keys tokens"])

    def test_an_unknown_mode_raises_rather_than_relaxing_the_gate(self):
        with self.assertRaises(ValueError):
            census.diff(self.base(), self.base(), "Exact")
        with self.assertRaises(ValueError):
            census.diff(self.base(), self.base(), "")

    def test_an_uncaptured_flag_list_is_reported_as_a_gap_not_as_wholesale_drift(self):
        captured = census.census([frame("system", subtype="init")], help_text="  --foo  x\n")
        uncaptured = census.census([frame("system", subtype="init")])
        self.assertIsNone(uncaptured["flags"])
        # neither side captured the help: nothing to say
        self.assertEqual(census.diff(uncaptured, uncaptured, "exact"), [])
        # one side did: name the gap rather than blame the binary for every flag
        self.assertEqual(census.diff(captured, uncaptured, "exact"), ["flags: not captured in observed"])
        self.assertEqual(census.diff(uncaptured, captured, "exact"), ["flags: not captured in recorded"])
        # captured-and-empty is still a real, comparable value
        answered_empty = census.census([frame("system", subtype="init")], help_text="")
        self.assertEqual(census.diff(captured, answered_empty, "exact"), ["flags: removed --foo"])

    def test_exact_mode_reports_payload_body_and_block_type_changes(self):
        rec = census.census([
            frame("control_request", request_id="r1", request={"subtype": "get_usage"}),
            frame("control_response", response={"subtype": "success", "request_id": "r1", "response": {"tokens": 1}}),
            frame("assistant", message={"role": "assistant", "content": [{"type": "text"}]}),
        ])
        obs = census.census([
            frame("control_request", request_id="r1", request={"subtype": "get_usage", "extra": 1}),
            frame("control_response", response={"subtype": "success", "request_id": "r1", "response": {"cost": 2}}),
            frame("assistant", message={"role": "assistant", "content": [{"type": "thinking"}]}),
        ])
        self.assertEqual(census.diff(rec, obs, "exact"), [
            "assistant: removed block types text",
            "assistant: added block types thinking",
            "control_request/get_usage: added payload keys extra",
            "control_request/get_usage: added required payload keys extra",
            "control_response/get_usage: removed body keys tokens",
            "control_response/get_usage: added body keys cost",
            "control_response/get_usage: removed required body keys tokens",
            "control_response/get_usage: added required body keys cost",
        ])

    def test_identical_census_has_no_diff(self):
        self.assertEqual(census.diff(self.base(), self.base(), "exact"), [])


if __name__ == "__main__":
    unittest.main()
