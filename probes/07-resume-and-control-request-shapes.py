import json, subprocess, sys, uuid, time, threading
cwd, out, sid, first_uuid = sys.argv[1:5]
cmd=["claude","-p","--input-format","stream-json","--output-format","stream-json","--include-partial-messages","--replay-user-messages","--forward-subagent-text","--permission-prompt-tool","stdio","--permission-prompts","host","--permission-mode","default","--model","haiku","--verbose","--resume",sid]
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
threading.Thread(target=reader,daemon=True).start()
pending={}
def ctl(sub,**kw):
    r=str(uuid.uuid4()); pending[r]=sub; send({"type":"control_request","request_id":r,"request":{"subtype":sub,**kw}}); return r
ctl("initialize",supportedDialogKinds=[],perTaskStopAffordance=True,agentProgressSummaries=True)
time.sleep(6)
with lock: pre=[f for f in frames if f.get("type") in ("assistant","user")]
print("HISTORY REPLAY on --resume before any input: assistant/user frames =", len(pre))
tests=[
 ("list_models",{}),("get_plan",{}),("get_workspace_diff",{}),("file_suggestions",{"query":"pro"}),
 ("read_file",{"path":"probes/01-stream-json-baseline.py","max_bytes":200}),
 ("add_directory",{"directory":"/tmp"}),("add_directory",{"path":"/tmp"}),("add_directory",{"directories":["/tmp"]}),
 ("apply_flag_settings",{"settings":{"effortLevel":"low"}}),("apply_flag_settings",{"settings":{"model":"sonnet"}}),("apply_flag_settings",{"settings":{"fastMode":True}}),("apply_flag_settings",{"settings":{"agent":"Explore"}}),("apply_flag_settings",{"settings":{"outputStyle":"Concise"}}),("apply_flag_settings",{"settings":{"viewMode":"fullscreen"}}),("apply_flag_settings",{"settings":{"bogusKey":1}}),
 ("set_color",{"color":"blue"}),("set_max_thinking_tokens",{"max_thinking_tokens":None,"thinking_display":"summarized"}),
 ("rewind_conversation",{"user_message_id":first_uuid}),("rewind_conversation",{"user_message_id":first_uuid,"dry_run":True}),
 ("rewind_files",{"user_message_id":first_uuid,"dry_run":True}),
 ("get_settings",{}),("update_settings",{"source":"userSettings","settings":{"tips":False}}),
 ("mcp_status",{}),("background_tasks",{}),("stop_task",{"task_id":"nope"}),
 ("generate_session_title",{}),("get_session_cost",{}),("get_usage",{}),("get_context_usage",{"detail":True}),
 ("remote_control",{}),("channel_enable",{}),("mcp_authenticate",{"serverName":"plugin:supabase:supabase"}),("mcp_oauth_callback_url",{"serverName":"plugin:supabase:supabase"}),("mcp_clear_auth",{"serverName":"nope"}),
 ("claude_authenticate",{}),("poll_event",{}),("ultrareview_launch",{}),("stage_file",{}),("register_repo_root",{"directory":cwd}),("set_cwd",{"path":cwd}),
 ("message_rated",{"messageUuid":first_uuid,"sentiment":"positive","surface":"assistant_text","cleared":False}),
 ("submit_feedback",{"description":"probe"}),("nonexistent_subtype",{}),
]
ids=[]
for sub,kw in tests:
    ids.append((ctl(sub,**kw),sub,kw)); time.sleep(0.15)
deadline=time.time()+45
while time.time()<deadline:
    with lock: done={(f.get("response") or {}).get("request_id") for f in frames if f.get("type")=="control_response"}
    if all(r in done for r,_,_ in ids): break
    time.sleep(0.3)
with lock: resp={(f.get("response") or {}).get("request_id"):f["response"] for f in frames if f.get("type")=="control_response"}
report=[]
for r,sub,kw in ids:
    x=resp.get(r)
    if not x: report.append(f"## {sub} {json.dumps(kw)[:80]} → NO RESPONSE"); continue
    body=x.get("response") if x.get("subtype")=="success" else x.get("error")
    s=json.dumps(body) if not isinstance(body,str) else body
    if sub in ("get_settings","submit_feedback"): s=s[:300]
    report.append(f"## {sub} {json.dumps(kw)[:80]} → {x.get('subtype')}: {s[:700]}")
with lock: others=[(f.get("type"),f.get("subtype")) for f in frames if f.get("type") not in ("control_response",)]
from collections import Counter
report.append("OTHER FRAMES: "+str(Counter(others).most_common()))
ctl("end_session"); time.sleep(1.5)
try: p.stdin.close()
except: pass
try: p.wait(timeout=20)
except: p.kill()
report.append("stderr tail: "+p.stderr.read()[-800:])
open(out+".report.txt","w").write("\n".join(report))
print("\n".join(report))
