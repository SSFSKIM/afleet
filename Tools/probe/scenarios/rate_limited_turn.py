"""A turn the engine rejects before inference: the rate_limit_event wire path (item 21, C2.G2).

Recordable only while a seven-day window sits at 100 per cent, and free while it does --
the rejection happens before any model call, so the run costs nothing however often it is
made. Outside the census for that reason: `diff` re-runs a census scenario against the live
binary, and once the window resets this one would run a real turn and report the difference
as drift, which is a gate failing for a reason that has nothing to do with the CLI changing.
"""
META = {"name": "rate-limited-turn",
        "purpose": "two prompts rejected by the weekly rate limit; rate_limit_event, the synthetic assistant reply and a zero-cost result",
        "serves": ["item 21", "C2.G2"], "spikes": [], "census": False, "deterministic": False,
        "isolation": "config-home", "launch": {"max_turns": 2},
        "prompts": ["Reply with exactly the word: alpha", "Reply with exactly the word: beta"],
        "resume_of": None, "setup": None}

RATE_LIMIT_FIELDS = ("status", "rateLimitType", "overageStatus", "overageDisabledReason", "isUsingOverage")


def run(session, ctx):
    for i, p in enumerate(META["prompts"], 1):
        before = len(session.frames())
        session.send_user(p)
        res = session.wait_result(timeout=120) or {}
        new = [r.get("frame") or {} for r in session.frames()[before:]]
        events = [f for f in new if f.get("type") == "rate_limit_event"]
        models = [(f.get("message") or {}).get("model") for f in new if f.get("type") == "assistant"]
        ctx["notes"].append(
            "prompt %d: result %s is_error=%s duration_api_ms=%s num_turns=%s; rate_limit_event frames=%d; assistant model(s)=%r"
            % (i, res.get("subtype"), res.get("is_error"), res.get("duration_api_ms"), res.get("num_turns"),
               len(events), models))
        for f in events:
            info = f.get("rate_limit_info") or {}
            ctx["notes"].append("prompt %d rate_limit_info: %s; unifiedWindows keys=%s"
                                % (i, {k: info.get(k) for k in RATE_LIMIT_FIELDS},
                                   sorted((info.get("unifiedWindows") or {}).keys())))
    mirrors = [f for f in session.frames() if f.get("frame", {}).get("type") == "transcript_mirror"]
    ctx["notes"].append("transcript_mirror frames: %d; mirrored entries: %d"
                        % (len(mirrors), sum(len(m["frame"].get("entries") or []) for m in mirrors)))
