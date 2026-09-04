"""S12: a second holder against a live session's registry record (parent §7.2's Contended wording).

Three holders are put against one session id, in the order the harness makes possible. The
headless `--resume` is up first -- `Session.start()` runs before `run()` -- and then, while it
holds the session, an interactive `claude --resume` joins on a pseudo-terminal, and after that
a `claude --bg --resume`, which is the second half of the parent's S12 and the one whose help
text claims it "starts a copy and says so". The registry is read at each step and the
interactive holder's screen is captured, because whether the CLI *says* anything is exactly
the question the Contended banner's wording rests on.

The reverse order -- terminal first, afleet second -- is not reachable from inside `run()`,
since the harness has already completed its handshake by then. `AFLEET_SPIKE_TUI_FIRST=1`
suppresses this scenario's own holders so the operator can start one by hand first (this
module has a `hold` entrypoint for that) and let the headless handshake meet it.

No prompt is sent, so no model turn is spent by any of the three.
"""
import glob
import json
import os
import pty
import subprocess
import sys
import threading
import time

TUI_FIRST = os.environ.get("AFLEET_SPIKE_TUI_FIRST") == "1"
HOLD_SECONDS = int(os.environ.get("AFLEET_SPIKE_HOLD_SECONDS") or 12)
# Keystrokes fed to the interactive holder a few seconds in, as a Python string literal with
# escapes (`\x1b[B\r` is Down then Enter). A terminal that opens on the workspace-trust prompt
# never reaches the session at all, so contention cannot be observed until that prompt is
# answered; this is how the operator answers it, and every run records what it sent.
TUI_KEYS = os.environ.get("AFLEET_SPIKE_TUI_KEYS") or ""

META = {"name": "spike-contention", "purpose": "S12: headless --resume while an interactive claude --resume holds the session", "serves": [],
        "spikes": ["S12"], "census": False, "fixture": False, "deterministic": False, "isolation": "config-home", "launch": {"max_turns": 1},
        "prompts": [], "resume_of": "plain-two-turn"}


def terminal_env(config_home):
    """The environment a plain terminal would have, plus the scratch config home.

    Every `CLAUDE*` variable is dropped first. A spike run from inside a Claude Code session
    inherits that session's own markers, and one of them -- `CLAUDE_CODE_CHILD_SESSION` --
    turns transcript saving off in the interactive CLI, which silently removes the very
    registry record this scenario exists to observe. The holder has to look like a terminal
    nobody launched from an agent, so the rule is by prefix rather than by a list that would
    need extending every time the hosting CLI gains a marker.
    """
    env = {k: v for k, v in os.environ.items() if not k.startswith("CLAUDE")}
    env["CLAUDE_CONFIG_DIR"] = config_home
    return env


def registry(config_home):
    """Every registry record under the config home, reduced to the fields §7.2 reasons about."""
    out = []
    for f in sorted(glob.glob(os.path.join(config_home, "sessions", "*.json"))):
        try:
            with open(f, encoding="utf-8") as fh:
                d = json.load(fh)
        except ValueError:
            continue
        out.append({k: d.get(k) for k in ("pid", "kind", "status", "sessionId", "entrypoint", "name")})
    return out


def hold(binary, cwd, config_home, session_id, seconds, keys="", observe=None):
    """Run an interactive `claude --resume` on a pseudo-terminal and return what it printed.

    The master side is drained on its own thread: a terminal UI fills a pipe in well under a
    second, and a child blocked writing to a full pty tells us nothing about contention.
    """
    master, slave = pty.openpty()
    try:
        import fcntl
        import struct
        import termios
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    except Exception:
        pass
    env = dict(terminal_env(config_home), TERM="xterm-256color")
    proc = subprocess.Popen([binary, "--resume", session_id], cwd=cwd,
                            stdin=slave, stdout=slave, stderr=slave, env=env, close_fds=True)
    os.close(slave)
    chunks = []

    def drain():
        while True:
            try:
                data = os.read(master, 65536)
            except OSError:
                return
            if not data:
                return
            chunks.append(data)

    t = threading.Thread(target=drain, daemon=True)
    t.start()
    if keys:
        time.sleep(4)
        try:
            os.write(master, keys.encode())
        except OSError:
            pass
    # Sampled from inside the hold, not after it. The registry is the whole observable here,
    # and reading it once the holder has exited answers a different question than the one asked.
    samples = []
    deadline = time.time() + seconds
    while time.time() < deadline and proc.poll() is None:
        if observe is not None:
            s = observe()
            if not samples or s != samples[-1]:
                samples.append(s)
        time.sleep(0.5)
    exited_early = proc.poll()
    try:
        os.write(master, b"/exit\r")
    except OSError:
        pass
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
    t.join(timeout=2)
    try:
        os.close(master)
    except OSError:
        pass
    return {"pid": proc.pid, "exit_code": proc.returncode, "exited_before_the_hold_ended": exited_early is not None,
            "samples": samples, "screen": b"".join(chunks).decode("utf-8", "replace")}


