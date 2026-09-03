"""S2's record: --resume replays no history (item 1)."""
import time

META = {"name": "resume-no-replay", "purpose": "--resume of plain-two-turn, initialize, six idle seconds, no history frames",
        "serves": ["item 1"], "spikes": ["S2"], "census": True, "deterministic": True, "isolation": "config-home",
        "launch": {"max_turns": 1}, "prompts": [], "resume_of": "plain-two-turn", "setup": None}


def run(session, ctx):
    time.sleep(6)
    history = [f for f in session.frames() if f.get("dir") == "out" and f.get("frame", {}).get("type") in ("assistant", "user")]
    ctx["notes"].append("assistant/user frames after resume with no input: %d" % len(history))
