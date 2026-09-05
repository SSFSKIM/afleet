"""C4's follow-up: which files the TUI writes when a project `.mcp.json` server is declined (parent §6.12).

§6.12 says afleet's *Decline* records the server name in `disabledMcpjsonServers` of the
local-settings store, "the exact file and key the terminal's own dialog writes". That clause
is a claim about the terminal, and nothing in the corpus had watched the terminal make the
write. This spike watches it: a fresh scratch project declaring one stdio server, the
interactive `claude` driven on a pseudo-terminal under the scratch config home, the project
server declined at the dialog, and the project directory and the config home diffed across
the run.

The observable is *which files changed and which keys they gained*, so the diff is taken by
path, size and digest, and the two JSON documents §6.12 names -- the project's
`.claude/settings.local.json` and the config home's `.claude.json` -- are additionally
compared as key-path shapes, never as values. The config home belongs to a logged-in
account and its project entries carry cwds and titles; a finding that quoted them would
carry engine bytes into a committed file, which §11 forbids wherever the byte lands.

No prompt is sent by either the headless session `spike` opens or the terminal, so the whole
spike spends nothing. The declared server's command is `/usr/bin/true`: if a decline ever
fails to prevent the spawn, the thing that runs exits zero and does nothing, which is the
point of choosing it.

The terminal opens on the workspace-trust dialog, because a fresh scratch directory is one
the scratch config home has never trusted (S12 found the same gate). The driver answers it
and then the MCP dialog, matching each by the copy the parity inventory records
(`docs/tui-parity/areas/06-08-02-models-auth-bootstrap.md` for trust,
`docs/tui-parity/areas/31-27-mcp-hooks.md` §1 for `New MCP server found in this project`),
and every step records whether its pattern was actually seen -- a step that timed out is a
finding about the dialog, not a driver to silently skip.
"""
import fcntl
import hashlib
import json
import os
import pty
import re
import struct
import subprocess
import sys
import termios
import threading
import time
import uuid

SERVER_NAME = "afleet-probe-true"
ANSI = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x1b[()][A-B0-9]|\x1b[=>]|[\x00-\x08\x0b\x0c\x0e-\x1f]")
WS = re.compile(r"[ \t]+")
# Escape sequences become a space rather than nothing. This TUI positions its words with
# cursor moves instead of writing the spaces between them, so stripping the sequences to the
# empty string produces `Accessingworkspace:` and no pattern written in English matches it.

META = {"name": "spike-mcp-decline-files",
        "purpose": "C4/§6.12: decline a project .mcp.json server in the TUI and diff the project and the config home",
        "serves": [], "spikes": ["mcp-decline-files"], "census": False, "fixture": False,
        "deterministic": False, "isolation": "config-home", "launch": {"max_turns": 1},
        "prompts": [], "resume_of": None}


OBSERVE = os.environ.get("AFLEET_SPIKE_OBSERVE") == "1"


def make_project(parent):
    """A pristine project directory for one run, named after the run.

    Not the scenario's own scratch cwd. Both dialogs this spike answers are asked once per
    project and remembered afterwards -- the trust decision in the config home's
    `.claude.json`, the MCP decision wherever this spike is here to find out -- so a fixed
    path answers the question on its first run and nothing on any run after it, which is the
    same trap `control-shapes` avoids by naming its `set_cwd` sibling after the session.
    """
    project = os.path.join(parent, "project-%s" % uuid.uuid4())
    os.makedirs(project)
    with open(os.path.join(project, ".mcp.json"), "w", encoding="utf-8") as fh:
        json.dump({"mcpServers": {SERVER_NAME: {"command": "/usr/bin/true", "args": [], "env": {}}}}, fh, indent=2)
    with open(os.path.join(project, "README.md"), "w", encoding="utf-8") as fh:
        fh.write("scratch project for the mcp-decline spike\n")
    return project


def digest_tree(root):
    """{relative path: (size, sha256)} for every file under `root`, symlinks recorded as their target.

    Read-only, which is what makes it safe to point at a logged-in config home: nothing here
    creates, moves or deletes anything under either directory it walks (§4.6's closing rule).
    """
    out = {}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(filenames):
            p = os.path.join(dirpath, name)
            rel = os.path.relpath(p, root)
            if os.path.islink(p):
                out[rel] = ("symlink", os.readlink(p))
                continue
            try:
                with open(p, "rb") as fh:
                    data = fh.read()
            except OSError as e:
                out[rel] = ("unreadable", str(e))
                continue
            out[rel] = (len(data), hashlib.sha256(data).hexdigest())
    return out


def tree_diff(before, after):
    added = sorted(k for k in after if k not in before)
    removed = sorted(k for k in before if k not in after)
    changed = sorted(k for k in after if k in before and after[k] != before[k])
    return {"added": added, "removed": removed, "changed": changed}


