"""C6.2 tracker 145: does `last_seen_user_message_uuid` widen what a reopened channel may rewind?

Parent §8.5 reads `rewind-turn` as saying a reopened channel cannot rewind at all: every message
older than the running process is refused with `{rewound: false, error: "stale target"}`. That
recording never sent `last_seen_user_message_uuid`, and 2.1.263 `cli.pretty.js:452145-452153`
shows the field is the whole of the difference -- the "later turn" scan starts at the *later* of
the target index and the index of the last-seen message, and the refusal text is chosen by
whether the field was supplied at all (`Ze === null ? "stale target" : "unseen later turn"`). If
supplying it can leave that scan empty, a reopened channel can rewind to an old message and
item 13's fork fallback is the rare path rather than the common one.

Three requests, one target, three values of the field:

- **omitted** -- the `rewind-turn` case, expected to be the refusal §8.5 records.
- **the transcript's last user message** -- the host claiming it has seen everything the
  session holds, which is what a reopened afleet channel can always claim truthfully.
- **the target itself** -- the host claiming it has seen nothing since the message it wants to
  rewind to, which is the honest claim of a host that has *not* caught up.

Each runs in its own `--fork-session` resume of one session picked out of the scratch config
home, so an honoured rewind lands on a disposable copy, the three cannot compound, and the
picked session's own transcript is only ever read. No prompt is sent in any of them and a
`rewind_conversation` is a control request, so the scenario spends no model turn; the forks are
closed by `end_session`. The scenario's own harness session is a bare handshake it does not use:
the contract starts one before `run()` and the measurement needs three of its own.

The forks' transcripts are read for record counts and file size on both sides of the request,
never for content, because the question an honoured rewind raises next -- does the engine
rewrite the file, or only move an anchor within it -- is answered by the shape of the change.
"""
import glob
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import harness      # noqa: E402
import redact       # noqa: E402

MIN_USER_MESSAGES = 3

META = {"name": "spike-rewind-last-seen",
        "purpose": "C6.2/145: rewind_conversation at an old message with and without last_seen_user_message_uuid",
        "serves": [], "spikes": ["C6.2"], "census": False, "fixture": False, "deterministic": False,
        "isolation": "config-home", "launch": {"max_turns": 1}, "prompts": [], "resume_of": None}


def settled_records(path, quiet=1.5, timeout=20.0):
    """The file's records once its size has held still for `quiet` seconds (as `rewind_turn`)."""
    deadline, size, since = time.time() + timeout, -1, time.time()
    while time.time() < deadline:
        now = os.path.getsize(path) if os.path.exists(path) else -1
        if now != size:
            size, since = now, time.time()
        elif time.time() - since >= quiet:
            break
        time.sleep(0.25)
    out = []
    if not os.path.exists(path):
        return out
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
    return out


def human_user_uuids(recs):
    """The uuids a rewind may target, in file order.

    The engine's own predicate (`dj`/`U3`, 2.1.263 `cli.pretty.js:795445`, `:795460`) excludes
    meta records, tool results and non-human origins; this is the same exclusion read off the
    file, so a target picked here is one the engine would also count as a user turn.
    """
    out = []
    for r in recs:
        if r.get("type") != "user" or r.get("isMeta") or r.get("isSynthetic") or not r.get("uuid"):
            continue
        if r.get("isCompactSummary") or r.get("isVisibleInTranscriptOnly"):
            continue
        content = (r.get("message") or {}).get("content")
        if isinstance(content, list) and content and content[0].get("type") == "tool_result":
            continue
        out.append(r["uuid"])
    return out


def pick_session(config_home):
    """The transcript under the config home with the most rewindable user messages.

    Read-only, and the cwd comes off the records rather than off the project directory's slug:
    the slug is the path with every separator turned into a hyphen, which no longer inverts on
    a path that itself contains one. A resume in the wrong cwd is a different project to the
    CLI, so the cwd is part of the pick and a candidate whose cwd is gone is not a candidate.
    """
    best = None
    for path in sorted(glob.glob(os.path.join(config_home, "projects", "*", "*.jsonl"))):
        recs = settled_records(path, quiet=0.0, timeout=0.0)
        users = human_user_uuids(recs)
        cwd = next((r["cwd"] for r in recs if r.get("cwd")), None)
        if len(users) < MIN_USER_MESSAGES or not cwd or not os.path.isdir(cwd):
            continue
        cand = (len(users), os.path.getmtime(path), path, cwd, users, len(recs))
        if best is None or cand[:2] > best[:2]:
            best = cand
    return best


def shape(recs):
    """Counts and nothing else: what a rewind did to a transcript, with no line of it quoted."""
    types = {}
    for r in recs:
        types[r.get("type")] = types.get(r.get("type"), 0) + 1
    leaves = [r for r in recs if r.get("type") == "last-prompt"]
    return {"records": len(recs), "by_type": types, "user_turns": len(human_user_uuids(recs)),
            "last_prompt_records": len(leaves)}


