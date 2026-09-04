"""The zero-cost census: initialize plus the requests that spend no model tokens (probe 04)."""
REQUESTS = [
    ("get_context_usage", {}), ("get_session_cost", {}), ("get_binary_version", {}), ("mcp_status", {}),
    ("background_tasks", {}), ("get_settings", {}), ("get_usage", {}), ("list_models", {}), ("get_plan", {}),
    ("file_suggestions", {"query": ""}),
]
META = {"name": "zero-cost", "purpose": "initialize and the zero-cost control requests; the drift ritual's first line",
        "serves": ["item 32", "item 33", "S8"], "census": True, "deterministic": True, "isolation": "config-home",
        "launch": {"max_turns": 1}, "prompts": [], "resume_of": None, "setup": None, "spikes": ["S8"]}


def run(session, ctx):
    for subtype, payload in REQUESTS:
        resp = session.request(subtype, timeout=30, **payload)
        ctx["notes"].append("%s -> %s" % (subtype, resp.get("subtype")))
