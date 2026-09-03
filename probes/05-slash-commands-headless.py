import json, subprocess, sys, uuid, time, threading, os
cwd = sys.argv[1]; out = sys.argv[2]
cmd = ["claude","-p","--input-format","stream-json","--output-format","stream-json","--include-partial-messages","--replay-user-messages","--forward-subagent-text","--include-hook-events","--permission-prompt-tool","stdio","--permission-prompts","host","--permission-mode","default","--model","haiku","--verbose"]
p = subprocess.Popen(cmd, cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
log=open(out,"w"); frames=[]; lock=threading.Lock()
def send(o):
    line=json.dumps(o); log.write("OUT "+line+"\n"); log.flush()
    p.stdin.write(line+"\n"); p.stdin.flush()
def reader():
    for line in p.stdout:
        line=line.strip()
        if not line: continue
        log.write("IN  "+line+"\n"); log.flush()
        try: m=json.loads(line)
        except Exception: continue
        with lock: frames.append(m)
        if m.get("type")=="control_request" and (m.get("request") or {}).get("subtype")=="can_use_tool":
            r=m["request"]
            send({"type":"control_response","response":{"subtype":"success","request_id":m["request_id"],"response":{"behavior":"allow","updatedInput":r["input"]}}})
threading.Thread(target=reader,daemon=True).start()
rid=str(uuid.uuid4())
send({"type":"control_request","request_id":rid,"request":{"subtype":"initialize","supportedDialogKinds":[],"perTaskStopAffordance":True,"agentProgressSummaries":True}})
time.sleep(4)
steps=[
 ("/help",""),("/context",""),("/cost",""),("/usage",""),("/status",""),("/model sonnet",""),("/model",""),("/tasks",""),("/permissions",""),("/config",""),("/vim",""),("/rewind",""),("/doctor",""),("/resume",""),("/memory",""),("/hooks",""),("/mcp",""),("/agents",""),("/skills",""),("/plan",""),("/diff",""),("/btw what is 2+2",""),("/export",""),("/rename probe-title",""),("/effort low",""),("/fast",""),("/theme",""),("/terminal-setup",""),("/keybindings",""),("/release-notes",""),("/copy",""),("/stats",""),("/bug",""),("/color red",""),("/add-dir /tmp",""),("/cd /tmp",""),("/branch",""),("/fork",""),("/background",""),("/goal",""),("/loops",""),("/tui",""),("/focus",""),("/brief",""),("/sandbox",""),("/ide",""),("/statusline",""),("/insights",""),("/init",""),
 ("TURN: Do exactly these three things in order and nothing else. 1) Use the Bash tool with run_in_background=true to run: sleep 12 && echo bg-done . 2) Use the Agent tool with subagent_type=Explore and prompt 'List the top-level entries of this directory using Bash ls, then reply with the count.' 3) When the background command notification arrives (or after the agent finishes, whichever is later), reply with the single word: done",""),
]
step_marks=[]
for text,_ in steps:
    is_turn=text.startswith("TURN: ")
    body=text[6:] if is_turn else text
    if text in ("/insights","/init") : continue  # prompt commands: would cost a real turn; skip
    u=str(uuid.uuid4()); start=len(frames)
    send({"type":"user","uuid":u,"parent_tool_use_id":None,"origin":{"kind":"human"},"message":{"role":"user","content":body}})
    deadline=time.time()+(150 if is_turn else 20)
    while time.time()<deadline:
        with lock: fr=frames[start:]
        if any(f.get("type")=="result" for f in fr): break
        time.sleep(0.2)
    with lock: fr=frames[start:]
    census={}
    for f in fr:
        t=f.get("type"); st=f.get("subtype") or ((f.get("request") or {}).get("subtype") if t=="control_request" else "") or ((f.get("event") or {}).get("type") if t=="stream_event" else "") or ""
        k=f"{t}/{st}" if st else t; census[k]=census.get(k,0)+1
    texts=[]
    for f in fr:
        if f.get("type")=="user" and isinstance(f.get("message",{}).get("content"),(str,list)):
            c=f["message"]["content"]
            if isinstance(c,str): texts.append(c[:300])
            else:
                for b in c:
                    if b.get("type")=="text": texts.append(b["text"][:300])
        if f.get("type")=="system" and f.get("subtype") in ("informational","local_command_output"):
            texts.append("[%s] %s"%(f["subtype"],str(f.get("content"))[:300]))
        if f.get("type")=="result":
            texts.append("[result:%s] %s"%(f.get("subtype"),str(f.get("result"))[:200]))
    step_marks.append({"text":body,"census":census,"texts":texts,"n":len(fr)})
    print("=== STEP",body[:50],"| frames",len(fr),"|",json.dumps(census)); 
    for t in texts[:8]: print("    ",t.replace("\n","⏎")[:240])
    sys.stdout.flush()
r=str(uuid.uuid4()); send({"type":"control_request","request_id":r,"request":{"subtype":"end_session"}})
time.sleep(2)
try: p.stdin.close()
except Exception: pass
try: p.wait(timeout=20)
except Exception: p.kill()
err=p.stderr.read()
json.dump({"steps":step_marks,"stderr_tail":err[-4000:]},open(out+".summary.json","w"),indent=1)
print("DONE exit",p.returncode)
