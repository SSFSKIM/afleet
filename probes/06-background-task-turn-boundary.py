import json, subprocess, sys, uuid, time, threading
cwd=sys.argv[1]; out=sys.argv[2]
cmd=["claude","-p","--input-format","stream-json","--output-format","stream-json","--include-partial-messages","--replay-user-messages","--forward-subagent-text","--include-hook-events","--permission-prompt-tool","stdio","--permission-prompts","host","--permission-mode","default","--model","haiku","--verbose"]
p=subprocess.Popen(cmd,cwd=cwd,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1)
log=open(out,"w"); frames=[]; lock=threading.Lock()
def send(o):
    line=json.dumps(o); log.write("OUT "+line+"\n"); log.flush(); p.stdin.write(line+"\n"); p.stdin.flush()
def reader():
    for line in p.stdout:
        line=line.strip()
        if not line: continue
        log.write("IN  "+line+"\n"); log.flush()
        try: m=json.loads(line)
        except: continue
        with lock: frames.append(m)
        if m.get("type")=="control_request" and (m.get("request") or {}).get("subtype")=="can_use_tool":
            send({"type":"control_response","response":{"subtype":"success","request_id":m["request_id"],"response":{"behavior":"allow","updatedInput":m["request"]["input"]}}})
threading.Thread(target=reader,daemon=True).start()
send({"type":"control_request","request_id":str(uuid.uuid4()),"request":{"subtype":"initialize","supportedDialogKinds":[],"perTaskStopAffordance":True,"agentProgressSummaries":True}})
time.sleep(3)
u=str(uuid.uuid4())
send({"type":"user","uuid":u,"parent_tool_use_id":None,"origin":{"kind":"human"},"message":{"role":"user","content":"Use the Bash tool with run_in_background=true to run exactly: sleep 6 && echo bg-done . Then immediately reply with the single word: started"}})
t0=time.time()
while time.time()-t0<120:
    with lock: n=sum(1 for f in frames if f.get("type")=="result")
    if n>=1: break
    time.sleep(0.2)
print("first result at", round(time.time()-t0,1),"s; now waiting 40s for background completion...")
time.sleep(40)
# also ask background_tasks list and get_session_cost
r=str(uuid.uuid4()); send({"type":"control_request","request_id":r,"request":{"subtype":"end_session"}})
time.sleep(2)
try: p.stdin.close()
except: pass
try: p.wait(timeout=20)
except: p.kill()
def summarize(m):
    t=m.get("type"); st=m.get("subtype") or ""
    if t=="stream_event": return None
    if t=="system" and st in ("hook_started","hook_response","hook_progress"): return f"{t}/{st} {m.get('hook_event')}"
    if t=="assistant":
        return f"assistant parent={m.get('parent_tool_use_id')} blocks={[(b['type'], b.get('name') or (b.get('text') or '')[:60]) for b in m['message']['content']]}"
    if t=="user":
        c=m['message']['content']
        blocks=[('text',c[:80])] if isinstance(c,str) else [(b['type'],(b.get('tool_use_id') or '')[-6:],str(b.get('content'))[:120]) for b in c]
        return f"user isReplay={m.get('isReplay')} origin={m.get('origin')} isSynthetic={m.get('isSynthetic')} is_meta={m.get('is_meta')} blocks={blocks}"
    if t=="result": return f"result/{st} result={str(m.get('result'))[:100]!r} num_turns={m.get('num_turns')}"
    if t=="system": return f"system/{st} "+json.dumps({k:v for k,v in m.items() if k not in ('type','subtype','uuid','session_id','tools','mcp_servers','slash_commands','skills','plugins','agents')})[:300]
    return f"{t}/{st} "+json.dumps({k:v for k,v in m.items() if k not in ('type','uuid','session_id')})[:200]
for m in frames:
    s=summarize(m)
    if s: print(s)
print("exit",p.returncode)
