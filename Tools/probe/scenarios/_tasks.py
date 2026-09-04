"""Wait until every task the CLI started has ended, so end_session never kills a live agent.

Shared by the agent scenarios. `CLAUDE_CODE_FORK_SUBAGENT=1` is on every launch line, which
backgrounds every subagent, so the initiating turn's `result` can arrive while the agents it
spawned are still running. A scenario that closed there would send `end_session` under a live
agent and land truncated evidence in the fixture.

Two things this has to get right, both learned from a recording that reported itself settled
and ended `result/error_during_execution` two seconds later.

A task id is not seen once. The engine re-emits `task_started` for the *same* `task_id` when
an auto-turn re-engages a backgrounded agent, so a set difference reads the earlier
`task_notification` as having settled the later start. The accounting is per occurrence.

And settling is not a moment. A re-engagement can arrive a second or two after the last
notification, so the wait ends only after nothing has been outstanding for `quiet` seconds --
which also drains the auto-turn that follows the last agent.
"""
import collections
import time


def started_ids(session):
    return [f["frame"].get("task_id") for f in session.frames()
            if f.get("frame", {}).get("subtype") == "task_started"]


def ended_ids(session):
    return [f["frame"].get("task_id") for f in session.frames()
            if f.get("frame", {}).get("subtype") == "task_notification"]


def pending(session):
    """Task ids started more often than they have ended, with their outstanding counts."""
    return collections.Counter(started_ids(session)) - collections.Counter(ended_ids(session))


def wait_for_tasks(session, timeout=300, quiet=10):
    """True when nothing has been outstanding for `quiet` seconds inside `timeout`."""
    deadline = time.time() + timeout
    calm_since = None
    while time.time() < deadline:
        if pending(session):
            calm_since = None
        else:
            calm_since = calm_since or time.time()
            if time.time() - calm_since >= quiet:
                return True
        time.sleep(1)
    return not pending(session)
