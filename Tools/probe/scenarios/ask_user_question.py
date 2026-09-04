"""AskUserQuestion answered through updatedInput.answers (items 6, 57; S15).

S15's environment value is settled and lives in `harness.DEFAULT_ENV_TABLE`, so this scenario
needs no override and no export: the bundle compares
`CLAUDE_CODE_QUESTION_PREVIEW_FORMAT` by equality against exactly `"markdown"` and `"html"`,
and the value chosen there is what appends the tool prompt's preview instructions.
"""
META = {"name": "ask-user-question",
        "purpose": "a question with two options and previews, answered through updatedInput.answers",
        "serves": ["item 6", "item 57"], "spikes": ["S15"], "census": True, "deterministic": False,
        "isolation": "config-home", "launch": {"max_turns": 3},
        "prompts": ["Before answering, use the AskUserQuestion tool to ask me which colour I prefer, "
                    "offering exactly two options, red and blue, each with a short preview. "
                    "After I answer, reply with only the colour I chose."],
        "resume_of": None, "setup": None}


def answer_first_option(frame):
    req = frame["request"]
    inp = dict(req.get("input") or {})
    questions = inp.get("questions") or []
    answers = {}
    for q in questions:
        opts = q.get("options") or []
        answers[q.get("question", "")] = (opts[0].get("label") if opts else "red")
    inp["answers"] = answers
    return {"behavior": "allow", "updatedInput": inp}


def run(session, ctx):
    session.on("can_use_tool",
               lambda f: answer_first_option(f) if f["request"].get("tool_name") == "AskUserQuestion"
               else {"behavior": "allow", "updatedInput": f["request"].get("input", {})})
    session.send_user(META["prompts"][0])
    res = session.wait_result(timeout=150)
    asks = [f["frame"]["request"] for f in session.frames()
            if f.get("frame", {}).get("request", {}).get("tool_name") == "AskUserQuestion"]
    previews = [o.get("preview") for a in asks
                for q in (a.get("input") or {}).get("questions", []) for o in q.get("options", [])]
    ctx["notes"].append("AskUserQuestion asks: %d; previews present: %s; requires_user_interaction: %s; result: %s"
                        % (len(asks), any(previews),
                           [a.get("requires_user_interaction") for a in asks], (res or {}).get("subtype")))
    ctx["notes"].append("CLAUDE_CODE_QUESTION_PREVIEW_FORMAT=%r"
                        % ctx["launch"].env_table.get("CLAUDE_CODE_QUESTION_PREVIEW_FORMAT"))
