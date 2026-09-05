#!/usr/bin/env python3
"""Protocol stand-in for ClaudeWire transport tests. Python 3.9+, stdlib only. See the plan's scenario table.

The contract, in two halves:

**The default scenario models the recorded engine.** Behaviour it emits that no fixture in `Fixtures/` shows is
a defect in this stand-in, not a licence for the code under test. Its job is to reproduce what `claude` does,
never to agree with what a specification assumed it does.

**Named scenarios may be deliberately synthetic**, and each says so where it is handled. `keep_alive`,
`unknown_request`, `malformed_can_use_tool`, `undeclared_dialog`, `mcp_tool_throws`, `flood`, `ignore_sigterm`
and the rest exist to drive paths the engine reaches only under conditions nobody can record on demand. They
are adversarial fixtures in code, and are not evidence about the engine.

The split earned its place twice:

- This stand-in used to answer `control_request/initialize` and then emit `system/init` in the same breath, so
  eleven tasks of transport tests passed against a handshake the real engine never performs. The engine emits
  `system/init` at the start of each **turn** — every recorded fixture places it after the first `user` frame,
  and `zero-cost` and `resume-no-replay`, which submit nothing, contain none at all.
- It also used to gate all MCP traffic behind `mcp_sequence`, so the default modelled a session whose host tool
  was live the instant the handshake completed. It is not: see `mcp_handshake()` below.

One divergence from the corpus that is known and deliberately not modelled, recorded so the next reader does
not mistake this file for complete:

- **`system/init` is not strictly one per turn.** The corpus has `nested-depth-2` at one inbound `user` frame
  and three `system/init`s, `session-mirror-relocation` at four and five — with one of those arriving *before*
  its adjacent user frame — and `explore-depth-1` and `background-shell` at one and two. Subagents and session
  relocation both produce extra ones. This file emits exactly one per user frame, which covers the plain case
  and understates the engine.
"""
import json, os, signal, sys, threading, time

SCENARIOS = [s for s in os.environ.get("SCRIPTED_CLAUDE_SCENARIO", "").split(",") if s]
ARGS = sys.argv[1:]
if "--version" in ARGS:
    print("2.1.259 (Claude Code)"); sys.exit(0)

def arg_after(flag):
    return ARGS[ARGS.index(flag) + 1] if flag in ARGS and ARGS.index(flag) + 1 < len(ARGS) else None
SESSION = arg_after("--session-id") or arg_after("--resume") or "00000000-0000-4000-8000-000000000000"
# `--fork-session` makes the engine mint a NEW session id: the `--resume` target names the session forked
# from, and every frame this process emits carries the new one. A stand-in that echoed the resume target
# would model a fork that does not exist and let a host keep the source id for a channel that is not it.
FORKED = "--fork-session" in ARGS
if FORKED:
    SESSION = "f0f0f0f0-0000-4000-8000-000000000fff"
OUT_LOCK = threading.Lock()
def emit(obj):
    with OUT_LOCK:
        sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n"); sys.stdout.flush()
def log(text):
    sys.stderr.write(text + "\n"); sys.stderr.flush()
def has(name): return name in SCENARIOS
def scenario_value(prefix):
    for s in SCENARIOS:
        if s.startswith(prefix + ":"): return s.split(":", 1)[1]
    return None

with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "Samples", "system_init.json")) as f:
    INIT_FRAME = json.load(f)
INIT_FRAME.update({"tools": ["Read", "mcp__afleet__send_user_file"], "session_id": SESSION, "cwd": os.getcwd()})

# MCP state, and the ordering constraint it enforces.
#
# The opening of every recorded fixture is identical (`zero-cost`, `plain-two-turn`, `send-user-file`,
# `resume-no-replay`, verified frame by frame):
#
#   1 in   control_request  initialize
#   2 out  control_request  mcp_message  (JSON-RPC initialize toward the in-process server)
#   3 in   control_response              (the host answers it)
#   4 out  control_response              (only now does the engine answer initialize)
#   5 out  auth_status
#   7 out  control_request  mcp_message  (notifications/initialized)
#   later  control_request  mcp_message  (tools/list), with the first user message or outbound request
#
# Frame 2 before frame 4 is the load-bearing part: **the engine does not answer `initialize` until the host has
# answered the server's JSON-RPC `initialize`.** That is a constraint on the host, not a detail of the engine —
# a transport that starts reading inbound frames only after `spawn()` returns deadlocks here, and this file
# reproducing the order is what makes that guarantee testable rather than assumed.
#
# `mcp_status` is answered out of this dictionary. The engine reports a server `connected` with its tools taken
# from the `tools/list` reply (`Fixtures/zero-cost` records exactly that shape). No fixture photographs an
# `mcp_status` taken mid-connection, so "connecting" below is this file's approximation of a window the corpus
# shows exists: a host that asks for the tool list the instant `spawn()` returns is inside it.
mcp = {"connected": False, "tools": [], "listing": False}
# The initialize response body, held from the moment it is built until the host answers frame 2.
held_initialize = {}

