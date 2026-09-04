"""A Write in the scratch cwd asked through can_use_tool and answered allow (items 4, 5; C2.G2)."""
META = {"name": "permission-allow", "purpose": "a Write asked through can_use_tool and answered allow",
        "serves": ["item 4", "item 5", "C2.G2"],
        "spikes": [], "census": True, "optional_pairs": ["system/thinking_tokens"], "deterministic": False, "isolation": "config-home",
        "launch": {"max_turns": 3},
        "prompts": ["Use the Write tool to create a file named probe.txt in the current directory "
                    "containing the text: afleet. Then reply with the single word: done"],
        "resume_of": None, "setup": None}


def run(session, ctx):
    session.send_user(META["prompts"][0])
    res = session.wait_result(timeout=120)
    asks = [f for f in session.frames() if f.get("frame", {}).get("request", {}).get("subtype") == "can_use_tool"]
    ctx["notes"].append("can_use_tool requests: %d; result: %s" % (len(asks), (res or {}).get("subtype")))
    if asks:
        r = asks[0]["frame"]["request"]
        ctx["notes"].append("ask fields: %s; suggestions: %s"
                            % (sorted(r.keys()), [x.get("type") for x in r.get("permission_suggestions") or []]))
