"""S10: -p with -w <name> creates and uses a worktree headless? (parent §7.7's *New isolated session*).

The parent asks three things of one launch: that the worktree is created, that the session's
cwd is inside it, and that the transcript lands under the worktree's slug rather than the
launch directory's. All three are read after a single turn -- `system/init.cwd` for the
second, and the project directory holding the session file for the third, because a slug is
derived from the *resolved* cwd (Surprises) and computing it from the launch path would
answer a different question.
"""
import glob
import os
import subprocess

META = {"name": "spike-worktree", "purpose": "S10: -w probe-wt under print mode", "serves": [], "spikes": ["S10"], "census": False, "fixture": False,
        "deterministic": False, "isolation": "config-home", "launch": {"max_turns": 2, "worktree": "probe-wt"},
        "prompts": ["Run `pwd` with the Bash tool and reply with only the directory it prints."], "resume_of": None}


def setup(cwd):
    subprocess.run(["git", "init", "-q"], cwd=cwd, check=True)
    with open(os.path.join(cwd, "README.md"), "w") as fh:
        fh.write("probe\n")
    subprocess.run(["git", "add", "."], cwd=cwd, check=True)
    subprocess.run(["git", "-c", "user.email=probe@example.invalid", "-c", "user.name=probe", "commit", "-q", "-m", "init"], cwd=cwd, check=True)


META["setup"] = setup


def transcript_dirs(config_home, session_id):
    """Every project directory under the config home holding this session's transcript."""
    return sorted(os.path.basename(os.path.dirname(p))
                  for p in glob.glob(os.path.join(config_home, "projects", "*", session_id + ".jsonl")))


def run(session, ctx):
    ctx["notes"].append("launch argv: %s" % " ".join(ctx["launch"].argv()))
    ctx["notes"].append("system/init cwd before turn: %s" % (session.system_init or {}).get("cwd"))
    session.send_user(META["prompts"][0])
    res = session.wait_result(timeout=180)
    init = session.system_init or {}
    ctx["notes"].append("system/init cwd: %s; result: %r" % (init.get("cwd"), str((res or {}).get("result"))[:200]))
    ctx["notes"].append("launch cwd (resolved): %s" % os.path.realpath(ctx["cwd"]))
    sid = init.get("session_id") or ctx["launch"].session_id
    ctx["notes"].append("session id: %s; transcript project dir(s): %s" % (sid, transcript_dirs(ctx["config_home"], sid)))
    wt = subprocess.run(["git", "worktree", "list"], cwd=ctx["cwd"], capture_output=True, text=True).stdout
    ctx["notes"].append("git worktree list:\n%s" % wt)
    ctx["notes"].append("stderr tail: %s" % session.stderr_tail(500))
