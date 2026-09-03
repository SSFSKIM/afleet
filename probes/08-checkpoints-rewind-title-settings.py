import json, subprocess, sys, uuid, time, threading, os
cwd, out = sys.argv[1:3]
env=dict(os.environ); env["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"]="1"
cmd=["claude","-p","--input-format","stream-json","--output-format","stream-json","--include-partial-messages","--replay-user-messages","--forward-subagent-text","--permission-prompt-tool","stdio","--permission-prompts","host","--permission-mode","default","--model","haiku","--verbose"]
p=subprocess.Popen(cmd,cwd=cwd,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1,env=env)
log=open(out,"w"); frames=[]; lock=threading.Lock()
def send(o):
    line=json.dumps(o); log.write("OUT "+line+"\n"); log.flush(); p.stdin.write(line+"\n"); p.stdin.flush()
perm=[]
def reader():
    for line in p.stdout:
        line=line.strip()
        if not line: continue
        log.write("IN  "+line+"\n"); log.flush()
        try: m=json.loads(line)
        except: continue
        with lock: frames.append(m)
        if m.get("type")=="control_request" and (m.get("request") or {}).get("subtype")=="can_use_tool":
            perm.append(m["request"])
            send({"type":"control_response","response":{"subtype":"success","request_id":m["request_id"],"response":{"behavior":"allow","updatedInput":m["request"]["input"],"decisionClassification":"user_temporary"}}})
threading.Thread(target=reader,daemon=True).start()
def ctl(sub,**kw):
    r=str(uuid.uuid4()); send({"type":"control_request","request_id":r,"request":{"subtype":sub,**kw}}); return r
def wait_ctl(r,timeout=30):
    t=time.time()
    while time.time()-t<timeout:
        with lock:
            for f in frames:
                if f.get("type")=="control_response" and (f.get("response") or {}).get("request_id")==r: return f["response"]
        time.sleep(0.2)
def wait_result(n,timeout=120):
    t=time.time()
    while time.time()-t<timeout:
        with lock: c=sum(1 for f in frames if f.get("type")=="result")
        if c>=n: return True
        time.sleep(0.2)
    return False
print("init:", json.dumps(wait_ctl(ctl("initialize",supportedDialogKinds=[],perTaskStopAffordance=True,agentProgressSummaries=True)))[:80])
u1=str(uuid.uuid4())
send({"type":"user","uuid":u1,"parent_tool_use_id":None,"origin":{"kind":"human"},"message":{"role":"user","content":"Use the Write tool to create a file named probe-rewind.txt in the current directory containing the text: hello . Then reply with the single word: done"}})
print("turn1 done:", wait_result(1))
print("PERMISSION REQUESTS:", [(r.get("tool_name"), r.get("display_name"), r.get("description"), [s.get("type") for s in (r.get("permission_suggestions") or [])], r.get("decision_reason_type"), r.get("suppress_always_allow_rule"), r.get("default_to_no"), r.get("requires_user_interaction"), r.get("title")) for r in perm])
if perm: print("  full first request keys:", sorted(perm[0].keys())); print("  suggestions:", json.dumps(perm[0].get("permission_suggestions"))[:500])
print("file exists:", os.path.exists(os.path.join(cwd,"probe-rewind.txt")))
tests=[("rewind_files",{"user_message_id":u1,"dry_run":True}),
       ("generate_session_title",{"description":"create probe-rewind.txt with hello","persist":False}),
       ("file_suggestions",{"query":"probe"}),("file_suggestions",{"query":"src/pro"}),("file_suggestions",{"query":""}),
       ("update_settings",{"source":"localSettings","settings":{"permissions":{"additionalDirectories":["/tmp/afleet-gap"]}}}),
       ("get_settings",{}),
       ("rewind_conversation",{"target_message_uuid":u1}),
       ("rewind_files",{"user_message_id":u1,"dry_run":False}),
      ]
for sub,kw in tests:
    r=wait_ctl(ctl(sub,**kw),40)
    body=(r or {}).get("response") if (r or {}).get("subtype")=="success" else (r or {}).get("error")
    s=json.dumps(body) if not isinstance(body,str) else body
    if sub=="get_settings": s=json.dumps({"applied":(body or {}).get("applied"),"sources_keys":sorted(((body or {}).get("sources") or {}).keys()) if isinstance((body or {}).get("sources"),dict) else str(type((body or {}).get("sources"))), "effective.permissions.additionalDirectories":((body or {}).get("effective") or {}).get("permissions",{}).get("additionalDirectories")})
    print(f"## {sub} {json.dumps(kw)[:90]} → {(r or {}).get('subtype')}: {s[:600]}")
print("file exists after rewind:", os.path.exists(os.path.join(cwd,"probe-rewind.txt")))
with lock: others=[(f.get("type"),f.get("subtype")) for f in frames if f.get("type") not in ("control_response","stream_event")]
from collections import Counter
print("FRAMES:", Counter(others).most_common())
# any conversation_reset / user frames after rewind?
with lock:
    for f in frames:
        if f.get("type") in ("conversation_reset",) or (f.get("type")=="user" and f.get("isReplay") and "rewind" in json.dumps(f).lower()): print("REWIND-RELATED FRAME:", json.dumps(f)[:300])
ctl("end_session"); time.sleep(1.5)
try: p.stdin.close()
except: pass
try: p.wait(timeout=20)
except: p.kill()
print("stderr tail:", p.stderr.read()[-600:])