def fork_session_id(home, pid, timeout=10.0):
    """The session id the engine gave this fork, read out of the registry by pid.

    Not from `system/init`: that frame is emitted at the head of a *turn*, and this scenario
    sends no prompt, so a zero-turn session never produces one -- waiting for it found nothing
    and left every case reporting on a transcript path that could not exist. The registry
    record the CLI writes for its own process exists from the handshake on, and the pid is the
    one thing the harness already knows about the child.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        for f in sorted(glob.glob(os.path.join(home, "sessions", "*.json"))):
            try:
                with open(f, encoding="utf-8") as fh:
                    d = json.load(fh)
            except (ValueError, OSError):
                continue
            if d.get("pid") == pid and d.get("sessionId"):
                return d["sessionId"]
        time.sleep(0.25)
    return None


def one_fork(ctx, binary, cwd, home, project_dir, sid, label, target, last_seen):
    """One fork, one `rewind_conversation`, and the fork transcript on both sides of it.

    The fork's transcript is its new session id inside the *picked* session's project
    directory: a fork runs in the same cwd, so the CLI's slug -- and the directory -- is the
    same one, and nothing has to invert the slug to find it.
    """
    payload = {"target_message_uuid": target}
    if last_seen is not None:
        payload["last_seen_user_message_uuid"] = last_seen
    session = harness.Session(harness.Launch(binary=binary, cwd=cwd, config_home=home, resume=sid,
                                             fork=True, max_turns=1), redact.Redactor())
    session.start(timeout=60)
    if session.proc is None:
        raise RuntimeError("session.start() returned without launching a process")
    fork_sid = fork_session_id(home, session.proc.pid)
    fork_path = os.path.join(project_dir, (fork_sid or "no-such-session") + ".jsonl")
    try:
        ctx["notes"].append("--- %s: fork of the picked session, request keys %s; fork is a new session: %s"
                            % (label, sorted(payload), bool(fork_sid) and fork_sid != sid))
        before = settled_records(fork_path) if os.path.exists(fork_path) else []
        size_before = os.path.getsize(fork_path) if os.path.exists(fork_path) else None
        ctx["notes"].append("  fork transcript (%s) before the request: exists %s, %s, %s bytes"
                            % ("resolved" if fork_sid else "UNRESOLVED session id",
                               os.path.exists(fork_path), shape(before), size_before))
        resp = session.request("rewind_conversation", timeout=60, **payload)
        body = resp.get("response") if resp.get("subtype") == "success" else resp.get("error")
        ctx["notes"].append("  envelope %s, body %s"
                            % (resp.get("subtype"), json.dumps(body) if isinstance(body, dict) else str(body)[:300]))
        after = settled_records(fork_path) if os.path.exists(fork_path) else []
        size_after = os.path.getsize(fork_path) if os.path.exists(fork_path) else None
        ctx["notes"].append("  fork transcript after the request: exists %s, %s, %s bytes"
                            % (os.path.exists(fork_path), shape(after), size_after))
        ctx["notes"].append("  transcript changed: size %s, records %s"
                            % (size_before != size_after, len(before) != len(after)))
    finally:
        session.close()


def run(_session, ctx):
    home = ctx["config_home"]
    binary = ctx["launch"].binary
    picked = pick_session(home)
    if picked is None:
        ctx["notes"].append("no transcript under the config home has %d rewindable user messages in a cwd that "
                            "still exists; nothing measured (a session is not created here: that would cost a turn)"
                            % MIN_USER_MESSAGES)
        return
    count, _, path, cwd, users, records = picked
    sid = os.path.basename(path)[:-len(".jsonl")]
    ctx["notes"].append("picked a session with %d user turns in %d records, cwd exists; resumed with --fork-session "
                        "three times, once per request" % (count, records))
    ctx["notes"].append("target is user turn 2 of %d; the last-seen value in case (b) is user turn %d"
                        % (count, count))
    target, last = users[1], users[-1]
    project_dir = os.path.dirname(path)
    # The picked session is evidence the scenario borrowed and must hand back untouched, so its
    # own file and the set of files beside it are measured across the whole run: a fork that
    # wrote into the original, or an honoured rewind that rewrote it, shows up here and nowhere
    # else -- the forks report only on themselves.
    origin_before = (os.path.getsize(path), len(settled_records(path, quiet=0.0, timeout=0.0)))
    siblings_before = set(glob.glob(os.path.join(project_dir, "*.jsonl")))
    for label, last_seen in (("(a) no last_seen_user_message_uuid", None),
                             ("(b) last_seen = the transcript's last user message", last),
                             ("(c) last_seen = the target itself", target)):
        one_fork(ctx, binary, cwd, home, project_dir, sid, label, target, last_seen)
    origin_after = (os.path.getsize(path), len(settled_records(path, quiet=0.0, timeout=0.0)))
    ctx["notes"].append("the picked session's own transcript across the three forks: %s bytes/%s records before, "
                        "%s/%s after; unchanged: %s"
                        % (origin_before + origin_after + (origin_before == origin_after,)))
    ctx["notes"].append("transcript files that appeared beside it during the run: %d"
                        % len(set(glob.glob(os.path.join(project_dir, "*.jsonl"))) - siblings_before))
    ctx["notes"].append("the scenario's own harness session was a bare handshake; no prompt was sent anywhere")