n = [0]
def uuid():
    n[0] += 1; return "5c81e7ed-0000-4000-8000-%012d" % n[0]
def control_request(request_id, request):
    emit({"type": "control_request", "request_id": request_id, "request": request})
def mcp_message(request_id, message):
    control_request(request_id, {"subtype": "mcp_message", "server_name": "afleet", "message": message})

def release_initialize_response():
    """Frames 4, 5 and 7: answer `initialize`, then send `notifications/initialized`.

    Reached only from the host's answer to frame 2, which is the whole point.
    """
    body = held_initialize.pop("body", None)
    if body is None: return
    emit({"type": "control_response", "response": body})
    # Frame 5, at the same millisecond as frame 4 in all sixteen recorded fixtures, and before any user
    # frame. It is the first frame carrying `session_id`, which is what makes a fork's own id knowable
    # without waiting for a turn.
    emit({"type": "auth_status", "isAuthenticating": False, "output": [], "error": None,
          "uuid": uuid(), "session_id": SESSION})
    mcp_message("s1n", {"jsonrpc": "2.0", "method": "notifications/initialized"})
    if held_initialize.pop("pending", False): can_use_tool("p1")
    if has("pending_unknown"): control_request("u2", {"subtype": "afleet_never_heard", "anything": 1})
    threading.Thread(target=after_init, daemon=True).start()

def request_tools_list():
    """`tools/list`, sent once, on the first thing the host does after the handshake.

    That is where the corpus puts it: with the first user frame in `plain-two-turn` and `send-user-file`, and
    with the first outbound control request in `zero-cost`, which never submits one. `mcp_slow_connect:<s>`
    stretches the gap so a test can observe the not-yet-connected window without racing it — the delay is
    synthetic, the window it widens is not.
    """
    if mcp["listing"] or mcp["connected"] or "body" in held_initialize: return
    mcp["listing"] = True
    def go():
        delay = float(scenario_value("mcp_slow_connect") or 0)
        if delay: time.sleep(delay)
        mcp_message("s2", {"jsonrpc": "2.0", "id": 91, "method": "tools/list"})
    threading.Thread(target=go, daemon=True).start()

def can_use_tool(request_id, **extra):
    req = {"subtype": "can_use_tool", "tool_name": "Write", "input": {"file_path": "out.txt", "content": "x"}, "tool_use_id": "toolu_" + request_id}
    req.update(extra); control_request(request_id, req)

ignore_term = has("ignore_sigterm")
if ignore_term:
    signal.signal(signal.SIGTERM, lambda *a: log("IGNORED SIGTERM")); signal.signal(signal.SIGINT, lambda *a: None)

