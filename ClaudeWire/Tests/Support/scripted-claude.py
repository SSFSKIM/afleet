#!/usr/bin/env python3
"""Protocol stand-in for ClaudeWire transport tests. Python 3.9+, stdlib only. See the plan's scenario table."""
import json, os, signal, sys, threading, time

SCENARIOS = [s for s in os.environ.get("SCRIPTED_CLAUDE_SCENARIO", "").split(",") if s]
ARGS = sys.argv[1:]
if "--version" in ARGS:
    print("2.1.259 (Claude Code)"); sys.exit(0)

def arg_after(flag):
    return ARGS[ARGS.index(flag) + 1] if flag in ARGS and ARGS.index(flag) + 1 < len(ARGS) else None
SESSION = arg_after("--session-id") or arg_after("--resume") or "00000000-0000-4000-8000-000000000000"
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

n = [0]
def uuid():
    n[0] += 1; return "5c81e7ed-0000-4000-8000-%012d" % n[0]
def control_request(request_id, request):
    emit({"type": "control_request", "request_id": request_id, "request": request})
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
# side_question_late_error: request ids the host asked and we deliberately left hanging until it cancels.
withheld = {}
def handle(line):
    try: frame = json.loads(line)
    except ValueError: log("BAD LINE " + line.strip()); return
    t = frame.get("type")
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
            if has("pending_undecodable"):
                body["pending_permission_requests"] = [
                    {"type": "control_request", "request_id": "q1", "request": {"subtype": "can_use_tool", "tool_name": "Write", "input": {"file_path": "q.txt", "content": "x"}, "tool_use_id": "toolu_q1"}},
                    {"type": "control_request", "request": {"subtype": "can_use_tool"}},   # no request_id: undecodable as a control request
                ]
            emit({"type": "control_response", "response": body})
            emit(dict(INIT_FRAME, uuid=uuid()))
            if has("pending"): can_use_tool("p1")
            threading.Thread(target=after_init, daemon=True).start()
        elif sub == "end_session":
            log("HOST end_session"); emit({"type": "control_response", "response": {"subtype": "success", "request_id": rid, "response": {}}})
            if not (has("ignore_end_session") or has("ignore_sigterm")):
                time.sleep(0.05); sys.stdout.flush(); os._exit(0)
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
        tag = "MCP" if str(rid).startswith("m") else "ANSWER"
        log("%s %s %s" % (tag, rid, json.dumps(r, separators=(",", ":"), sort_keys=True)))
    elif t == "user":
        content = frame["message"]["content"]
        text = content if isinstance(content, str) else " ".join(b.get("text", "") for b in content if isinstance(b, dict))
        emit({"type": "assistant", "message": {"id": "msg_echo", "type": "message", "role": "assistant", "model": "scripted", "content": [{"type": "text", "text": "echo: " + text}], "stop_reason": "end_turn", "stop_sequence": None, "usage": {"input_tokens": 1, "output_tokens": 1}}, "parent_tool_use_id": None, "uuid": uuid(), "session_id": SESSION, "user_message_uuid": frame.get("uuid")})
        emit({"type": "result", "subtype": "success", "duration_ms": 1, "duration_api_ms": 1, "is_error": False, "num_turns": 1, "result": "echo: " + text, "stop_reason": "end_turn", "total_cost_usd": 0, "usage": {"input_tokens": 1, "output_tokens": 1}, "modelUsage": {}, "permission_denials": [], "uuid": uuid(), "session_id": SESSION})

for line in sys.stdin:
    if line.strip(): handle(line)
# stdin closed
if has("ignore_end_session") or has("ignore_sigterm"):
    while True: time.sleep(1)
sys.exit(0)
