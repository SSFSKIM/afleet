#!/usr/bin/env python3
"""fake-claude: replay a fixture reactively; duplex scripts; safe materialisation (spec §4.8)."""
import json
import os
import re
import sys
import threading
import time

MARKER = ".afleet-fake-home"
SLUG_TOKEN = "_slug_"
ARTIFACT_TOKEN = "<artifacts>"
EXIT_REFUSED = 2
EXIT_UNEXPECTED = 3
# The file `probe`'s `write_fixture` drops into a fixture directory that would otherwise be
# empty, so git carries the directory. It is not a stream and not an artifact, and both the
# materialiser and the final-state comparison have to look past it.
PLACEHOLDER = ".gitkeep"


def slug_of(cwd):
    """The project slug the CLI derives from a working directory; resolved first, because the
    CLI slugs the path it resolved to. `/tmp` is a symlink to `/private/tmp` on macOS, so an
    unresolved cwd yields a slug no real session ever wrote under."""
    return re.sub(r"[^A-Za-z0-9]", "-", os.path.realpath(cwd))


def _read_json(path):
    with open(path) as fh:
        return json.load(fh)


def load_fixture(d):
    meta = _read_json(os.path.join(d, "fixture.json"))
    with open(os.path.join(d, "frames.ndjson")) as fh:
        frames = [json.loads(l) for l in fh if l.strip()]
    cen = _read_json(os.path.join(d, "census.json"))
    streams = _read_json(os.path.join(d, "streams.json"))
    return meta, frames, cen, streams


def dumps(obj):
    return json.dumps(obj, separators=(",", ":"), ensure_ascii=False)


# ---------------------------------------------------------------- materialise
def _real(p):
    return os.path.realpath(os.path.expanduser(p))


def _within(child, parent):
    child, parent = _real(child), _real(parent)
    return child == parent or child.startswith(parent.rstrip("/") + "/")


def _forbidden_home(dest, env):
    """The real config home `dest` resolves into, or None. Nothing under Tools/ may write there."""
    homes = [os.path.expanduser("~/.claude")]
    if env.get("CLAUDE_CONFIG_DIR"):
        homes.append(env["CLAUDE_CONFIG_DIR"])
    for home in homes:
        if _within(dest, home):
            return home
    return None


def _marker_reason(dest):
    """Why `dest` is not a directory fake-claude created and marked, or None."""
    marker = os.path.join(_real(dest), MARKER)
    if os.path.islink(marker):
        return "%s carries a %s that is a symlink, not a marker fake-claude wrote" % (dest, MARKER)
    if not os.path.isfile(marker):
        return "%s is missing the %s marker" % (dest, MARKER)
    return None


def refusal_reason(dest, session_id, env=None):
    """Why `materialize` must not write into `dest`, or None."""
    env = os.environ if env is None else env
    home = _forbidden_home(dest, env)
    if home:
        return "%s resolves into the config home %s" % (dest, home)
    real = _real(dest)
    if os.path.lexists(dest) or os.path.exists(real):
        if not os.path.isdir(real):
            return "%s exists and is not a directory" % dest
        reason = _marker_reason(dest)
        if reason:
            return reason
        for root, _, files in os.walk(os.path.join(real, "projects")):
            if session_id + ".jsonl" in files:
                return "%s already holds a transcript for %s" % (dest, session_id)
    return None


def replay_home_reason(home, env=None):
    """Why replay must not append into `home`, or None. Replay never creates the home itself."""
    env = os.environ if env is None else env
    forbidden = _forbidden_home(home, env)
    if forbidden:
        return "%s resolves into the config home %s" % (home, forbidden)
    return _marker_reason(home)


def safe_path(root, rel):
    """A destination under root whose every component below root is a real directory, never a symlink;
    refused (returns None) when a component is a symlink or the resolved path leaves root."""
    root = _real(root)
    cur = root
    parts = [p for p in rel.split(os.sep) if p not in ("", ".")]
    if any(p == ".." for p in parts):
        return None
    for part in parts[:-1]:
        cur = os.path.join(cur, part)
        if os.path.islink(cur):
            return None
        if os.path.exists(cur) and not os.path.isdir(cur):
            return None
    final = os.path.join(cur, parts[-1]) if parts else cur
    if os.path.islink(final) or not _within(final, root):
        return None
    return final


