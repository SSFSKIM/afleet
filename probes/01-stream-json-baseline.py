import json, subprocess, sys
from collections import Counter
cwd = sys.argv[1]
cmd = ["claude","-p","--input-format","stream-json","--output-format","stream-json","--include-partial-messages","--replay-user-messages","--permission-prompts","host","--permission-mode","default","--model","haiku","--verbose"]
p = subprocess.Popen(cmd, cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
def send(o):
    p.stdin.write(json.dumps(o)+"\n"); p.stdin.flush()
send({"type":"user","message":{"role":"user","content":"Use the Bash tool to run exactly this command: echo afleet-probe-ok . Then reply with the single word: done"}})
seen=Counter()
for line in p.stdout:
    line=line.strip()
    if not line: continue
    try: m=json.loads(line)
    except Exception: print("RAW", line[:160]); continue
    t=m.get("type"); st=m.get("subtype") or (m.get("request") or {}).get("subtype") or (m.get("event") or {}).get("type") or ""
    seen[(t,st)]+=1
    if t=="control_request" and (m.get("request") or {}).get("subtype")=="can_use_tool":
        r=m["request"]; print("PERMISSION REQUEST:", r.get("tool_name"), json.dumps(r.get("input"))[:120], "| reason:", r.get("decision_reason_type"), "| suggestions:", len(r.get("permission_suggestions") or []))
        send({"type":"control_response","response":{"subtype":"success","request_id":m["request_id"],"response":{"behavior":"allow","updatedInput":r["input"]}}})
    elif t=="control_request":
        print("OTHER CONTROL REQUEST:", (m.get("request") or {}).get("subtype"))
    elif t=="system" and st=="init":
        print("INIT: version", m.get("claude_code_version"), "| model", m.get("model"), "| mode", m.get("permissionMode"), "| commands", len(m.get("slash_commands",[])), "| terminal-only", len(m.get("terminal_slash_commands",[])), "| skills", len(m.get("skills",[])), "| plugins", len(m.get("plugins",[])), "| agents", len(m.get("agents",[])), "| socket", m.get("messaging_socket_path"))
        print("INIT keys:", ", ".join(sorted(m.keys())))
    elif t=="result":
        print("RESULT:", m.get("subtype"), "| cost", m.get("total_cost_usd"), "| turns", m.get("num_turns"), "| session", m.get("session_id"), "| text:", (m.get("result") or "")[:80])
        break
p.stdin.close()
print("CENSUS:", ", ".join(f"{t}/{s}:{n}" if s else f"{t}:{n}" for (t,s),n in seen.most_common()))
try:
    p.wait(timeout=20)
except Exception:
    p.kill()
err=p.stderr.read(); print("STDERR tail:", err[-600:].strip() or "(empty)")
