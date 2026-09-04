"""S8: the control request and response shapes the command router relies on (items 11, 13; C4.G4).

Two shapes in here are deliberate and would read as defects otherwise.

`claude_oauth_callback` is handed an invalid code on purpose, because an error
`control_response` is one of the two envelopes §6.4's table has to pin and the only way to
draw one is to ask something the CLI refuses.

`claude_oauth_wait_for_completion` answers only when the login flow settles, and no login
completes here, so the scenario cancels it. A host cancel is not terminal -- the CLI's abort
map is populated by three host subtypes and this is not one of them -- so the request may
stay open to the end of the recording. `record` declares the id in `fixture.json`'s
`withdrawn_requests`, which is the one narrow escape `verify` allows, and it is written from
this `cancel()` call rather than read back out of the frames.

The sibling directory `set_cwd` relocates into is named after the session, so every run
relocates into a directory the scratch config home has never trusted. A fixed name would be
trusted from the first recording onwards and the drift ritual would compare a needs-trust
answer against a trusted one for a reason that has nothing to do with the binary.
"""
import os

META = {"name": "control-shapes",
        "purpose": "apply_flag_settings with readback, rewind_conversation, set_cwd needing trust, "
                   "the claude_authenticate family",
        "serves": ["item 11", "item 13", "C4.G4"], "spikes": ["S8"], "census": True, "deterministic": False,
        "isolation": "config-home", "launch": {"max_turns": 2},
        "prompts": ["Reply with exactly the word: shapes"], "resume_of": None, "setup": None}


def run(session, ctx):
    first_uuid = session.send_user(META["prompts"][0])
    session.wait_result(timeout=120)

    def note(sub, resp):
        body = resp.get("response") if resp.get("subtype") == "success" else resp.get("error")
        ctx["notes"].append("%s -> %s %s" % (sub, resp.get("subtype"),
                                             sorted(body.keys()) if isinstance(body, dict) else str(body)[:200]))

    note("apply_flag_settings", session.request("apply_flag_settings", settings={"effortLevel": "low"}))
    note("get_settings", session.request("get_settings"))
    note("list_models", session.request("list_models"))
    note("get_workspace_diff", session.request("get_workspace_diff"))
    note("rewind_files dry_run", session.request("rewind_files", user_message_id=first_uuid, dry_run=True))
    sibling = os.path.join(os.path.dirname(ctx["cwd"]),
                           "control-shapes-sibling-%s" % (session.system_init or {}).get("session_id", "unknown"))
    os.makedirs(sibling, exist_ok=True)
    note("set_cwd sibling", session.request("set_cwd", path=sibling))
    note("set_cwd back", session.request("set_cwd", path=ctx["cwd"]))
    note("rewind_conversation", session.request("rewind_conversation", target_message_uuid=first_uuid))
    note("claude_authenticate", session.request("claude_authenticate"))
    note("claude_oauth_callback (invalid code)", session.request("claude_oauth_callback", code="probe-invalid-code"))
    rid = session.request_async("claude_oauth_wait_for_completion")   # no login completes; capture the shape or the silence
    resp = session.wait_response(rid, timeout=10)
    if resp is None:
        session.cancel(rid)
        ctx["notes"].append("claude_oauth_wait_for_completion -> no response in 10 s; withdrawn by the host "
                            "(control_cancel_request recorded, id declared in withdrawn_requests)")
    else:
        note("claude_oauth_wait_for_completion", resp)
    note("generate_session_title", session.request("generate_session_title",
                                                   description="control shapes probe", persist=False))
