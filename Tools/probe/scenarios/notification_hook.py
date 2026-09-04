"""S18: the Notification hook registered through initialize.hooks fires while a permission ask
waits (item 53).

The handshake registers two hooks, `Notification` under `afleet.notification` and
`ConfigChange` under `afleet.config-change`, so the policy keys on `callback_id` rather than
taking the first `hook_callback` that arrives. A `ConfigChange` callback answered as if it
were the notification would release the permission ask early and record a finding about the
wrong hook; every id seen is noted either way.

`WAIT_SECONDS` is the budget the plan sets, and it is a budget rather than a target: the plan
is explicit that a hook which does not fire inside it is itself the finding, not an argument
for waiting longer.
"""
import time

META = {"name": "notification-hook",
        "purpose": "a permission ask left waiting past the idle threshold; the hook_callback for "
                   "afleet.notification and its input shape",
        "serves": ["item 53"], "spikes": ["S18"], "census": True,
        "optional_pairs": ["system/thinking_tokens"],
        "deterministic": False, "isolation": "config-home", "launch": {"max_turns": 3},
        "prompts": ["Use the Write tool to create a file named waiting.txt containing the text: wait. "
                    "Then reply with the single word: done"],
        "resume_of": None, "setup": None}
WAIT_SECONDS = 75
NOTIFICATION_CALLBACK = "afleet.notification"


def run(session, ctx):
    seen = {}
    ids = []

    def hook(frame):
        req = frame["request"]
        cb = req.get("callback_id")
        ids.append(cb)
        if cb == NOTIFICATION_CALLBACK and "input" not in seen:
            seen["input"] = req.get("input")
            seen["callback_id"] = cb
            seen["at"] = time.time()
        return {"continue": True}

    session.on("hook_callback", hook)

    def slow_allow(frame):
        t0 = time.time()
        while time.time() - t0 < WAIT_SECONDS and "input" not in seen:
            time.sleep(0.5)
        seen.setdefault("waited", round(time.time() - t0, 1))
        return {"behavior": "allow", "updatedInput": frame["request"].get("input", {})}

    session.on("can_use_tool", slow_allow)
    session.send_user(META["prompts"][0])
    res = session.wait_result(timeout=240)
    ctx["notes"].append("hook_callback seen: %s; callback_id: %s; input keys: %s; result: %s"
                        % ("input" in seen, seen.get("callback_id"),
                           sorted((seen.get("input") or {}).keys()), (res or {}).get("subtype")))
    ctx["notes"].append("hook_callback ids: %s; the ask waited %ss of the %ss budget"
                        % (ids, seen.get("waited"), WAIT_SECONDS))
    if "input" in seen:
        ctx["notes"].append("notification input: %s" % str(seen["input"])[:300])