def after_init():
    if has("keep_alive"):
        def ka():
            while True: time.sleep(0.1); emit({"type": "keep_alive"})
        threading.Thread(target=ka, daemon=True).start()
    if has("unknown_request"): control_request("u1", {"subtype": "afleet_never_heard", "anything": 1})
    if has("malformed_can_use_tool"): control_request("b1", {"subtype": "can_use_tool", "tool_name": "Write", "input": "not-an-object", "tool_use_id": "toolu_b1"})
    if has("declared_dialog"): control_request("d1", {"subtype": "request_user_dialog", "dialog_kind": "refusal_fallback_prompt", "payload": {"originalModel": "a", "fallbackModel": "b"}})
    if has("undeclared_dialog"):
        control_request("d2", {"subtype": "request_user_dialog", "dialog_kind": "weird_kind", "payload": {}})
        def cancel():
            time.sleep(0.5)
            if "d2" not in answered: emit({"type": "control_cancel_request", "request_id": "d2"}); log("CANCELLED d2")
        threading.Thread(target=cancel, daemon=True).start()
    if has("cancel_request"):
        can_use_tool("c1")
        def cancel():
            time.sleep(0.2); emit({"type": "control_cancel_request", "request_id": "c1"}); log("CANCELLED c1")
        threading.Thread(target=cancel, daemon=True).start()
    if has("hook_unregistered"): control_request("h1", {"subtype": "hook_callback", "callback_id": "nope", "input": {"hook_event_name": "Notification", "message": "m"}})
    if has("hook_registered"): control_request("h2", {"subtype": "hook_callback", "callback_id": "afleet.notification", "input": {"hook_event_name": "Notification", "message": "needs you", "title": "Claude Code", "notification_type": "permission_prompt"}})
    if has("mcp_sequence"):
        msgs = [("m1", {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "scripted"}}}),
                ("m1n", {"jsonrpc": "2.0", "method": "notifications/initialized"}),
                ("m2", {"jsonrpc": "2.0", "id": 2, "method": "ping"}),
                ("m3", {"jsonrpc": "2.0", "id": 3, "method": "tools/list"}),
                ("m4", {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "send_user_file", "arguments": {"files": ["hello.txt"], "status": "normal"}}}),
                ("m5", {"jsonrpc": "2.0", "id": 5, "method": "resources/list"}),
                ("m6", {"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 4}})]
        for rid, msg in msgs: control_request(rid, {"subtype": "mcp_message", "server_name": "afleet", "message": msg})
    if has("mcp_slow_tool"):
        mcp_message("m8", {"jsonrpc": "2.0", "id": 8, "method": "tools/call",
                           "params": {"name": "slow_send", "arguments": {}}})
        if has("cancel_mcp"):
            def cancel_m8():
                time.sleep(0.2); emit({"type": "control_cancel_request", "request_id": "m8"}); log("CANCELLED m8")
            threading.Thread(target=cancel_m8, daemon=True).start()
    if has("mcp_tool_throws"):
        control_request("m7", {"subtype": "mcp_message", "server_name": "afleet",
                               "message": {"jsonrpc": "2.0", "id": 7, "method": "tools/call",
                                           "params": {"name": "explode", "arguments": {"path": "/Users/someone/private/ledger.csv"}}}})
    if scenario_value("flood"):
        count = int(scenario_value("flood"))
        for i in range(count):
            emit({"type": "assistant", "message": {"id": "msg_%d" % i, "type": "message", "role": "assistant", "model": "scripted", "content": [{"type": "text", "text": "x" * 200}], "stop_reason": None, "stop_sequence": None, "usage": {"input_tokens": 1, "output_tokens": 1}}, "parent_tool_use_id": None, "uuid": uuid(), "session_id": SESSION})
        emit({"type": "result", "subtype": "success", "duration_ms": 1, "duration_api_ms": 1, "is_error": False, "num_turns": 1, "result": "flooded", "stop_reason": "end_turn", "total_cost_usd": 0, "usage": {"input_tokens": 1, "output_tokens": 1}, "modelUsage": {}, "permission_denials": [], "uuid": uuid(), "session_id": SESSION})
        log("FLOOD DONE")
    if has("leak_stdout"):
        # A grandchild that inherits this process's stdout and stderr write ends and outlives it. When the
        # child then exits, the reader never sees EOF: EOF needs *every* holder of the write end to close it.
        # Popen inherits both descriptors by default, which is precisely the case that matters.
        import subprocess
        subprocess.Popen(["/bin/sleep", "20"])
        log("GRANDCHILD HOLDS STDOUT")
    if scenario_value("stderr"): log(scenario_value("stderr"))
    if scenario_value("exit") is not None:
        sys.stdout.flush(); os._exit(int(scenario_value("exit")))

answered = set()
deaf = [False]
closed_stdin = [False]
# side_question_late_error: request ids the host asked and we deliberately left hanging until it cancels.
withheld = {}
def handle(line):
    try: frame = json.loads(line)
    except ValueError: log("BAD LINE " + line.strip()); return
    t = frame.get("type")
    if t in ("user", "control_request") and (t == "user" or frame["request"].get("subtype") != "initialize"):
        request_tools_list()
    if t == "control_request":
        rid = frame["request_id"]; sub = frame["request"].get("subtype")
        if sub == "initialize":
            if has("no_init"):
                # Still run the post-init side effects (stderr, keep_alive, ...) so a handshake-timeout
                # scenario can be combined with them; only the initialize answer is withheld.
                threading.Thread(target=after_init, daemon=True).start()
                return
            resp = {"commands": [], "agents": [], "models": [], "output_style": "default", "available_output_styles": ["default"], "current_model": "scripted", "current_permission_mode": "default", "session_state": {}, "pid": os.getpid(), "fast_mode_state": "off"}
            body = {"subtype": "success", "request_id": rid, "response": resp}
            if has("pending"): body["pending_permission_requests"] = [{"type": "control_request", "request_id": "p1", "request": {"subtype": "can_use_tool", "tool_name": "Write", "input": {"file_path": "p.txt", "content": "x"}, "tool_use_id": "toolu_p1"}}]
            if has("pending_unknown"):
                # Synthetic. The engine re-arms only requests it knows about, but the host cannot assume its
                # own vocabulary matches the engine's: a subtype afleet has never heard of is exactly what a
                # newer engine re-arms, and the pending path must treat it the way the live path does.
                body["pending_permission_requests"] = [
                    {"type": "control_request", "request_id": "u2", "request": {"subtype": "afleet_never_heard", "anything": 1}}]
            if has("pending_undecodable"):
                body["pending_permission_requests"] = [
                    {"type": "control_request", "request_id": "q1", "request": {"subtype": "can_use_tool", "tool_name": "Write", "input": {"file_path": "q.txt", "content": "x"}, "tool_use_id": "toolu_q1"}},
                    {"type": "control_request", "request": {"subtype": "can_use_tool"}},   # no request_id: undecodable as a control request
                ]
            # Frame 2 before frame 4: the response is held until the host answers the server's JSON-RPC
            # initialize. A host whose inbound loop starts after `spawn()` returns never gets past here.
            held_initialize["body"] = body
            held_initialize["pending"] = has("pending")
            mcp_message("s1", {"jsonrpc": "2.0", "id": 90, "method": "initialize",
                               "params": {"protocolVersion": "2025-11-25", "capabilities": {},
                                          "clientInfo": {"name": "scripted", "version": "0"}}})
        elif sub == "end_session":
            log("HOST end_session"); emit({"type": "control_response", "response": {"subtype": "success", "request_id": rid, "response": {}}})
            if not (has("ignore_end_session") or has("ignore_sigterm")):
                time.sleep(0.05); sys.stdout.flush(); os._exit(0)
        elif sub == "mcp_status":
            server = {"name": "afleet", "status": "connected" if mcp["connected"] else "connecting",
                      "serverInfo": {"name": "afleet", "version": "0.1"}, "scope": "dynamic",
                      "tools": [{"name": name, "annotations": {}} for name in mcp["tools"]]}
            emit({"type": "control_response", "response": {"subtype": "success", "request_id": rid,
                                                           "response": {"mcpServers": [server]}}})
        elif sub == "get_usage":
            # Shape copied from the recorded response in `Fixtures/zero-cost`, trimmed to the windows a reader
            # looks at. `usage:<n>` drives the seven-day percentage; the five-hour one stays low.
            seven = float(scenario_value("usage") or 11)
            usage = {"rate_limits_available": True,
                     "rate_limits": {"five_hour": {"utilization": 15, "resets_at": "2026-09-05T00:59:59Z"},
                                     "seven_day": {"utilization": seven, "resets_at": "2026-09-08T02:59:59Z"},
                                     "seven_day_opus": None, "tangelo": None,
                                     "nimbus_quill": {"utilization": 0, "resets_at": None},
                                     "extra_usage": {"is_enabled": False, "utilization": None},
                                     "limits": [{"kind": "session", "group": "session", "percent": 15, "severity": "normal"},
                                                {"kind": "weekly_all", "group": "weekly", "percent": seven, "severity": "normal"}]}}
            emit({"type": "control_response", "response": {"subtype": "success", "request_id": rid, "response": usage}})
        elif sub == "side_question" and has("side_question_late_error"):
            withheld[rid] = sub; log("HOST " + str(sub) + " WITHHELD")
        else:
            log("HOST " + str(sub))
            if has("exit_after_answer"):
                # A backlog in front of the answer, sized to fit one pipe buffer so this process can still
                # exit without blocking. The host is left holding an answer it has not read yet at the moment
                # the child dies — which is the only arrangement under which the correlation is actually tested.
                for i in range(60):
                    emit({"type": "assistant", "message": {"id": "pre_%d" % i, "type": "message", "role": "assistant", "model": "scripted", "content": [{"type": "text", "text": "y" * 100}], "stop_reason": None, "stop_sequence": None, "usage": {"input_tokens": 1, "output_tokens": 1}}, "parent_tool_use_id": None, "uuid": uuid(), "session_id": SESSION})
            emit({"type": "control_response", "response": {"subtype": "success", "request_id": rid, "response": {}}})
            if has("exit_after_answer"):
                sys.stdout.flush(); os._exit(0)
    elif t == "control_cancel_request":
        rid = frame["request_id"]
        log("HOST CANCEL " + str(rid))
        if rid in withheld:
            del withheld[rid]
            # The engine answers an honoured cancel with an error response for an id the host has
            # already forgotten; the host must treat that as ordinary traffic (spec §6.4).
            emit({"type": "control_response", "response": {"subtype": "error", "request_id": rid, "error": "Side question cancelled"}})
            log("LATE ERROR " + str(rid))
    elif t == "control_response":
        r = frame["response"]; rid = r.get("request_id"); answered.add(rid)
        if rid == "s1":
            release_initialize_response()
            # Synthetic, and the only way to produce a stdin write that never completes: this process stops
            # reading, the 64 KB pipe fills behind the host's next write, and `StdinWriter`'s serial queue —
            # and everything queued behind it, `end_session` included — is stuck there.
            if has("deaf_stdin"): deaf[0] = True
            # `close_stdin` keeps this process running but takes its read end of the pipe away, so the
            # host's next write gets EPIPE. Also synthetic: "the reply never reached the child" has to be
            # produced for real, and a child that *exits* instead would unregister the in-flight MCP task
            # and prove nothing about the write. Both flags are actioned on the main thread, below —
            # closing fd 0 underneath a thread blocked reading it raises EBADF and kills the interpreter.
            if has("close_stdin"): closed_stdin[0] = True
        if rid == "s2":
            result = ((r.get("response") or {}).get("mcp_response") or {}).get("result") or {}
            mcp["tools"] = [tool.get("name") for tool in result.get("tools", [])]
            mcp["connected"] = True; mcp["listing"] = False
            log("MCP CONNECTED " + json.dumps(mcp["tools"]))
        tag = "MCP" if str(rid).startswith("m") else "ANSWER"
        log("%s %s %s" % (tag, rid, json.dumps(r, separators=(",", ":"), sort_keys=True)))
    elif t == "user":
        content = frame["message"]["content"]
        text = content if isinstance(content, str) else " ".join(b.get("text", "") for b in content if isinstance(b, dict))
        # system/init opens the turn, as it does in every recorded fixture — never at handshake.
        emit(dict(INIT_FRAME, uuid=uuid()))
        # `rate_limit:<status>` reproduces the two shapes the corpus actually carries. Thirteen recorded
        # objects have status "allowed" beside overageStatus "rejected" and overageDisabledReason
        # "org_level_disabled" on turns that completed; five, all in `rate-limited-turn`, have status
        # "rejected" with "out_of_credits". Only `status` says whether the turn ran.
        rate_limit = scenario_value("rate_limit")
        if rate_limit:
            rejected = rate_limit == "rejected"
            emit({"type": "rate_limit_event", "uuid": uuid(), "session_id": SESSION,
                  "rate_limit_info": {"status": "rejected" if rejected else "allowed",
                                      "rateLimitType": "seven_day" if rejected else "five_hour",
                                      "overageStatus": "rejected",
                                      "overageDisabledReason": "out_of_credits" if rejected else "org_level_disabled",
                                      "isUsingOverage": False, "resetsAt": 1788836400,
                                      "unifiedWindows": {"five_hour": {"utilization": 0.55, "resetsAt": 1788570000},
                                                         "seven_day": {"utilization": 1.0 if rejected else 0.11, "resetsAt": 1788836400}}}})
        emit({"type": "assistant", "message": {"id": "msg_echo", "type": "message", "role": "assistant", "model": "scripted", "content": [{"type": "text", "text": "echo: " + text}], "stop_reason": "end_turn", "stop_sequence": None, "usage": {"input_tokens": 1, "output_tokens": 1}}, "parent_tool_use_id": None, "uuid": uuid(), "session_id": SESSION, "user_message_uuid": frame.get("uuid")})
        emit({"type": "result", "subtype": "success", "duration_ms": 1, "duration_api_ms": 1, "is_error": False, "num_turns": 1, "result": "echo: " + text, "stop_reason": "end_turn", "total_cost_usd": 0, "usage": {"input_tokens": 1, "output_tokens": 1}, "modelUsage": {}, "permission_denials": [], "uuid": uuid(), "session_id": SESSION})

for line in sys.stdin:
    if line.strip(): handle(line)
    if deaf[0]:
        log("DEAF")
        while True: time.sleep(1)
    if closed_stdin[0]:
        try: os.close(0)
        except OSError: pass
        log("STDIN CLOSED")
        break
# stdin closed
if has("stay_alive") or has("ignore_end_session") or has("ignore_sigterm"):
    while True: time.sleep(1)
sys.exit(0)