def _open_new(path, mode):
    """open() that never follows a symlink at the leaf."""
    flags = os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | (os.O_APPEND if "a" in mode else 0) | (os.O_TRUNC if "w" in mode else 0)
    return os.fdopen(os.open(path, flags, 0o600), mode)


def _create_new(path, mode):
    """Create the leaf, or refuse. The other half of the containment `safe_path` starts.

    `safe_path` rejects a symlink, but a *hard* link is not a path -- it is a second name for
    an inode, and every canonical-path check still sees a file under the fake root. A
    pre-existing leaf inside a marked home can therefore be a second name for a file in a real
    `~/.claude`, and opening it `O_TRUNC` writes straight through to it. `O_EXCL` is the test
    that cannot be fooled by a name: a new inode or nothing.
    """
    return os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), mode)


def _open_existing(path, mode):
    """Open a leaf that must already exist, without following a symlink and without truncating."""
    flags = (os.O_RDWR if "+" in mode else os.O_WRONLY) | os.O_NOFOLLOW | (os.O_APPEND if "a" in mode else 0)
    return os.fdopen(os.open(path, flags), mode)


def _refuse_shared_inode(fh, what):
    """Refuse a file that has more than one name, once it is already open.

    For the appends, where the leaf legitimately exists and `O_EXCL` cannot be used. The check
    is on the open descriptor rather than on the path, so nothing can be swapped underneath it
    between the test and the write.
    """
    if os.fstat(fh.fileno()).st_nlink != 1:
        fh.close()
        raise RuntimeError("refusing to write %s: the file has more than one link, so it may be a second "
                           "name for an inode outside the fake home" % what)
    return fh


def _rewrite_text(text, meta, cwd, real_home):
    slug = slug_of(cwd)
    text = text.replace(SLUG_TOKEN, slug)
    if meta.get("cwd"):
        text = text.replace(meta["cwd"], cwd)
    return text.replace(ARTIFACT_TOKEN, os.path.join(real_home, "tasks"))


def rewrite_paths(text, meta, cwd, home):
    """Rewrite recorded text for a replay: the `_slug_` token, the recorded cwd, the `<artifacts>`
    token, and the root standing in front of `/projects/<recorded slug>/`, which becomes the fake
    home's. That root is whatever config home the recording ran under — `~/.claude` is one such
    root, not the only one, since recordings are made under a scratch `CLAUDE_CONFIG_DIR` (§4.6)
    and redaction leaves a synthetic scratch path alone (§4.5 rule 3)."""
    text = _rewrite_text(text, meta, cwd, home)
    if meta.get("cwd"):
        root = os.path.join(home, "projects", slug_of(cwd)) + "/"
        text = re.sub(r'[^"\s\\]*/projects/%s/' % re.escape(slug_of(meta["cwd"])), lambda m: root, text)
    return text


def initial_bytes(fixture_dir, stream, meta, cwd, real_home):
    """The bytes materialize lays down for one `initial/` stream, or None when it has none."""
    src = os.path.join(fixture_dir, "initial", stream)
    if not os.path.isfile(src):
        return None
    with open(src, "rb") as fh:
        data = fh.read()
    try:
        return _rewrite_text(data.decode("utf-8"), meta, cwd, real_home).encode("utf-8")
    except UnicodeDecodeError:
        return data


def materialize(fixture_dir, config_home, cwd, env=None, stderr=sys.stderr):
    meta, _, _, _ = load_fixture(fixture_dir)
    reason = refusal_reason(config_home, meta["session_id"], env)
    if reason:
        stderr.write("fake-claude: refusing to materialize: %s\n" % reason)
        return EXIT_REFUSED
    real = _real(config_home)
    os.makedirs(real, exist_ok=True)
    with _open_new(os.path.join(real, MARKER), "a") as marker:
        _refuse_shared_inode(marker, MARKER)
    initial = os.path.join(fixture_dir, "initial")
    for root, _, files in os.walk(initial):
        for f in files:
            if f == PLACEHOLDER:
                continue
            stream = os.path.relpath(os.path.join(root, f), initial)
            rel = stream.replace(SLUG_TOKEN, slug_of(cwd))
            dst = safe_path(real, os.path.join("projects", rel))
            if dst is None:
                stderr.write("fake-claude: refusing to write through a symlink or outside the fake home: projects/%s\n" % rel)
                return EXIT_REFUSED
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            try:
                with _create_new(dst, "wb") as b:
                    b.write(initial_bytes(fixture_dir, stream, meta, cwd, real))
            except FileExistsError:
                stderr.write("fake-claude: refusing to materialize onto an existing file, which may be a "
                             "hard link out of the fake home: projects/%s\n" % rel)
                return EXIT_REFUSED
    return 0