def shapes(obj, prefix=""):
    """Key paths to type names, with every scalar value discarded.

    A list becomes its length and the set of its element types, so `disabledMcpjsonServers`
    reads as `list[str] len=1` without the name inside it reaching the finding.
    """
    out = {}
    if isinstance(obj, dict):
        for k in sorted(obj):
            out.update(shapes(obj[k], prefix + "." + k if prefix else k))
    elif isinstance(obj, list):
        kinds = sorted({type(v).__name__ for v in obj})
        out[prefix] = "list[%s] len=%d" % (",".join(kinds) or "-", len(obj))
    else:
        out[prefix] = type(obj).__name__
    return out


def read_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def shape_diff(before, after):
    """Key paths gained, lost and re-typed between two JSON documents."""
    b = shapes(before) if before is not None else {}
    a = shapes(after) if after is not None else {}
    return {"gained": sorted("%s: %s" % (k, a[k]) for k in a if k not in b),
            "lost": sorted(k for k in b if k not in a),
            "retyped": sorted("%s: %s -> %s" % (k, b[k], a[k]) for k in a if k in b and a[k] != b[k])}


def terminal_env(config_home):
    """A terminal's environment plus the scratch config home; every CLAUDE* marker dropped.

    The same rule `spike_contention` follows and for the same reason: a spike run from inside
    a Claude Code session inherits markers that change the interactive CLI's behaviour.
    """
    env = {k: v for k, v in os.environ.items() if not k.startswith("CLAUDE")}
    env["CLAUDE_CONFIG_DIR"] = config_home
    env["TERM"] = "xterm-256color"
    return env


def drive(binary, cwd, config_home, steps, idle_exit_after=6.0):
    """Run the interactive `claude` on a pty, answering `steps` as their patterns appear.

    Each step is `(label, regex, keys, timeout)`. The screen is matched with the escape
    sequences stripped, because a TUI writes its copy interleaved with cursor moves and a
    pattern that matched the raw bytes would be matching a redraw artefact.
    """
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 44, 130, 0, 0))
    proc = subprocess.Popen([binary], cwd=cwd, stdin=slave, stdout=slave, stderr=slave,
                            env=terminal_env(config_home), close_fds=True)
    os.close(slave)
    chunks = []
    lock = threading.Lock()

    def drain():
        while True:
            try:
                data = os.read(master, 65536)
            except OSError:
                return
            if not data:
                return
            with lock:
                chunks.append(data)

    t = threading.Thread(target=drain, daemon=True)
    t.start()

    def screen():
        with lock:
            raw = b"".join(chunks).decode("utf-8", "replace")
        return WS.sub(" ", ANSI.sub(" ", raw))

    log = []
    for step in steps:
        rx = re.compile(step["pattern"], re.I | re.S)
        deadline = time.time() + step["timeout"]
        seen = False
        while time.time() < deadline:
            if rx.search(screen()):
                seen = True
                break
            if proc.poll() is not None:
                break
            time.sleep(0.3)
        time.sleep(1.0)
        entry = {"step": step["label"], "pattern": step["pattern"], "seen": seen, "keys": "",
                 "child_alive": proc.poll() is None, "screen_at_match": screen()[-2500:]}
        log.append(entry)
        if seen:
            # The keys are chosen against the screen this dialog actually arrived with, not
            # against a remembered option order: a menu whose highlight starts somewhere else
            # after a baseline bump turns a blind `Enter` into the opposite answer.
            entry["keys"] = step["keys"](entry["screen_at_match"]) if callable(step["keys"]) else step["keys"]
        if not entry["keys"]:
            continue
        try:
            os.write(master, entry["keys"].encode())
        except OSError:
            entry["write_failed"] = True
        time.sleep(2.5)
        if step.get("after"):
            step["after"]()

    time.sleep(idle_exit_after)
    for keys in ("/exit\r", "\x03\x03"):
        if proc.poll() is not None:
            break
        try:
            os.write(master, keys.encode())
        except OSError:
            pass
        time.sleep(2.0)
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
    return {"exit_code": proc.returncode, "steps": log, "screen": screen()}


DECLINE_LINE = "Continue without using this MCP server"


def decline_keys(screen_at_match):
    """`Enter` only when the decline option is the one already highlighted; nothing otherwise.

    The dialog arrives with the safe option selected, so declining is a bare `Enter` and the
    arrow keys a driver would otherwise send are what could wrap the selection onto *Use this
    MCP server*. `AFLEET_SPIKE_DECLINE_KEYS` overrides the whole judgement for a baseline that
    moves the highlight; sending nothing is the third outcome and is itself the finding.
    """
    if os.environ.get("AFLEET_SPIKE_DECLINE_KEYS"):
        return os.environ["AFLEET_SPIKE_DECLINE_KEYS"]
    if OBSERVE:
        return ""
    return "\r" if re.search(r"\u276f\s*" + DECLINE_LINE, screen_at_match) else ""


