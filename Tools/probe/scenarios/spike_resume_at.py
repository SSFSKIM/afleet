"""S11: is --resume-session-at <uuid> inclusive of that message? (parent §7.7's *Fork from here*).

Run twice, and the two runs differ by exactly one flag. `AFLEET_SPIKE_RESUME_AT` unset is the
control: `--resume <plain-two-turn> --fork-session`, which forks the whole history. Set to a
chain-entry uuid, the same launch gains `--resume-session-at <uuid>`. Comparing the two forks'
transcripts is what settles inclusivity; a single run could not, because nothing else says
whether a fork copies history at all or only appends what it records.

The target uuid comes from the environment rather than from an edit to this file, so the two
runs are the same source and the worktree is never left half-edited for a concurrent executor.
The candidates are printed on every run, so the control tells the operator what to pass.
"""
import glob
import json
import os

TARGET = os.environ.get("AFLEET_SPIKE_RESUME_AT") or None

META = {"name": "spike-resume-at", "purpose": "S11: --resume-session-at inclusivity", "serves": [], "spikes": ["S11"], "census": False, "fixture": False,
        "deterministic": False, "isolation": "config-home",
        "launch": {"max_turns": 2, "fork": True,
                   "extra_flags": ["--resume-session-at", TARGET] if TARGET else []},
        "prompts": ["Reply with exactly: after"],
        "resume_of": "plain-two-turn"}


def chain(config_home, session_id):
    """(index, type, uuid) for every record of a session's transcript, in file order."""
    files = glob.glob(os.path.join(config_home, "projects", "*", session_id + ".jsonl"))
    if not files:
        return None
    out = []
    with open(files[0], encoding="utf-8") as fh:
        for i, line in enumerate(fh):
            if line.strip():
                r = json.loads(line)
                out.append((i, r.get("type"), r.get("uuid")))
    return out


def brief(records):
    return ["%d %s %s" % (i, t, u) for i, t, u in records]


def run(session, ctx):
    resumed = ctx["launch"].resume
    before = chain(ctx["config_home"], resumed) or []
    ctx["notes"].append("target passed on the launch line: %s" % (TARGET or "(none -- control run)"))
    ctx["notes"].append("launch argv: %s" % " ".join(ctx["launch"].argv()))
    ctx["notes"].append("resumed session %s holds %d records; user/assistant entries: %s"
                        % (resumed, len(before), brief([r for r in before if r[1] in ("user", "assistant")])))
    session.send_user(META["prompts"][0])
    res = session.wait_result(timeout=180)
    forked = (session.system_init or {}).get("session_id")
    ctx["notes"].append("fork session id: %s (resumed %s); result: %r"
                        % (forked, resumed, str((res or {}).get("result"))[:200]))
    after = chain(ctx["config_home"], forked)
    if after is None:
        ctx["notes"].append("no transcript for the fork under %s/projects" % ctx["config_home"])
        return
    ctx["notes"].append("fork holds %d records; full chain:\n%s" % (len(after), "\n".join(brief(after))))
    if TARGET:
        uuids = [u for _, _, u in after]
        ctx["notes"].append("target %s present in the fork: %s" % (TARGET, TARGET in uuids))
    ctx["notes"].append("resumed session now holds %d records (was %d before this run)"
                        % (len(chain(ctx["config_home"], resumed) or []), len(before)))
    ctx["notes"].append("stderr tail: %s" % session.stderr_tail(500))