def run_cli(binary, args, cwd, config_home, timeout=60):
    p = subprocess.run([binary] + args, cwd=cwd, capture_output=True, text=True, timeout=timeout,
                       env=terminal_env(config_home))
    return {"argv": " ".join(args), "returncode": p.returncode, "stdout": p.stdout[-2000:], "stderr": p.stderr[-2000:]}


def run(session, ctx):
    sid = ctx["launch"].resume
    binary = ctx["launch"].binary
    home = ctx["config_home"]
    ctx["notes"].append("binary: %s; session: %s; cwd: %s" % (binary, sid, ctx["cwd"]))
    ctx["notes"].append("headless (this process) is up: handshake ok, pid %s" % session.proc.pid)
    ctx["notes"].append("registry with the headless holder alone: %s" % registry(home))
    if TUI_FIRST:
        ctx["notes"].append("AFLEET_SPIKE_TUI_FIRST=1: no second holder started here; the observation is "
                            "whether this headless handshake succeeded at all against a holder started by hand")
        ctx["notes"].append("stderr tail: %s" % session.stderr_tail(1000))
        return

    ctx["notes"].append("keys fed to the interactive holder: %r" % TUI_KEYS)
    held = hold(binary, ctx["cwd"], home, sid, HOLD_SECONDS, TUI_KEYS, lambda: registry(home))
    ctx["notes"].append("registry states seen while the interactive holder ran (%d distinct):" % len(held["samples"]))
    for s in held["samples"]:
        ctx["notes"].append("  %s" % s)
    ctx["notes"].append("headless still alive during the interactive hold: %s" % (session.proc.poll() is None))
    ctx["notes"].append("interactive holder: pid %s, exit %s, exited before the hold ended: %s"
                        % (held["pid"], held["exit_code"], held["exited_before_the_hold_ended"]))
    ctx["notes"].append("interactive holder screen:\n%s" % held["screen"])
    ctx["notes"].append("registry after the interactive holder left: %s" % registry(home))

    bg = run_cli(binary, ["--bg", "--resume", sid], ctx["cwd"], home)
    ctx["notes"].append("`claude --bg --resume %s` -> exit %s\nstdout: %s\nstderr: %s"
                        % (sid, bg["returncode"], bg["stdout"], bg["stderr"]))
    ctx["notes"].append("registry after --bg --resume: %s" % registry(home))
    agents = run_cli(binary, ["agents", "--json"], ctx["cwd"], home)
    ctx["notes"].append("`claude agents --json` -> exit %s\nstdout: %s\nstderr: %s"
                        % (agents["returncode"], agents["stdout"], agents["stderr"]))
    ctx["notes"].append("headless still alive at the end: %s" % (session.proc.poll() is None))
    ctx["notes"].append("stderr tail: %s" % session.stderr_tail(1000))


def main(argv):
    """`python3 spike_contention.py hold <binary> <cwd> <config-home> <session-id> <seconds>`.

    The same interactive holder the scenario uses, runnable on its own so the reverse order --
    terminal holder first, headless second -- can be arranged without a second copy of it.
    """
    if not argv or argv[0] != "hold":
        sys.stderr.write("usage: spike_contention.py hold <binary> <cwd> <config-home> <session-id> <seconds>\n")
        return 2
    binary, cwd, home, sid, seconds = argv[1:6]
    held = hold(binary, cwd, home, sid, int(seconds), TUI_KEYS, lambda: registry(home))
    print("registry states seen while holding:")
    for s in held["samples"]:
        print("  %s" % s)
    print("exit %s, exited early %s" % (held["exit_code"], held["exited_before_the_hold_ended"]))
    print(held["screen"])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
