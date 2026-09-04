"""One Explore agent searching synthetic files (items 9, 38, 49; C3.G3).

The prompt names the tool, the subagent type, the search word and the exact reply, so the
turn count is not the model's to choose -- the reproducibility test the census turns on
(child spec, Surprises: a scenario is reproducible exactly when nothing the model decides can
change how many turns it takes).
"""
import os
from _tasks import wait_for_tasks

META = {"name": "explore-depth-1", "purpose": "one Explore subagent searching synthetic files",
        "serves": ["item 9", "item 38", "item 49", "C3.G3"],
        "spikes": [], "census": True, "optional_pairs": ["system/thinking_tokens",
                            # Whether a run needs a permission ask is the model's choice here, not the
                            # scenario's: nothing in the prompt drives one, and `nested-depth-2` recorded
                            # a `can_use_tool` its own re-run did not produce. The three permission
                            # fixtures and `notification-hook` are where an ask is the evidence, and they
                            # stay strict.
                            "control_request/can_use_tool", "control_response/can_use_tool"],
        "deterministic": False, "isolation": "config-home", "launch": {"max_turns": 4},
        "mirror_identity_only": {"subagents/": ["message.stop_reason", "message.usage"]},
        # Not every field: the race is confined to the two the recordings showed, and
        # while *whether* the sidecar and its mirror disagree is timing, *which* fields
        # can is not. A drift anywhere else is a corrupt mirror and still fails.
        "prompts": ["Use the Agent tool with subagent_type Explore to find which files in this directory "
                    "contain the word gamma. Do not search yourself and do not use any other tool. "
                    "Then reply with only the file names it reports, and nothing else."],
        "resume_of": None}


def setup(cwd):
    for name, text in (("one.txt", "alpha beta\n"), ("two.txt", "gamma delta\n"), ("three.md", "no match here\n")):
        with open(os.path.join(cwd, name), "w") as fh:
            fh.write(text)
META["setup"] = setup


def run(session, ctx):
    session.send_user(META["prompts"][0])
    res = session.wait_result(timeout=300)
    settled = wait_for_tasks(session, timeout=300)
    started = [f["frame"] for f in session.frames() if f.get("frame", {}).get("subtype") == "task_started"]
    ctx["notes"].append("task_started: %d, depths: %s, all settled: %s, result: %s"
                        % (len(started), [t.get("spawn_depth") for t in started], settled,
                           (res or {}).get("subtype")))
    ctx["notes"].append("frames with parent_tool_use_id: %d"
                        % sum(1 for f in session.frames() if f.get("frame", {}).get("parent_tool_use_id")))
