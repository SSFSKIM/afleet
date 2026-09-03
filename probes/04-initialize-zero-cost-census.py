import json, subprocess, sys, uuid, time, threading, os
cwd = sys.argv[1]
out = sys.argv[2]
cmd = ["claude","-p","--input-format","stream-json","--output-format","stream-json","--include-partial-messages","--replay-user-messages","--forward-subagent-text","--include-hook-events","--permission-prompt-tool","stdio","--permission-prompts","host","--verbose"]
p = subprocess.Popen(cmd, cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
frames=[]
def send(o):
    p.stdin.write(json.dumps(o)+"\n"); p.stdin.flush()
rid=str(uuid.uuid4())
send({"type":"control_request","request_id":rid,"request":{"subtype":"initialize","supportedDialogKinds":[],"perTaskStopAffordance":True,"agentProgressSummaries":True}})
def reader():
    for line in p.stdout:
        line=line.strip()
        if not line: continue
        try: frames.append(json.loads(line))
        except Exception: frames.append({"RAW":line})
t=threading.Thread(target=reader,daemon=True); t.start()
deadline=time.time()+40
got_init=False
while time.time()<deadline:
    if any(f.get("type")=="control_response" and (f.get("response") or {}).get("request_id")==rid for f in frames):
        got_init=True
        break
    time.sleep(0.2)
# ask a few zero-cost control requests
reqs={}
for sub,extra in [("get_context_usage",{}),("get_session_cost",{}),("get_binary_version",{}),("mcp_status",{}),("background_tasks",{}),("get_settings",{}),("get_usage",{})]:
    r=str(uuid.uuid4()); reqs[r]=sub
    send({"type":"control_request","request_id":r,"request":{"subtype":sub,**extra}})
deadline=time.time()+25
while time.time()<deadline:
    done={ (f.get("response") or {}).get("request_id") for f in frames if f.get("type")=="control_response"}
    if all(r in done for r in reqs): break
    time.sleep(0.2)
r=str(uuid.uuid4()); send({"type":"control_request","request_id":r,"request":{"subtype":"end_session"}})
time.sleep(1.5)
try: p.stdin.close()
except Exception: pass
try: p.wait(timeout=15)
except Exception: p.kill()
err=p.stderr.read()
json.dump({"got_init":got_init,"reqs":reqs,"frames":frames,"stderr_tail":err[-3000:]}, open(out,"w"), indent=1)
print("frames:", len(frames), "got_init:", got_init, "exit:", p.returncode)
for f in frames:
    t=f.get("type"); st=f.get("subtype") or ((f.get("response") or {}).get("subtype") if t=="control_response" else "") or ""
    rid2=(f.get("response") or {}).get("request_id")
    print(" ", t, st, reqs.get(rid2,"init" if rid2==rid else ""))
