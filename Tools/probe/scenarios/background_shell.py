"""A run_in_background Bash, its task_notification and the auto-turn; the output file bundled
as an artifact (items 61, 15; C3.G3).

`keep_open` is set. The global constraint forbids sending `end_session` while a background
task is still running, because the stream close kills its shells, and this is the scenario the
flag was written for -- the scenario does wait for the notification before it returns, but a
run where the notification never arrives must not close the session over a live shell.

The prompt pins both replies -- the one that starts the task and the one the auto-turn makes
-- so the turn count is not the model's to choose.
"""
META = {"name": "background-shell",
        "purpose": "background Bash, task_notification, auto-turn, task output file",
        "serves": ["item 61", "item 15", "C3.G3"],
        "spikes": [], "census": True, "optional_pairs": ["system/thinking_tokens",
                            # Whether a run needs a permission ask is the model's choice here, not the
                            # scenario's: nothing in the prompt drives one, and `nested-depth-2` recorded
                            # a `can_use_tool` its own re-run did not produce. The three permission
                            # fixtures and `notification-hook` are where an ask is the evidence, and they
                            # stay strict.
                            "control_request/can_use_tool", "control_response/can_use_tool"],
        "deterministic": False, "isolation": "config-home", "launch": {"max_turns": 4},
        "keep_open": True,
        "prompts": ["Use the Bash tool with run_in_background=true to run exactly: sleep 6 && echo bg-done . "
                    "Then immediately reply with the single word: started . "
                    "When that background task finishes, reply with the single word: finished . "
                    "Use no tool other than that one Bash call."],
        "resume_of": None, "setup": None}


def run(session, ctx):
    session.send_user(META["prompts"][0])
    first = session.wait_result(timeout=120)
    notif = session.wait_for(lambda f: f.get("type") == "system" and f.get("subtype") == "task_notification",
                             timeout=90)
    # `wait_for` is a cursor, so this is the auto-turn's result and not the one already taken.
    second = session.wait_result(timeout=120) if notif else None
    ctx["notes"].append("first result: %s; task_notification: %s; output_file: %s; auto-turn result: %s"
                        % ((first or {}).get("subtype"), bool(notif), (notif or {}).get("output_file"),
                           (second or {}).get("subtype")))
    ctx["notes"].append("background_tasks_changed frames: %d"
                        % sum(1 for f in session.frames()
                              if f.get("frame", {}).get("subtype") == "background_tasks_changed"))