def rel_files(base):
    """Every file beneath `base`, as paths relative to it."""
    return set(os.path.relpath(os.path.join(root, f), base)
               for root, _, files in os.walk(base) for f in files if f != PLACEHOLDER)


def compare_final_state(fixture_dir, config_home, cwd):
    """Records per line for transcript files, bytes for artifacts, and nothing else beneath the
    fake home's projects/ and tasks/. Returns (ok, report)."""
    meta, _, _, _ = load_fixture(fixture_dir)
    real, report, ok = _real(config_home), [], True
    tdir, adir = os.path.join(fixture_dir, "transcript"), os.path.join(fixture_dir, "artifacts")
    pdir, kdir = os.path.join(real, "projects"), os.path.join(real, "tasks")
    for rel in sorted(rel_files(tdir)):
        with open(os.path.join(tdir, rel)) as fh:
            want = [json.loads(rewrite_paths(l, meta, cwd, real)) for l in fh if l.strip()]
        dst = os.path.join(pdir, rel.replace(SLUG_TOKEN, slug_of(cwd)))
        got = None
        if os.path.isfile(dst):
            with open(dst) as fh:
                got = [json.loads(l) for l in fh if l.strip()]
        if got != want:
            ok = False; report.append("transcript %s differs (%s vs %s records)" % (rel, None if got is None else len(got), len(want)))
    for rel in sorted(rel_files(adir)):
        with open(os.path.join(adir, rel), "rb") as fh:
            want_bytes = fh.read()
        got_bytes = None
        if os.path.isfile(os.path.join(kdir, rel)):
            with open(os.path.join(kdir, rel), "rb") as fh:
                got_bytes = fh.read()
        if got_bytes != want_bytes:
            ok = False; report.append("artifact %s differs" % rel)
    expected = set(os.path.join("projects", r.replace(SLUG_TOKEN, slug_of(cwd))) for r in rel_files(tdir))
    expected |= set(os.path.join("tasks", r) for r in rel_files(adir))
    expected.add(MARKER)
    for rel in sorted(rel_files(real) - expected):
        ok = False; report.append("%s is under the fake home but not in the fixture" % rel)
    return ok, "\n".join(report)


# ---------------------------------------------------------------- replay
def _get(frame, dotted):
    cur = frame
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur


