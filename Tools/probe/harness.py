"""Launch line, redact-then-capture, control correlation, answer policies, MCP mini-server (spec §4.3)."""
import json
import os
import signal
import subprocess
import tempfile
import threading
import time
import uuid
import warnings
from dataclasses import dataclass, field

VERSION = "0.1"
SCRATCH_CONFIG_HOME = "/tmp/afleet-fixtures/config-home"
DEFAULT_ENV_TABLE = {
    "CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING": "1",
    "CLAUDE_AUTO_BACKGROUND_TASKS": "1",
    "CLAUDE_CODE_DISABLE_NOTIFICATION_PRESENCE_CHECK": "1",
    "CLAUDE_CODE_FORK_SUBAGENT": "1",
}
FORBIDDEN_ENV = ("CLAUDE_CODE_REMOTE", "CLAUDE_CODE_CONTAINER_ID", "CLAUDE_CODE_ENTRYPOINT")
INITIALIZE = {
    "subtype": "initialize",
    "supportedDialogKinds": ["refusal_fallback_prompt", "fable_overage_consent_prompt"],
    "perTaskStopAffordance": True,
    "agentProgressSummaries": True,
    "sdkMcpServers": ["afleet"],
    "sdkMcpServerConfigs": {"afleet": {}},
    "hooks": {"Notification": [{"hookCallbackIds": ["afleet.notification"]}],
              "ConfigChange": [{"hookCallbackIds": ["afleet.config-change"]}]},
}
SEND_USER_FILE_TOOL = {
    "name": "send_user_file",
    "description": "Send one or more files to the user.",
    "inputSchema": {"type": "object",
                    "properties": {"files": {"type": "array", "items": {"type": "string"}},
                                   "caption": {"type": "string"},
                                   "status": {"type": "string", "enum": ["normal", "proactive"]},
                                   "display": {"type": "string", "enum": ["render", "attach"]}},
                    "required": ["files", "status"]},
}
# Above this length an all-letter host name stops behaving like a word one meets in prose.
HOSTNAME_WORD_LIMIT = 8


def word_shaped_hostname(hostname):
    """Would substituting this host name rewrite ordinary words as well as host names?

    The redactor replaces every occurrence of the recording machine's name with `<host>`
    as plain text, so a name that reads like an English word rewrites that word wherever
    it appears -- a machine called `dev` turns `developer` into `<host>eloper` throughout
    the fixture, and only a careful human reader would notice. A digit, a hyphen or a
    capital anywhere in the name rules the collision out, which is what almost every real
    host name has; names of two characters or fewer are safe because the redactor already
    declines to substitute them.
    """
    short = (hostname or "").split(".")[0]
    return 2 < len(short) <= HOSTNAME_WORD_LIMIT and short.isascii() and short.isalpha() and short.islower()


def check_recording_hostname(hostname):
    """Warn -- never fail -- when the recording host name is word-shaped. The recording is
    still valid evidence and nothing about redaction changes; what changes is that its
    prose needs reading before the fixture is committed."""
    if word_shaped_hostname(hostname):
        warnings.warn("recording host name %r reads like an ordinary word: redaction replaces every occurrence "
                      "of it with <host>, so words containing it will be rewritten throughout the fixture. "
                      "Read the fixture text before committing it, or record under a qualified host name." % hostname)


