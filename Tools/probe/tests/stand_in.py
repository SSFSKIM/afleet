#!/usr/bin/env python3
"""Scripted stream-json stand-in for harness tests. Features via STAND_IN_FEATURES."""
import json
import os
import sys
import threading
import time
import uuid

FEATURES = [f for f in os.environ.get("STAND_IN_FEATURES", "").split(",") if f]
inbox = []
lock = threading.Condition()
out_lock = threading.Lock()   # main and the responder thread both emit


def emit(frame):
    with out_lock:
        sys.stdout.write(json.dumps(frame) + "\n")
        sys.stdout.flush()


def reader():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            m = json.loads(line)
        except ValueError:
            continue
        with lock:
            inbox.append(m)
            lock.notify_all()
    with lock:
        inbox.append({"type": "__eof__"})
        lock.notify_all()


def wait(pred, timeout=10):
    deadline = time.time() + timeout
    with lock:
        while True:
            for m in inbox:
                if pred(m):
                    return m
            remaining = deadline - time.time()
            if remaining <= 0:
                return None
            lock.wait(remaining)


def response_to(rid, timeout=10):
    return wait(lambda m: m.get("type") == "control_response" and (m.get("response") or {}).get("request_id") == rid, timeout)


def control_request(subtype, **payload):
    rid = str(uuid.uuid4())
    req = {"subtype": subtype}
    req.update(payload)
    emit({"type": "control_request", "request_id": rid, "request": req})
    return rid


def responder():
    """Answer every host control_request main() does not handle itself, so the harness's
    own outbound request/await-response cycle can be driven end to end."""
    answered = set()
    while True:
        m = wait(lambda x: x.get("type") == "control_request" and x.get("request_id") not in answered
                 and (x.get("request") or {}).get("subtype") not in ("initialize", "end_session"), 60)
        if m is None:
            return
        answered.add(m["request_id"])
        req = m.get("request") or {}
        emit({"type": "control_response", "response": {"subtype": "success", "request_id": m["request_id"],
              "response": {"echo": req.get("subtype"), "note": req.get("note")}}})


def main():
    if "--version" in sys.argv:
        print("2.1.259 (Claude Code)"); return 0
    if "--help" in sys.argv:
        print("Options:\n  -p, --print  x\n  --input-format <f>  y\n  --permission-prompt-tool <t>  z\n"); return 0
    threading.Thread(target=reader, daemon=True).start()
    threading.Thread(target=responder, daemon=True).start()
    if "no_initialize" in FEATURES:
        wait(lambda m: m.get("type") == "__eof__", 60)   # never answer the handshake
        return 0
    init = wait(lambda m: m.get("type") == "control_request" and (m.get("request") or {}).get("subtype") == "initialize", 10)
    if init is None:
        return 4
    emit({"type": "control_response", "response": {"subtype": "success", "request_id": init["request_id"],
          "response": {"commands": [], "agents": [], "models": [], "output_style": "default", "account": {"email": "real@example.com"},
                       "current_model": "haiku", "current_permission_mode": "default", "session_state": "idle", "pid": os.getpid()}}})
    user = wait(lambda m: m.get("type") == "user", 20)
    if user is None:
        return 0
    sid = str(uuid.uuid4())
    emit({"type": "system", "subtype": "init", "session_id": sid, "cwd": os.getcwd(), "tools": ["Bash", "mcp__afleet__send_user_file"],
          "capabilities": ["interrupt_receipt_v1"], "claude_code_version": "2.1.259", "apiKeySource": "none", "uuid": str(uuid.uuid4())})
    for feature in FEATURES:
        if feature == "permission":
            rid = control_request("can_use_tool", tool_name="Write", input={"file_path": "x.txt", "content": "hi"}, tool_use_id="tu1")
            r = response_to(rid)
            emit({"type": "system", "subtype": "stand_in_saw", "what": "permission", "behavior": ((r or {}).get("response") or {}).get("response", {}).get("behavior")})
        elif feature == "unknown":
            rid = control_request("bogus_probe_request", payload=1)
            r = response_to(rid)
            emit({"type": "system", "subtype": "stand_in_saw", "what": "unknown", "error": (r or {}).get("response", {}).get("error")})
        elif feature == "dialog":
            rid = control_request("request_user_dialog", dialog_kind="not_declared_kind", payload={})
            r = response_to(rid, timeout=1.5)
            emit({"type": "system", "subtype": "stand_in_saw", "what": "dialog", "answered": r is not None})
            emit({"type": "control_cancel_request", "request_id": rid})
        elif feature == "dialog_declared":
            rid = control_request("request_user_dialog", dialog_kind="refusal_fallback_prompt", payload={})
            r = response_to(rid)
            emit({"type": "system", "subtype": "stand_in_saw", "what": "dialog_declared",
                  "response": ((r or {}).get("response") or {}).get("response")})
        elif feature == "elicitation":
            # Field names as the parity inventory records them (31-27 §15.3).
            rid = control_request("elicitation", mcp_server_name="afleet", message="pick one",
                                  requested_schema={"type": "object", "properties": {"choice": {"type": "string"}}})
            r = response_to(rid)
            emit({"type": "system", "subtype": "stand_in_saw", "what": "elicitation",
                  "response": ((r or {}).get("response") or {}).get("response")})
        elif feature == "mcp":
            for msg in ({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "stand-in", "version": "0"}}},
                        {"jsonrpc": "2.0", "method": "notifications/initialized"},
                        {"jsonrpc": "2.0", "id": 2, "method": "ping"},
                        {"jsonrpc": "2.0", "id": 3, "method": "tools/list"},
                        {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "send_user_file", "arguments": {"files": ["a.txt", "b.txt"], "caption": "two", "status": "normal"}}},
                        {"jsonrpc": "2.0", "id": 5, "method": "nope/method"}):
                rid = control_request("mcp_message", server_name="afleet", message=msg)
                r = response_to(rid)
                emit({"type": "system", "subtype": "stand_in_saw", "what": "mcp", "id": msg.get("id"), "mcp_response": ((r or {}).get("response") or {}).get("response", {}).get("mcp_response")})
        elif feature == "envvars":
            rid = control_request("update_environment_variables", variables={"SECRET_KEY": "s3cret"})
            response_to(rid)
        elif feature == "hook":
            rid = control_request("hook_callback", callback_id="afleet.notification", input={"message": "hello", "notification_type": "idle"})
            r = response_to(rid)
            emit({"type": "system", "subtype": "stand_in_saw", "what": "hook", "response": ((r or {}).get("response") or {}).get("response")})
        elif feature == "ignore_end_session":
            pass
        elif feature == "leak":
            emit({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "token sk-ant-api03-LEAKLEAK and mail leak@example.com"}]}, "uuid": str(uuid.uuid4())})
    emit({"type": "result", "subtype": "success", "result": "done", "num_turns": 1, "session_id": sid, "uuid": str(uuid.uuid4())})
    # end-of-session behaviour
    end = wait(lambda m: m.get("type") == "__eof__" or (m.get("type") == "control_request" and (m.get("request") or {}).get("subtype") == "end_session"), 30)
    if end and end.get("type") == "control_request":
        if "ignore_end_session" in FEATURES:
            wait(lambda m: m.get("type") == "__eof__", 30)
            time.sleep(30)  # keep living until a signal arrives
        else:
            emit({"type": "control_response", "response": {"subtype": "success", "request_id": end["request_id"], "response": {}}})
    return 0


if __name__ == "__main__":
    sys.exit(main())
