import json, subprocess, sys, uuid
from collections import Counter
cwd = sys.argv[1]
extra = sys.argv[2:]
cmd = ["claude","-p","--input-format","stream-json","--output-format","stream-json","--include-partial-messages","--replay-user-messages","--permission-prompts","host","--permission-mode","default","--model","haiku","--verbose"] + extra
p = subprocess.Popen(cmd, cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
def send(o):
    p.stdin.write(json.dumps(o)+"\n"); p.stdin.flush()
pending={}
def control(sub, **kw):
    rid=str(uuid.uuid4()); pending[rid]=sub
    send({"type":"control_request","request_id":rid,"request":{"subtype":sub,**kw}})
control("initialize", supportedDialogKinds=[])
send({"type":"user","message":{"role":"user","content":__import__("os").environ.get("PROMPT","Use the Write tool to create a file named probe.txt in the current directory containing the text: afleet. Then reply with the single word: done")}})
seen=Counter(); phase="turn"
for line in p.stdout:
    line=line.strip()
    if not line: continue
    try: m=json.loads(line)
    except Exception: print("RAW", line[:160]); continue
    t=m.get("type"); st=m.get("subtype") or (m.get("request") or {}).get("subtype") or (m.get("event") or {}).get("type") or ((m.get("response") or {}).get("subtype") if t=="control_response" else "") or ""
    seen[(t,st)]+=1
    if t=="control_response":
        r=m["response"]; sub=pending.pop(r.get("request_id"),"?")
        body=r.get("response") or r.get("error")
        print(f"CONTROL RESPONSE to {sub}: {r.get('subtype')} keys={sorted(body.keys()) if isinstance(body,dict) else body}")
        if sub=="initialize" and isinstance(body,dict):
            print("   commands:", len(body.get("commands",[])), "| output_style:", body.get("output_style"), "| models:", len(body.get("models",[])), "| account keys:", sorted((body.get("account") or {}).keys()))
        if phase=="post" and sub=="set_permission_mode":
            break
    elif t=="control_request" and (m.get("request") or {}).get("subtype")=="can_use_tool":
        r=m["request"]; print("PERMISSION REQUEST:", r.get("tool_name"), json.dumps(r.get("input"))[:100], "| reason_type:", r.get("decision_reason_type"), "| suggestions:", [s.get("type") for s in (r.get("permission_suggestions") or [])], "| default_to_no:", r.get("default_to_no"), "| tool_use_id:", bool(r.get("tool_use_id")))
        send({"type":"control_response","response":{"subtype":"success","request_id":m["request_id"],"response":{"behavior":"allow","updatedInput":r["input"]}}})
    elif t=="control_request":
        print("OTHER CONTROL REQUEST:", (m.get("request") or {}).get("subtype"))
    elif t=="system" and st=="init":
        print("INIT ok: session", m.get("session_id"), "| terminal-only cmds:", m.get("terminal_slash_commands"))
    elif t=="result":
        print("RESULT:", m.get("subtype"), "| turns", m.get("num_turns"), "| text:", (m.get("result") or "")[:60])
        phase="post"; control("set_permission_mode", mode="acceptEdits")
p.stdin.close()
print("CENSUS:", ", ".join(f"{t}/{s}:{n}" if s else f"{t}:{n}" for (t,s),n in seen.most_common()))
try: p.wait(timeout=20)
except Exception: p.kill()
err=p.stderr.read(); print("STDERR tail:", err[-500:].strip() or "(empty)")
