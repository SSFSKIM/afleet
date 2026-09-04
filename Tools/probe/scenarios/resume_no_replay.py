"""S2's record: --resume replays no history (item 1).

Outside the census, because the scenario consumes its own precondition. A session's *first*
resume appends one `mode` record to its transcript and mirrors it; a second resume of the
same session appends nothing and emits no `transcript_mirror` at all. So re-running this
scenario against the session it recorded cannot reproduce the recording -- the drift ritual
reported `removed pair transcript_mirror`, which is true of the run and says nothing about
the binary. Restoring the precondition means re-recording `plain-two-turn` first, which is
not something a gate can do. Same rule as `rate-limited-turn`: a scenario leaves the census
when re-running it cannot be expected to reproduce what was recorded.
"""
import time

META = {"name": "resume-no-replay", "purpose": "--resume of plain-two-turn, initialize, six idle seconds, no history frames",
        "serves": ["item 1"], "spikes": ["S2"], "census": False, "deterministic": True, "isolation": "config-home",
        "launch": {"max_turns": 1}, "prompts": [], "resume_of": "plain-two-turn", "setup": None}


def run(session, ctx):
    time.sleep(6)
    history = [f for f in session.frames() if f.get("dir") == "out" and f.get("frame", {}).get("type") in ("assistant", "user")]
    ctx["notes"].append("assistant/user frames after resume with no input: %d" % len(history))