@dataclass
class Launch:
    binary: str = "claude"
    binary_args: list = field(default_factory=list)   # placed right after binary (tests use it for the stand-in script)
    cwd: str = "."
    session_id: str = None
    resume: str = None
    fork: bool = False
    model: str = "haiku"
    permission_mode: str = "default"
    agent: str = None
    effort: str = None
    name: str = None
    add_dirs: list = field(default_factory=list)
    worktree: str = None              # None | "" (bare -w) | "<name>"
    allow_bypass: bool = False
    prompt_suggestions: bool = False
    setting_sources: str = ""         # None = omit the flag; "" = --setting-sources ""
    strict_mcp_config: bool = True
    max_turns: int = None
    extra_flags: list = field(default_factory=list)
    env_table: dict = field(default_factory=lambda: dict(DEFAULT_ENV_TABLE))
    config_home: str = SCRATCH_CONFIG_HOME   # None = inherit the real one

    def argv(self):
        a = [self.binary] + list(self.binary_args) + [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--replay-user-messages", "--forward-subagent-text", "--include-hook-events",
            "--permission-prompt-tool", "stdio", "--permission-prompts", "host"]
        if self.resume:
            a += ["--resume", self.resume] + (["--fork-session"] if self.fork else [])
        elif self.session_id:
            a += ["--session-id", self.session_id]
        for flag, val in (("--model", self.model), ("--permission-mode", self.permission_mode), ("--agent", self.agent),
                          ("--effort", self.effort), ("-n", self.name)):
            if val:
                a += [flag, val]
        for d in self.add_dirs:
            a += ["--add-dir", d]
        if self.worktree is not None:
            a += ["-w"] + ([self.worktree] if self.worktree else [])
        if self.allow_bypass:
            a += ["--allow-dangerously-skip-permissions"]
        a += ["--enable-auth-status", "--session-mirror"]
        if self.prompt_suggestions:
            a += ["--prompt-suggestions", "true"]
        if self.setting_sources is not None:
            a += ["--setting-sources", self.setting_sources]
        if self.strict_mcp_config:
            a += ["--strict-mcp-config"]
        if self.max_turns is not None:
            a += ["--max-turns", str(self.max_turns)]
        a += list(self.extra_flags)
        # Checked over the whole line, not just `extra_flags`: the CLI takes the last
        # occurrence, so a second `--permission-prompt-tool` anywhere -- in `extra_flags`
        # or in `binary_args` -- silently disarms the one this method just wrote, and
        # without the literal `stdio` every permission ask in the recording is denied
        # (parent §6.1).
        at = [i for i, x in enumerate(a) if x == "--permission-prompt-tool"]
        if not at or a[at[-1] + 1:at[-1] + 2] != ["stdio"]:
            raise ValueError("the launch line must keep --permission-prompt-tool stdio")
        return a

    def environment(self, base=None):
        env = dict(os.environ if base is None else base)
        for k in FORBIDDEN_ENV:
            env.pop(k, None)
        env.update(self.env_table)
        if self.config_home:
            env["CLAUDE_CONFIG_DIR"] = self.config_home
        return env


class MCPServer:
    """Minimal JSON-RPC 2.0 server for the in-process `afleet` MCP server."""
    def __init__(self, cwd, tools=None):
        self.cwd = cwd
        self.tools = tools or [SEND_USER_FILE_TOOL]
        self.calls = []

    def handle(self, msg):
        method, mid = msg.get("method"), msg.get("id")
        if "id" not in msg:                      # notification
            return {"jsonrpc": "2.0", "result": {}, "id": 0}
        if method == "initialize":
            return {"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                                                            "serverInfo": {"name": "afleet", "version": VERSION}}}
        if method == "ping":
            return {"jsonrpc": "2.0", "id": mid, "result": {}}
        if method == "tools/list":
            return {"jsonrpc": "2.0", "id": mid, "result": {"tools": self.tools}}
        if method == "tools/call":
            params = msg.get("params") or {}
            if params.get("name") != "send_user_file":
                return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32602, "message": "unknown tool %s" % params.get("name")}}
            args = params.get("arguments") or {}
            files = args.get("files") or []
            missing = [f for f in files if not os.path.isfile(os.path.join(self.cwd, f))]
            self.calls.append(args)
            if missing:
                return {"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": "missing: %s" % ", ".join(missing)}], "isError": True}}
            text = "sent %d file(s) to the user: %s" % (len(files), ", ".join(files))
            if args.get("caption"):
                text += " (caption: %s)" % args["caption"]
            return {"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": text}]}}
        return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "method not found: %s" % method}}


