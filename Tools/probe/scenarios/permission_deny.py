"""The same Write asked through can_use_tool and denied with a message (item 41)."""
META = {"name": "permission-deny", "purpose": "a Write asked through can_use_tool and denied with a message",
        "serves": ["item 41"],
        "spikes": [], "census": True, "deterministic": False, "isolation": "config-home",
        "launch": {"max_turns": 3},
        "prompts": ["Use the Write tool to create a file named probe.txt in the current directory "
                    "containing the text: afleet. Then reply with the single word: done"],
        "resume_of": None, "setup": None}


def run(session, ctx):
    session.on("can_use_tool", "deny")
    session.send_user(META["prompts"][0])
    res = session.wait_result(timeout=120)
    asks = [f for f in session.frames() if f.get("frame", {}).get("request", {}).get("subtype") == "can_use_tool"]
    ctx["notes"].append("can_use_tool requests: %d" % len(asks))
    ctx["notes"].append("result: %s; text: %r" % ((res or {}).get("subtype"), str((res or {}).get("result"))[:120]))
