"""S16: a general-purpose agent that itself spawns Explore (items 49, 52).

The two facts the fixture exists for are the depths on `task_started` and the two sidecars
under `subagents/`, which §8.8's two-step join reads `parentAgentId` from. `--forward-subagent-text`
is on every launch line, so whether depth-2 text or thinking reaches the host is observable
here and nowhere else in the corpus.

The prompt pins the delegation and the reply so the turn count is not the model's to choose.
"""
import os
from _tasks import wait_for_tasks

META = {"name": "nested-depth-2", "purpose": "a depth-2 run: general-purpose spawns Explore",
        "serves": ["item 49", "item 52"],
        "spikes": ["S16"], "census": True, "optional_pairs": ["system/thinking_tokens"],
        "deterministic": False, "isolation": "config-home", "launch": {"max_turns": 6},
        "unwritten_prefix": 2,          # one agent_metadata entry per subagent stream
        "mirror_identity_only": ["subagents/"],
        "prompts": ["Use the Agent tool with subagent_type general-purpose. Instruct that agent to use the "
                    "Agent tool itself with subagent_type Explore to find which files in this directory "
                    "contain the word delta, and to report the file names back to you. You must delegate "
                    "the search to a subagent rather than searching yourself, and you must use no other "
                    "tool. Then reply with only those file names, and nothing else."],
        "resume_of": None}


def setup(cwd):
    for name, text in (("one.txt", "alpha beta\n"), ("two.txt", "gamma delta\n"), ("three.md", "delta again\n")):
        with open(os.path.join(cwd, name), "w") as fh:
            fh.write(text)
META["setup"] = setup


def run(session, ctx):
    session.send_user(META["prompts"][0])
    res = session.wait_result(timeout=480)
    settled = wait_for_tasks(session, timeout=480)
    started = [f["frame"] for f in session.frames() if f.get("frame", {}).get("subtype") == "task_started"]
    ctx["notes"].append("task_started: %d, depths: %s, all settled: %s, result: %s"
                        % (len(started), sorted(t.get("spawn_depth") for t in started), settled,
                           (res or {}).get("subtype")))
    ctx["notes"].append("depth-2 text or thinking forwarded: %s" % any(
        f.get("frame", {}).get("type") == "assistant" and f["frame"].get("parent_tool_use_id") and
        any(b.get("type") in ("text", "thinking") for b in f["frame"]["message"].get("content", []))
        for f in session.frames()))
