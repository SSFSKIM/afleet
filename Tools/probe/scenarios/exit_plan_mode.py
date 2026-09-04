"""Plan mode, a plan presented through ExitPlanMode, approved with a setMode update (item 7)."""
META = {"name": "exit-plan-mode",
        "purpose": "--permission-mode plan, a plan presented through ExitPlanMode, approved with a setMode update",
        "serves": ["item 7"], "spikes": [], "census": True, "deterministic": False, "isolation": "config-home",
        "launch": {"max_turns": 3, "permission_mode": "plan"},
        "prompts": ["Plan, in three short bullet points, how you would add a README.md to this directory. "
                    "Then call ExitPlanMode to present the plan. Do not create any file."],
        "resume_of": None, "setup": None}


def approve(frame):
    req = frame["request"]
    if req.get("tool_name") == "ExitPlanMode":
        return {"behavior": "allow", "updatedInput": req.get("input", {}),
                "updatedPermissions": [{"type": "setMode", "mode": "acceptEdits", "destination": "session"}]}
    return {"behavior": "allow", "updatedInput": req.get("input", {})}


def run(session, ctx):
    session.on("can_use_tool", approve)
    session.send_user(META["prompts"][0])
    res = session.wait_result(timeout=150)
    plans = [f["frame"]["request"] for f in session.frames()
             if f.get("frame", {}).get("request", {}).get("tool_name") == "ExitPlanMode"]
    ctx["notes"].append("ExitPlanMode asks: %d; plan keys: %s; result: %s"
                        % (len(plans), sorted((plans[0].get("input") or {}).keys()) if plans else [],
                           (res or {}).get("subtype")))
    modes = [f["frame"] for f in session.frames() if f.get("frame", {}).get("subtype") == "status"]
    ctx["notes"].append("status frames after approval: %s" % [m.get("permissionMode") for m in modes])