class Replayer:
    def __init__(self, fixture_dir, env, stdin, stdout, stderr):
        self.env, self.stdin, self.stdout, self.stderr = env, stdin, stdout, stderr
        self.meta, self.frames, self.census, self.streams = load_fixture(fixture_dir)
        self.fixture_dir = fixture_dir
        self.speed = float(env.get("FAKE_CLAUDE_SPEED", "1") or "1")
        self.script = _read_json(env["FAKE_CLAUDE_SCRIPT"]) if env.get("FAKE_CLAUDE_SCRIPT") else []
        self.rules = {s for step in self.script if step.get("rule") == "generic-success" for s in step.get("subtypes", [])}
        self.patches = [s for s in self.script if "patch" in s]
        self.steps = [s for s in self.script if "rule" not in s and "patch" not in s]
        self.init_override = _read_json(env["FAKE_CLAUDE_INIT"]) if env.get("FAKE_CLAUDE_INIT") else None
        self.home = _real(env["FAKE_CLAUDE_CONFIG_HOME"]) if env.get("FAKE_CLAUDE_CONFIG_HOME") else None
        self.cwd = env.get("FAKE_CLAUDE_CWD") or os.getcwd()
        self.inbox, self.cond, self.eof = [], threading.Condition(), False
        self.last_request_id = None
        self.init_request_id = None      # the recording's own id for its initialize request
        self.out_index = 0
        self.started = set()            # real stream paths already positioned at their append start
        self.missing_artifacts = set()  # artifact paths already reported absent, so each is said once

    # ---- io
    def emit(self, frame):
        try:
            if self.home:
                frame = self._rewrite_frame(frame)
            if self.home and frame.get("type") == "transcript_mirror":
                self._append_mirror(frame)
        except RuntimeError as e:                       # a symlink appeared under the fake home: stop before writing
            self.stderr.write("fake-claude: %s\n" % e); self.stderr.flush()
            raise SystemExit(EXIT_REFUSED)
        self.stdout.write(dumps(frame) + "\n"); self.stdout.flush()
        if frame.get("type") == "control_request":
            self.last_request_id = frame.get("request_id")
        self.out_index += 1

    def _reader(self):
        for line in self.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                f = json.loads(line)
            except ValueError:
                continue
            with self.cond:
                self.inbox.append(f); self.cond.notify_all()
        with self.cond:
            self.eof = True; self.cond.notify_all()

    def take(self, pred, timeout):
        """Remove and return the first inbox frame matching pred, or None on timeout/eof."""
        deadline = None if timeout is None else time.time() + timeout
        with self.cond:
            while True:
                for i, f in enumerate(self.inbox):
                    if pred(f):
                        return self.inbox.pop(i)
                if self.eof:
                    return None
                rem = None if deadline is None else deadline - time.time()
                if rem is not None and rem <= 0:
                    return None
                self.cond.wait(rem if rem is not None else 0.5)

    def fail(self, msg):
        self.stderr.write("fake-claude: %s\n" % msg); self.stderr.flush()
        return EXIT_UNEXPECTED

    # ---- filesystem
    def _rewrite_frame(self, frame):
        frame = json.loads(rewrite_paths(dumps(frame), self.meta, self.cwd, self.home))
        for s in self._artifact_paths(frame):
            self._write_artifact(s)
        return frame

    def _artifact_paths(self, obj):
        prefix = os.path.join(self.home, "tasks") + "/"
        if isinstance(obj, dict):
            for v in obj.values():
                for s in self._artifact_paths(v):
                    yield s
        elif isinstance(obj, list):
            for v in obj:
                for s in self._artifact_paths(v):
                    yield s
        elif isinstance(obj, str) and obj.startswith(prefix):
            yield obj

    def _write_artifact(self, path):
        rel = os.path.relpath(path, os.path.join(self.home, "tasks"))
        src = os.path.join(self.fixture_dir, "artifacts", rel)     # artifacts/ keeps the recorded task-root layout
        dst = safe_path(self.home, os.path.join("tasks", rel))
        if dst is None:
            raise RuntimeError("refusing to write artifact through a symlink: tasks/%s" % rel)
        if not os.path.isfile(src):
            if rel not in self.missing_artifacts:
                self.missing_artifacts.add(rel)
                self.stderr.write("fake-claude: frame names an artifact the fixture does not hold: artifacts/%s\n" % rel)
                self.stderr.flush()
        elif not os.path.exists(dst):
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            with open(src, "rb") as a, _create_new(dst, "wb") as b:
                b.write(a.read())

    def _stream_start(self, stream):
        """Where this stream's recorded appends begin on disk. streams.json holds the recorded
        offset; when materialize laid the stream down it rewrote the slug and the cwd inside it,
        so the bytes it wrote — not the recorded offset — are where the appends now start."""
        data = initial_bytes(self.fixture_dir, stream, self.meta, self.cwd, self.home)
        return self.streams.get(stream, 0) if data is None else len(data)

    def _append_mirror(self, frame):
        rel = os.path.relpath(frame["filePath"], os.path.join(self.home, "projects"))
        path = safe_path(self.home, os.path.join("projects", rel))
        if path is None:
            raise RuntimeError("refusing to append through a symlink: projects/%s" % rel)
        stream = rel.replace(slug_of(self.cwd), SLUG_TOKEN, 1)
        if path not in self.started:
            self.started.add(path)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            if not os.path.exists(path):
                with _create_new(path, "ab"):
                    pass
            start = self._stream_start(stream)
            if start > os.path.getsize(path):
                raise RuntimeError("stream %s holds %d bytes but its appends start at %d: materialize this fixture into the fake home first"
                                   % (stream, os.path.getsize(path), start))
            # `open(path, "r+b")` followed a symlink and truncated whatever it found; the
            # no-follow open and the link count together keep the truncation inside the fake
            # home even when the leaf was laid down by something other than materialize.
            with _refuse_shared_inode(_open_existing(path, "r+b"), "projects/" + rel) as fh:
                fh.truncate(start)
        with _refuse_shared_inode(_open_existing(path, "ab"), "projects/" + rel) as fh:
            for entry in frame.get("entries", []):
                fh.write((dumps(entry) + "\n").encode("utf-8"))

    # ---- script
    def _due(self, step, next_t):
        if "after" in step:
            return next_t is None or self.out_index > step["after"]
        if "at" in step:
            return next_t is None or step["at"] <= next_t
        return True

    def _run_script(self, next_t):
        """Run the script as a sequential state machine: an emit step waits for its position (time or
        index); expect and answer steps run as soon as they are reached, wherever they sit."""
        while self.steps:
            s = self.steps[0]
            if "emit" in s:
                if not self._due(s, next_t):
                    return None
                self.steps.pop(0); self.emit(s["emit"]); continue
            self.steps.pop(0)
            if "expect" in s:
                got = self.take(lambda f: self._matches(f, s["expect"]), (s.get("timeout_ms", 5000)) / 1000.0)
                if got is None:
                    return self.fail("expect timed out: %s" % dumps(s["expect"]))
                self._last_matched = got
            elif "answer" in s:
                ans = json.loads(dumps(s["answer"]))
                if ans.get("type") == "control_response" and getattr(self, "_last_matched", {}).get("type") == "control_request":
                    ans.setdefault("response", {})["request_id"] = self._last_matched["request_id"]
                self.emit(ans)
        return None

    def _matches(self, frame, matcher):
        for k, v in matcher.items():
            if k == "request_id":
                want = self.last_request_id if v == "$last" else v
                got = frame.get("request_id") or (frame.get("response") or {}).get("request_id")
                if got != want:
                    return False
            elif _get(frame, k) != v:
                return False
        return True

    # ---- recorded host inputs
    def _input_pred(self, want):
        """What a host frame has to look like to be the one this recorded `in` line stands for."""
        t = want.get("type")
        if t == "control_response":
            rid = want["response"]["request_id"]
            return lambda f: f.get("type") == "control_response" and (f.get("response") or {}).get("request_id") == rid
        if t == "user":
            return lambda f: f.get("type") == "user"
        if t == "control_request":
            sub = want["request"]["subtype"]
            return lambda f: f.get("type") == "control_request" and f.get("request_id") and (f.get("request") or {}).get("subtype") == sub
        return lambda f: f.get("type") == t

    @staticmethod
    def _is_end_session(frame):
        return frame.get("type") == "control_request" and (frame.get("request") or {}).get("subtype") == "end_session"

    def _wait_recorded_input(self, rec, later):
        """Wait for the host frame this recorded `in` line stands for.

        The recording's order *among host frames* is not an order the host has to reproduce.
        A reply the host owes one of our out frames and a request the host's own caller makes
        come from two different threads, so either can reach us first however the recording
        happened to interleave them. A frame that some later recorded `in` line is still
        waiting for is therefore left in the inbox for that line to claim, rather than judged
        unexpected here; only a frame no remaining line accounts for is unexpected. An
        `end_session` is the exception: the host asking to stop is answered whenever it comes.
        """
        want = rec["frame"]
        pred = self._input_pred(want)
        deferred = [self._input_pred(r["frame"]) for r in later]
        while True:
            got = self.take(lambda f: pred(f) or self._is_end_session(f) or not any(p(f) for p in deferred), None)
            if got is None:
                return None, None
            if pred(got):
                if want.get("type") == "user":
                    self._note_user_text(want, got)
                return got, want
            code = self._handle_unexpected(got)
            if code is not None:
                return code, None

    def _note_user_text(self, want, got):
        """A user frame matches on type alone, so a host driving a different prompt than the
        recording still replays; §4.8 asks for the difference on stderr so a caller can see it."""
        recorded, sent = _get(want, "message.content"), _get(got, "message.content")
        if recorded != sent:
            self.stderr.write("fake-claude: user text differs from the recording: sent %s, recorded %s\n"
                              % (dumps(sent)[:200], dumps(recorded)[:200]))
            self.stderr.flush()

    def _handle_unexpected(self, frame):
        sub = (frame.get("request") or {}).get("subtype")
        rid = frame.get("request_id")
        if frame.get("type") == "control_request" and rid and sub in self.rules:
            self.emit({"type": "control_response", "response": {"subtype": "success", "request_id": rid, "response": {}}})
            return None
        if frame.get("type") == "control_request" and rid and sub == "end_session":
            self.emit({"type": "control_response", "response": {"subtype": "success", "request_id": rid, "response": {}}})
            return 0
        return self.fail("unexpected host frame: %s" % dumps(frame)[:300])

    def run(self):
        threading.Thread(target=self._reader, daemon=True).start()
        i, prev_t, pending_id_map = 0, 0, {}
        while i < len(self.frames):
            rec = self.frames[i]
            if "dropped" in rec:
                i += 1; continue
            code = self._run_script(rec["t"])                        # script steps run around every line, in or out
            if code is not None:
                return code
            if rec["dir"] == "in":
                later = [r for r in self.frames[i + 1:] if r.get("dir") == "in" and "dropped" not in r]
                got, want = self._wait_recorded_input(rec, later)
                if isinstance(got, int):
                    return got
                if got is None:
                    return 0                                             # stdin closed mid-replay: exit like the CLI
                if want.get("type") == "control_request":                 # host request: remember its real id
                    pending_id_map[want["request_id"]] = got["request_id"]
                    if want["request"]["subtype"] == "initialize":
                        self.init_request_id = want["request_id"]
                prev_t = rec["t"]; i += 1; continue
            delay = (rec["t"] - prev_t) / 1000.0
            if self.speed > 0 and delay > 0:
                time.sleep(delay / self.speed)
            frame = json.loads(dumps(rec["frame"]))
            for patch in self.patches:                                   # {"patch": {matcher}, "remove": [keys]} strips keys from matching out frames
                if self._matches(frame, patch["patch"]):
                    for k in patch.get("remove", []):
                        frame.pop(k, None)
            if frame.get("type") == "control_response":
                rid = frame["response"].get("request_id")
                if rid in pending_id_map:
                    frame["response"]["request_id"] = pending_id_map[rid]
                if self.init_override and rid is not None and rid == self.init_request_id:
                    frame["response"]["response"] = self.init_override
            self.emit(frame)
            prev_t = rec["t"]; i += 1
        code = self._run_script(None)
        if code is not None:
            return code
        while True:                                                       # after the last line: wait for close or end_session
            got = self.take(lambda f: True, None)
            if got is None:
                return 0
            code = self._handle_unexpected(got)
            if code is not None:
                return code


