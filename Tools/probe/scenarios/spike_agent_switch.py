"""S17: does apply_flag_settings {agent} take effect on the next turn, and does --agent persist across --resume? (parent §7.7 restart rule).

Two halves, one agent definition. The **runtime switch** is this scenario: launch with no
agent, run a turn, send `apply_flag_settings {agent: "probe-agent"}`, run a second turn, and
read whether the reply carries the agent's marker. The agent's system prompt is the only
observable a host has for "the system prompt changed", so it is made to be one.

The **persistence** half is `main()` below (`spike_agent_switch.py persist <binary>`), because
it needs two processes and the scenario contract is one. It launches with `--agent`, then
resumes without it, and asks §7.4's two questions: does the session keep the agent, and does
the agent's `initialPrompt` replay as a user turn. `initialPrompt` is why the parent calls such
a channel not transparently restartable, so the definition carries one -- an agent without it
could not answer the question the clause is about.
"""
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import harness      # noqa: E402
import redact       # noqa: E402

MARKER = "PROBEAGENT"
AGENT = """---
name: probe-agent
description: A probe agent that marks its replies.
initialPrompt: Reply with exactly the word READY and nothing else.
---
You are the probe agent. Begin every reply with the exact word PROBEAGENT and then answer briefly.
"""
SCRATCH_CWD = "/tmp/afleet-fixtures/spike-agent-switch"

META = {"name": "spike-agent-switch", "purpose": "S17: runtime agent switch and agent persistence", "serves": [], "spikes": ["S17"], "census": False,
        "fixture": False, "deterministic": False, "isolation": "config-home", "launch": {"max_turns": 4, "setting_sources": "project"},
        "prompts": ["Reply with exactly: plain", "Reply with one short sentence about the weather."], "resume_of": None}


def setup(cwd):
    os.makedirs(os.path.join(cwd, ".claude", "agents"), exist_ok=True)
    with open(os.path.join(cwd, ".claude", "agents", "probe-agent.md"), "w") as fh:
        fh.write(AGENT)


META["setup"] = setup


def text_of(res):
    return str((res or {}).get("result"))[:200]


def user_texts(session):
    """The `user` frames the session has seen. Under `--replay-user-messages` the CLI echoes
    what the host sent, so a user frame present before anything was sent came from the engine."""
    return [str(r["frame"].get("message", {}).get("content"))[:120]
            for r in session.frames() if "frame" in r and r["frame"].get("type") == "user"]


def agent_view(session):
    """What the handshake and `system/init` say about agents, which is the readback §7.4 wants."""
    init = session.system_init or {}
    return {"init.agent": init.get("agent"),
            "init.agents": [a.get("name") if isinstance(a, dict) else a for a in (init.get("agents") or [])],
            "init.output_style": init.get("output_style")}


def run(session, ctx):
    session.send_user(META["prompts"][0])
    r1 = session.wait_result(timeout=180)
    ctx["notes"].append("turn 1 (launched with no --agent): %r; starts with %s: %s"
                        % (text_of(r1), MARKER, text_of(r1).startswith(MARKER)))
    ctx["notes"].append("agent view after turn 1: %s" % agent_view(session))
    r = session.request("apply_flag_settings", settings={"agent": "probe-agent"})
    ctx["notes"].append("apply_flag_settings {agent: probe-agent} -> subtype %s, response %r"
                        % (r.get("subtype"), r.get("response")))
    back = session.request("get_settings")
    ctx["notes"].append("get_settings readback -> %r" % (back.get("response"),))
    session.send_user(META["prompts"][1])
    r2 = session.wait_result(timeout=180)
    ctx["notes"].append("turn 2 (after apply_flag_settings): %r; starts with %s: %s"
                        % (text_of(r2), MARKER, text_of(r2).startswith(MARKER)))
    ctx["notes"].append("agent view after turn 2: %s" % agent_view(session))
    ctx["notes"].append("stderr tail: %s" % session.stderr_tail(500))


def persist(binary, notes):
    """Launch with --agent, then resume without it, recording what each session saw."""
    import uuid
    os.makedirs(SCRATCH_CWD, exist_ok=True)
    setup(SCRATCH_CWD)
    sid = str(uuid.uuid4())
    a = harness.Session(harness.Launch(binary=binary, cwd=SCRATCH_CWD, session_id=sid, agent="probe-agent",
                                       setting_sources="project", max_turns=6), redact.Redactor())
    a.start(timeout=60)
    notes.append("A: launched with --agent probe-agent, session %s" % sid)
    # A prepended `initialPrompt` runs before anything is written to stdin, so a result that
    # arrives while nothing has been sent *is* the prepend. A timeout here is the other answer.
    pre = a.wait_result(timeout=90)
    notes.append("A: result arriving before any stdin prompt (the initialPrompt prepend): %r"
                 % (text_of(pre) if pre else None))
    notes.append("A: user frames seen before any stdin prompt: %s"
                 % user_texts(a))
    notes.append("A: agent view: %s" % agent_view(a))
    a.send_user("Reply with one short sentence about the sea.")
    ra = a.wait_result(timeout=180)
    notes.append("A: reply %r; starts with %s: %s" % (text_of(ra), MARKER, text_of(ra).startswith(MARKER)))
    notes.append("A: agent view after the reply: %s" % agent_view(a))
    a.close()
    time.sleep(2)

    b = harness.Session(harness.Launch(binary=binary, cwd=SCRATCH_CWD, resume=sid,
                                       setting_sources="project", max_turns=6), redact.Redactor())
    b.start(timeout=60)
    notes.append("B: resumed %s with no --agent" % sid)
    pre_b = b.wait_result(timeout=30)
    notes.append("B: result arriving before any stdin prompt: %r" % (text_of(pre_b) if pre_b else None))
    notes.append("B: user frames seen before any stdin prompt: %s"
                 % user_texts(b))
    notes.append("B: agent view: %s" % agent_view(b))
    b.send_user("Reply with one short sentence about the sky.")
    rb = b.wait_result(timeout=180)
    notes.append("B: reply %r; starts with %s: %s" % (text_of(rb), MARKER, text_of(rb).startswith(MARKER)))
    notes.append("B: agent view after the reply: %s" % agent_view(b))
    b.close()
    return notes


def main(argv):
    if not argv or argv[0] != "persist":
        sys.stderr.write("usage: spike_agent_switch.py persist <binary>\n")
        return 2
    notes = []
    try:
        persist(argv[1], notes)
    finally:
        for n in notes:
            print(n)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
