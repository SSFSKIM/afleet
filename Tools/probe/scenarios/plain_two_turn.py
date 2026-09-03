"""Two short prompts, no tools (items 1, 2, 31, 56; C3.G1)."""
META = {"name": "plain-two-turn", "purpose": "two short prompts, no tools",
        "serves": ["item 1", "item 2", "item 31", "item 56", "C3.G1"],
        "spikes": ["S14"], "census": True, "deterministic": False, "isolation": "config-home",
        "launch": {"max_turns": 2},
        "prompts": ["Reply with exactly the word: one", "Reply with exactly the word: two"],
        "resume_of": None, "setup": None}


def run(session, ctx):
    for p in META["prompts"]:
        session.send_user(p)
        res = session.wait_result(timeout=120)
        ctx["notes"].append("result: %s" % (res or {}).get("subtype"))
    mirrors = [f for f in session.frames() if f.get("frame", {}).get("type") == "transcript_mirror"]
    ctx["notes"].append("transcript_mirror frames: %d" % len(mirrors))