def print_help(cen, out):
    out.write("Usage: claude [options] [command] [prompt]\n\nOptions:\n")
    for flag in cen.get("flags") or []:      # census.py writes null, not [], when `claude --help` was never captured
        out.write("  %s\n" % flag)


def main(argv=None, env=None, stdin=sys.stdin, stdout=sys.stdout, stderr=sys.stderr):
    argv = sys.argv[1:] if argv is None else argv
    env = os.environ if env is None else env
    if argv[:1] == ["materialize"]:
        rest = argv[3:]
        if len(argv) < 3 or (rest and (rest[0] != "--cwd" or len(rest) != 2)):
            stderr.write("usage: fake-claude materialize <fixture> <configHome> [--cwd <path>]\n"); return EXIT_REFUSED
        return materialize(argv[1], argv[2], rest[1] if rest else os.getcwd(), env, stderr)
    fixture_dir = env.get("FAKE_CLAUDE_FIXTURE")
    if "--version" in argv:
        v = env.get("FAKE_CLAUDE_VERSION") or (load_fixture(fixture_dir)[0].get("cli_version") if fixture_dir else "0.0.0")
        stdout.write("%s (Claude Code)\n" % v); return 0
    if "--help" in argv:
        print_help(load_fixture(fixture_dir)[2] if fixture_dir else {"flags": []}, stdout); return 0
    if not fixture_dir:
        stderr.write("fake-claude: FAKE_CLAUDE_FIXTURE is not set\n"); return EXIT_REFUSED
    if env.get("FAKE_CLAUDE_CONFIG_HOME"):
        reason = replay_home_reason(env["FAKE_CLAUDE_CONFIG_HOME"], env)
        if reason:
            stderr.write("fake-claude: refusing to replay into a fake home: %s\n" % reason); return EXIT_REFUSED
    return Replayer(fixture_dir, env, stdin, stdout, stderr).run()


if __name__ == "__main__":
    sys.exit(main())