class Session:
    def __init__(self, launch, redactor, initialize=None, declared_dialog_kinds=None, spill_after=5000):
        self.launch = launch
        self.redactor = redactor
        check_recording_hostname(redactor.hostname)
        self.initialize = dict(INITIALIZE if initialize is None else initialize)
        self.declared = set(declared_dialog_kinds if declared_dialog_kinds is not None else self.initialize.get("supportedDialogKinds", []))
        self.spill_after = spill_after
        self.policies = {"can_use_tool": "allow"}
        self.mcp = MCPServer(launch.cwd)
        self._capture = []           # in-memory redacted records
        self._spool = None           # (path, fh) once spilled
        self._spooled = 0
        self._lock = threading.Condition()
        # A separate lock, never held together with `_lock`: a policy dispatch thread
        # answering a request and the scenario thread sending the next one both write
        # stdin, and a text stream interleaved mid-line is a protocol error. It stays
        # outside `_lock` so a full stdin pipe can never stall the stdout reader, whose
        # draining is what lets the child read again.
        self._write_lock = threading.Lock()
        self._threads = []
        self._t0 = None
        self._pending = {}           # outbound request_id -> subtype
        self._responses = {}         # outbound request_id -> response object
        self._dropped_ids = set()
        self._raw_frames = []        # redacted decoded frames for wait_for (same objects as capture)
        self._inbound_subtypes = {}  # CLI-originated request_id -> subtype (for the redactor's rule lookup)
        self._eof = False
        self._wait_cursor = 0
        self.system_init = None
        self.proc = None
        self._stderr = []

    # ---- capture
    def _now_ms(self):
        if self._t0 is None:
            self._t0 = time.monotonic()
        return int((time.monotonic() - self._t0) * 1000)

    def _record(self, direction, frame):
        """Redact, stamp and append as one atomic step.

        Everything up to and including the append happens under `_lock`, because three
        threads record concurrently -- the caller's, the stdout reader's and each policy
        dispatch thread's. Stamping outside the lock lets a thread that read an earlier
        clock append after one that read a later clock, and a capture whose timestamps do
        not increase is not a recording of anything. The redactor's manifest counters are
        shared mutable state on the same path, so they are serialised here too.
        """
        with self._lock:
            rs = dict(self._pending)
            rs.update(self._inbound_subtypes)
            red = self.redactor.redact_frame(frame, direction, rs)
            t = self._now_ms()
            if red is None:
                # The redactor drops a frame; the tombstone that keeps its place in the
                # order, and the suppression of the answer that would quote it back, are
                # the caller's job.
                rid = frame.get("request_id")
                self._dropped_ids.add(rid)
                rec = {"t": t, "dir": direction, "dropped": (frame.get("request") or {}).get("subtype"), "request_id": rid}
            elif frame.get("type") == "control_response" and (frame.get("response") or {}).get("request_id") in self._dropped_ids:
                return None
            else:
                rec = {"t": t, "dir": direction, "frame": red}
            self._capture.append(rec)
            if len(self._capture) > self.spill_after:
                self._spill_locked()
            self._lock.notify_all()
        return red

    def _spill_locked(self):
        if self._spool is None:
            d = tempfile.mkdtemp(prefix="afleet-spool-")
            os.chmod(d, 0o700)
            path = os.path.join(d, "capture.ndjson")
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            self._spool = (path, os.fdopen(fd, "w"))
        for rec in self._capture:
            self._spool[1].write(json.dumps(rec) + "\n")
        self._spool[1].flush()
        self._spooled += len(self._capture)
        self._capture = []

    def frames(self):
        with self._lock:
            out = []
            if self._spool is not None:
                if not self._spool[1].closed:      # `close()` releases the writer; the path stays readable
                    self._spool[1].flush()
                with open(self._spool[0]) as fh:
                    out = [json.loads(l) for l in fh if l.strip()]
            return out + list(self._capture)

    # ---- process
    def start(self, timeout=30):
        self.proc = subprocess.Popen(self.launch.argv(), cwd=self.launch.cwd, env=self.launch.environment(),
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        for target in (self._reader, self._stderr_reader):
            t = threading.Thread(target=target, daemon=True)
            self._threads.append(t)
            t.start()
        rid = "init-1"
        self._send({"type": "control_request", "request_id": rid, "request": self.initialize}, subtype="initialize", rid=rid)
        resp = self._wait_response(rid, timeout)
        if resp is None:
            raise RuntimeError("initialize timed out; stderr: %s" % "".join(self._stderr)[-2000:])
        if resp.get("subtype") != "success":
            raise RuntimeError("initialize failed: %s" % resp.get("error"))
        return resp.get("response") or {}

    def _send(self, frame, subtype=None, rid=None):
        if rid and subtype:
            self._pending[rid] = subtype
        self._record("in", frame)
        line = json.dumps(frame) + "\n"
        with self._write_lock:
            self.proc.stdin.write(line)
            self.proc.stdin.flush()

    def _stderr_reader(self):
        for line in self.proc.stderr:
            self._stderr.append(line)

    def _reader(self):
        for line in self.proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                frame = json.loads(line)
            except ValueError:
                frame = {"type": "__unparseable__", "raw": line}
            if frame.get("type") == "control_request":
                self._inbound_subtypes[frame.get("request_id")] = (frame.get("request") or {}).get("subtype")
            red = self._record("out", frame)
            if red is not None:
                with self._lock:
                    self._raw_frames.append(red)
                    if red.get("type") == "system" and red.get("subtype") == "init":
                        self.system_init = red
                    if red.get("type") == "control_response":
                        self._responses[(red.get("response") or {}).get("request_id")] = red["response"]
                    self._lock.notify_all()
            if frame.get("type") == "control_request":
                threading.Thread(target=self._dispatch, args=(frame,), daemon=True).start()
        with self._lock:
            self._eof = True
            self._lock.notify_all()

    # ---- inbound policy
    def on(self, subtype, policy):
        self.policies[subtype] = policy

    def _dispatch(self, frame):
        req = frame.get("request") or {}
        sub = req.get("subtype")
        rid = frame.get("request_id")
        policy = self.policies.get(sub)
        try:
            if sub == "mcp_message":
                self.answer(rid, {"mcp_response": self.mcp.handle(req.get("message") or {})}); return
            if sub == "request_user_dialog" and req.get("dialog_kind") not in self.declared and policy is None:
                return                                    # left for the CLI's deadline (parent §6.3)
            if sub == "hook_callback" and policy is None:
                self.answer(rid, {"continue": True}); return
            if policy is None and sub not in ("can_use_tool", "elicitation", "request_user_dialog", "hook_callback"):
                self.answer(rid, error="subtype %s not supported by afleet %s" % (sub, VERSION)); return   # the parent §6.3 string, verbatim
            if policy == "leave":
                return
            if policy == "allow" or (policy is None and sub == "can_use_tool"):
                self.answer(rid, {"behavior": "allow", "updatedInput": req.get("input", {})}); return
            if policy == "deny":
                self.answer(rid, {"behavior": "deny", "message": "denied by the probe scenario"}); return
            if callable(policy):
                resp = policy(frame)
                if resp is not None:
                    self.answer(rid, resp)
                return
            self.answer(rid, error="subtype %s not supported by afleet %s" % (sub, VERSION))
        except Exception as e:  # never leave a request unanswered because the policy crashed
            try:
                self.answer(rid, error="probe policy failed: %s" % e)
            except (ValueError, OSError):
                pass                                  # stdin is gone; the exit cancels it (parent §6.3)

    def answer(self, request_id, response=None, error=None):
        body = {"subtype": "error", "request_id": request_id, "error": error} if error is not None else \
               {"subtype": "success", "request_id": request_id, "response": response if response is not None else {}}
        self._send({"type": "control_response", "response": body})

    # ---- outbound
    def send_user(self, text, uuid_=None):
        u = uuid_ or str(uuid.uuid4())
        self._send({"type": "user", "uuid": u, "parent_tool_use_id": None, "origin": {"kind": "human"},
                    "message": {"role": "user", "content": text}})
        return u

    def request_async(self, subtype, **payload):
        rid = str(uuid.uuid4())
        req = {"subtype": subtype}
        req.update(payload)
        self._send({"type": "control_request", "request_id": rid, "request": req}, subtype=subtype, rid=rid)
        return rid

    def wait_response(self, rid, timeout=30):
        return self._wait_response(rid, timeout)

    def cancel(self, rid):
        """Cancel one of our own outbound requests (recorded as an `in` control_cancel_request)."""
        self._send({"type": "control_cancel_request", "request_id": rid})

    def request(self, subtype, timeout=30, **payload):
        rid = self.request_async(subtype, **payload)
        resp = self._wait_response(rid, timeout)
        if resp is None:
            raise TimeoutError("no response to %s within %ss" % (subtype, timeout))
        return resp

    def _wait_response(self, rid, timeout):
        deadline = time.time() + timeout
        with self._lock:
            while rid not in self._responses:
                remaining = deadline - time.time()
                if remaining <= 0 or (self._eof and self.proc.poll() is not None):
                    return None
                self._lock.wait(min(remaining, 0.5))
            return self._responses[rid]

    def wait_for(self, pred, timeout=60):
        """The next frame matching pred that arrived after the previous match (a cursor, so two
        wait_result() calls return two different results)."""
        deadline = time.time() + timeout
        with self._lock:
            while True:
                for i in range(self._wait_cursor, len(self._raw_frames)):
                    if pred(self._raw_frames[i]):
                        self._wait_cursor = i + 1
                        return self._raw_frames[i]
                remaining = deadline - time.time()
                if remaining <= 0:
                    return None
                self._lock.wait(min(remaining, 0.5))

    def wait_result(self, timeout=120):
        return self.wait_for(lambda f: f.get("type") == "result", timeout)

    # ---- shutdown (parent §6.7)
    def close(self, end_session=True):
        if self.proc is None:
            return None
        if self.proc.poll() is None and end_session:
            try:
                self._send({"type": "control_request", "request_id": "end-1", "request": {"subtype": "end_session"}}, "end_session", "end-1")
            except (BrokenPipeError, OSError):
                pass
        try:
            with self._write_lock:
                self.proc.stdin.close()
        except OSError:
            pass
        for sig in (None, signal.SIGTERM, signal.SIGKILL):
            if sig is not None and self.proc.poll() is None:
                self.proc.send_signal(sig)
            try:
                self.proc.wait(timeout=5)
                break
            except subprocess.TimeoutExpired:
                continue
        self._release()
        return self.proc.returncode

    def _release(self):
        """Let go of every handle the session opened. The reader threads end at EOF, which
        the exit above has already delivered, so they are joined before their streams are
        closed rather than being torn out from under a blocking read. The spool file is
        released too; `frames()` re-opens its path by name, so a closed writer costs
        nothing and an unclosed one is a leak in every scenario that spills."""
        for t in self._threads:
            t.join(timeout=5)
        self._threads = []
        for stream in (self.proc.stdin, self.proc.stdout, self.proc.stderr):
            if stream is not None and not stream.closed:
                try:
                    stream.close()
                except OSError:
                    pass
        with self._lock:
            if self._spool is not None and not self._spool[1].closed:
                self._spool[1].close()

    def stderr_tail(self, n=2000):
        return "".join(self._stderr)[-n:]
