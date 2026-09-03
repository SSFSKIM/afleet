import json, subprocess, sys
from collections import Counter
cwd=sys.argv[1]
cmd=["claude","-p","--input-format","stream-json","--output-format","stream-json","--permission-prompts","host","--permission-mode","default","--model","haiku","--verbose"]
p=subprocess.Popen(cmd,cwd=cwd,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1)
def send(o): p.stdin.write(json.dumps(o)+"\n"); p.stdin.flush()
send({"type":"user","message":{"role":"user","content":"Send the file note.txt in the current directory to me using the SendUserFile tool (load it with ToolSearch first if it is deferred). Then reply with the single word: done"}})
seen=Counter()
for line in p.stdout:
    line=line.strip()
    if not line: continue
    try: m=json.loads(line)
    except Exception: continue
    t=m.get("type"); st=m.get("subtype") or (m.get("request") or {}).get("subtype") or ""
    seen[(t,st)]+=1
    if t=="control_request" and st=="can_use_tool":
        send({"type":"control_response","response":{"subtype":"success","request_id":m["request_id"],"response":{"behavior":"allow","updatedInput":m["request"]["input"]}}})
    if t=="assistant":
        for b in m["message"]["content"]:
            if b.get("type")=="tool_use": print("TOOL_USE:", b["name"], json.dumps(b.get("input"))[:140])
    if t=="user":
        for b in (m["message"]["content"] if isinstance(m["message"]["content"],list) else []):
            if b.get("type")=="tool_result": print("TOOL_RESULT:", (json.dumps(b.get("content"))[:200]))
        if m.get("tool_use_result") is not None: print("TOOL_USE_RESULT keys:", list(m["tool_use_result"].keys())[:12] if isinstance(m["tool_use_result"],dict) else type(m["tool_use_result"]).__name__)
    if t=="system" and st not in ("init","status","hook_started","hook_response","thinking_tokens"): print("SYSTEM:", st, json.dumps({k:v for k,v in m.items() if k not in ("type","subtype","uuid","session_id")})[:220])
    if t=="result": print("RESULT:", m.get("subtype"), (m.get("result") or "")[:60]); break
p.stdin.close()
print("CENSUS:", ", ".join(f"{t}/{s}:{n}" if s else f"{t}:{n}" for (t,s),n in seen.most_common()))
try: p.wait(timeout=20)
except Exception: p.kill()