def run(session, ctx):
    home, binary = ctx["config_home"], ctx["launch"].binary
    project = make_project(ctx["cwd"])
    ctx["notes"].append("binary: %s; project: %s; config home: %s" % (binary, project, home))
    ctx["notes"].append("declared server: %r command=/usr/bin/true (stdio); the project is not a "
                        "version-controlled tree, so \u00a76.12's store resolution lands the local-settings "
                        "store at the project directory itself rather than at a repository root above it"
                        % SERVER_NAME)
    ctx["notes"].append("headless session (opened by `spike` in %s, no prompt) pid %s; it never enters the project"
                        % (ctx["cwd"], session.proc.pid))

    local_settings = os.path.join(project, ".claude", "settings.local.json")
    dot_claude_json = os.path.join(home, ".claude.json")

    def snap():
        return {"project": digest_tree(project), "home": digest_tree(home),
                "local": read_json(local_settings), "dot": read_json(dot_claude_json)}

    marks = {"before": snap()}
    ctx["notes"].append("before: %d files under the project, %d under the config home; "
                        "project .claude/settings.local.json exists=%s; config home .claude.json exists=%s"
                        % (len(marks["before"]["project"]), len(marks["before"]["home"]),
                           marks["before"]["local"] is not None, marks["before"]["dot"] is not None))

    # Down then Enter at the trust dialog: the highlighted option on arrival is `No, exit`, so
    # the Enter a driver would send first closes the terminal before it reaches anything.
    steps = [{"label": "workspace trust", "pattern": r"trust this folder|Quick safety check",
              "keys": "\x1b[B\r", "timeout": 40, "after": lambda: marks.setdefault("after_trust", snap())},
             {"label": "mcp consent", "pattern": r"new MCP server[s]? found in this project",
              "keys": decline_keys, "timeout": 90, "after": lambda: marks.setdefault("after_decline", snap())}]
    driven = drive(binary, project, home, steps)
    for st in driven["steps"]:
        ctx["notes"].append("step %r: pattern seen=%s, keys sent=%r, child alive=%s%s"
                            % (st["step"], st["seen"], st["keys"], st["child_alive"],
                               " (WRITE FAILED)" if st.get("write_failed") else ""))
        if st["seen"]:
            ctx["notes"].append("  screen at %r:\n%s" % (st["step"], st["screen_at_match"]))
    ctx["notes"].append("terminal exit code: %s" % driven["exit_code"])
    marks["end"] = snap()

    order = [k for k in ("before", "after_trust", "after_decline", "end") if k in marks]
    for a, b in zip(order, order[1:]):
        ctx["notes"].append("%s -> %s  project: %s" % (a, b, json.dumps(tree_diff(marks[a]["project"], marks[b]["project"]))))
        ctx["notes"].append("%s -> %s  config home: %s" % (a, b, json.dumps(tree_diff(marks[a]["home"], marks[b]["home"]))))
        ctx["notes"].append("%s -> %s  project .claude/settings.local.json key shapes: %s"
                            % (a, b, json.dumps(shape_diff(marks[a]["local"], marks[b]["local"]))))
        pa, pb = (marks[a]["dot"] or {}), (marks[b]["dot"] or {})
        ctx["notes"].append("%s -> %s  config home .claude.json outside projects{}: %s"
                            % (a, b, json.dumps(shape_diff({k: v for k, v in pa.items() if k != "projects"},
                                                           {k: v for k, v in pb.items() if k != "projects"}))))
        key = os.path.realpath(project)
        ctx["notes"].append("%s -> %s  config home .claude.json projects[<this project>]: %s"
                            % (a, b, json.dumps(shape_diff((pa.get("projects") or {}).get(key),
                                                           (pb.get("projects") or {}).get(key)))))
    end_entry = ((marks["end"]["dot"] or {}).get("projects") or {}).get(os.path.realpath(project)) or {}
    ctx["notes"].append("at the end, the project entry's consent arrays: %s"
                        % json.dumps({k: shapes(end_entry[k], k).get(k) for k in
                                      ("enabledMcpjsonServers", "disabledMcpjsonServers", "enableAllProjectMcpServers")
                                      if k in end_entry}))
    ctx["notes"].append("at the end, the local-settings store's arrays: %s"
                        % json.dumps({k: shapes((marks["end"]["local"] or {})[k], k).get(k)
                                      for k in ("enabledMcpjsonServers", "disabledMcpjsonServers")
                                      if k in (marks["end"]["local"] or {})}))
    ctx["notes"].append("declared server name appears verbatim in the local-settings store: %s"
                        % (SERVER_NAME in json.dumps(marks["end"]["local"] or {})))
    ctx["notes"].append("terminal screen (tail):\n%s" % driven["screen"][-3000:])


def main(argv):
    """`python3 spike_mcp_decline_files.py screen <binary> <cwd> <config-home>` -- the driver alone.

    The dialog copy is the one thing this spike cannot know in advance on a new baseline; this
    entrypoint drives the terminal without the headless session so the patterns above can be
    re-read against a screen when a baseline moves.
    """
    if not argv or argv[0] != "screen":
        sys.stderr.write("usage: spike_mcp_decline_files.py screen <binary> <cwd> <config-home>\n")
        return 2
    binary, cwd, home = argv[1:4]
    out = drive(binary, cwd, home, [{"label": "observe", "pattern": r"$never^", "keys": "", "timeout": 25}])
    print(out["screen"])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
