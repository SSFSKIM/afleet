"""Wait until every task the CLI started has ended, so end_session never kills a live agent.

Shared by the agent scenarios. `CLAUDE_CODE_FORK_SUBAGENT=1` is on every launch line, which
backgrounds every subagent, so the initiating turn's `result` can arrive while the agents it
spawned are still running. A scenario that closed there would send `end_session` — or close
stdin — under a live agent and land a truncated sidecar in the fixture.

Not a scenario itself: `load_scenario` puts the scenario directory on `sys.path` before
loading, which is what lets a sibling module be imported by bare name.
"""
import time


def started_ids(session):
    return [f["frame"].get("task_id") for f in session.frames()
            if f.get("frame", {}).get("subtype") == "task_started"]


def ended_ids(session):
    return [f["frame"].get("task_id") for f in session.frames()
            if f.get("frame", {}).get("subtype") == "task_notification"]


def wait_for_tasks(session, timeout=300):
    """True when every task_started has a task_notification; also drains the auto-turns that follow."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        pending = set(started_ids(session)) - set(ended_ids(session))
        if not pending:
            time.sleep(3)                      # let a trailing auto-turn's result arrive
            return True
        time.sleep(1)
    return False
